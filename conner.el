;;; conner.el --- Define and run project specific commands  -*- lexical-binding: t -*-

;; Authors: Tomás Ralph <tomasralph2000@gmail.com>
;; Created: 2024
;; Version: 0.5
;; Package-Requires: ((emacs "29.1"))
;; Homepage: https://github.com/tralph3/conner
;; Keywords: tools

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Conner allows you to define custom commands tailored to your
;; projects' needs.  Whether it's compiling, running, testing,
;; prettifying, monitoring changes, debugging, installing, or any
;; other task specific to your workflow, Conner makes it easy to
;; integrate with Emacs.
;;
;; Commands are configured in a .conner file, typically located at the
;; root of your project.  Inside this file, you'll define a Lisp object
;; containing a list of command names, their respective commands, and
;; their types.
;;
;; Integration with project.el enables seamless execution of these
;; commands within Emacs, either on arbitrary directories or
;; automatically detecting the current project's root.
;;
;; Additionally, Conner also has support for .env files.  By default,
;; Conner will look in the root directory of your project for a .env
;; file and load any environment variables found within.  These
;; variables are then accessible to Conner commands, and won't pollute
;; the regular Emacs session.
;;
;; Conner is configurable, so you can add your own command types if
;; what's available doesn't quite suit your needs.


;;; Code:

(require 'project)

(defgroup conner nil
  "Conner is a Command Runner for GNU Emacs."
  :link '(url-link :tag "Homepage" "https://github.com/tralph3/conner")
  :group 'development
  :prefix "conner-")

(defcustom conner-file-name ".conner"
  "Filename where the launch commands will be defined."
  :type 'string)

(defcustom conner-env-file ".env"
  "Filename where env variables are defined."
  :type 'string)

(defcustom conner-read-env-file t
  "Whether to read env files before running commands.

If non-nil, conner will look for a `conner-env-file' in the provided
root dir and load any environment variables within, passing them to
every command when called.

This will not modify `process-environment'.  The changes will only
apply and be visible to conner commands."
  :type 'boolean)

(defcustom conner-default-file-behavior 'project
  "Where should conner operate by default.

If set to `project', conner will read, write and update commands
defined in the `conner-file-name' of the directory by
default.  You would need to pass \\[universal-argument] to these
functions to have them operate on the associated local file.

If set to `local', the inverse is true.  It will operate on the
local file by default, and you will need to pass
\\[universal-argument] to have it operate on the project file."
  :type '(choice (const :tag "Project file" project)
                 (const :tag "Local file" local)))

(defcustom conner-command-types-alist
  `(("compile" ,#'conner--run-compile-command)
    ("elispf" ,#'conner--run-elispf-command)
    ("meta" ,#'conner--run-meta-command)
    ("term" ,#'conner--run-term-command)
    ("eat" ,#'conner--run-eat-command)
    ("vterm" ,#'conner--run-vterm-command))
  "Alist of command types and their associated functions.

You can add your own command types here.  Each associated function
will be given two arguments.

1. PLIST, which is the plist that represents the command that has
been called.  You can use `plist-get' to fetch data from it.

2. ROOT-DIR, which is the path given to `conner-run-command'."
  :type '(repeat (list
                  (string :tag "Type name")
                  (function :tag "Handler function"))))

(defcustom conner-use-navigation-in-command-edit t
  "Whether TAB should be bound when using `conner--edit-command'.

If non-nil, whenever you are editing a Conner command, TAB and
S-TAB will be bound to `conner--edit-move-to-next-command' and
`conner--edit-move-to-prev-command' respectively.  You can
disable this behavior by setting this to nil."
  :type 'boolean)

(defcustom conner-project-backend (if (featurep 'projectile)
                                      'projectile
                                    'project.el)
  "What project backend to use.

If Projectile is available, it defaults to it.  Otherwise, it uses
`project.el'."
  :type '(choice (const :tag "project.el" project.el)
                 (const :tag "Projectile" projectile)))

(defvar conner--env-var-regexp
  (rx
   line-start
   (0+ space)
   (optional "export" (0+ space)) ;; optional export
   (group (1+ (in "_" alnum))) ;; key
   (or
    (and (0+ space) "=" (0+ space))
    (and ":" (1+ space))) ;; separator
   (or
    (and "'" (group (0+ (or "\\'" (not (any "'"))))) "'") ;; single quoted value
    (and ?\" (group (0+ (or "\\\"" (not (any "\""))))) ?\") ;; double quoted value
    (group (1+ (not (in "#" "\n" space)))) ;; unquoted value
    (0+ space)
    (optional "#" (0+ any))))
  "Regexp to match env vars in file.")

(defvar conner--commands nil
  "List of commands of the last `conner-file-name' file read.")

(defvar conner--command-template '(:name "Command name"
                                         :command "The command to run"
                                         :type "See available types in `conner-command-types-alist'"
                                         :workdir nil
                                         :environment nil
                                         :hook nil
                                         :silent nil)
  "Command template that's presented to the user when adding a new command.")

(defun conner--construct-file-path (root-dir)
  "Return the path to ROOT-DIR's `conner-file-name'."
  (file-name-concat (expand-file-name root-dir) conner-file-name))

(defun conner--validate-command-plist (plist)
  "Throw an error if PLIST is an invalid Conner command."
  (let ((command-types (mapcar #'car conner-command-types-alist)))
    (when (not (plistp plist))
      (user-error "Not a plist.  Ensure each key has a value"))
    (when (not (plist-get plist :name))
      (user-error "Name not specified.  Add a :name key"))
    (when (not (stringp (plist-get plist :name)))
      (user-error "Name is not a string"))
    (when (not (plist-get plist :command))
      (user-error "Command not specified.  Add a :command key"))
    (when (not (plist-get plist :type))
      (user-error "Type not specified.  Add a :type key"))
    (when (not (stringp (plist-get plist :type)))
      (user-error "Type is not a string"))
    (when (not (member (plist-get plist :type) command-types))
      (user-error "Unknown command type.  Consult `conner-command-types-alist' for available types"))
    (when (not (or (stringp (plist-get plist :workdir))
                   (not (plist-get plist :workdir))))
      (user-error "Workdir is not a string"))
    (when (not (or (listp (plist-get plist :environment))
                   (not (plist-get plist :environment))))
      (user-error "Environment is not a list"))
    (when (not (or (functionp (plist-get plist :hook))
                   (not (plist-get plist :hook))))
      (user-error "Hook is not a function"))
    (when (not (booleanp (plist-get plist :silent)))
      (user-error "Silent is not a boolean"))))

(defun conner--pp-list (list)
  "Pretty print LIST using line breaks after every item."
  (when (not (listp list))
    (error "Not a valid list"))
  (with-temp-buffer
    (let ((inhibit-message t)
          (message-log-max nil))
      (lisp-data-mode)
      (prin1 list (current-buffer))
      (goto-char (1+ (point-min)))
      (dotimes (i (1- (length list)))
        (forward-sexp 1)
        (newline-and-indent))
      (goto-char (point-max))
      (buffer-string))))

(defun conner--pp-plist (plist)
  "Pretty print PLIST using line breaks after every value."
  (when (not (plistp plist))
    (error "Not a valid plist"))
  (with-temp-buffer
    (let ((inhibit-message t)
          (message-log-max nil))
      (lisp-data-mode)
      (insert "(")
      (cl-loop for (key val) on plist by #'cddr do
               (prin1 key (current-buffer))
               (insert " ")
               (if (and val (listp val))
                   (insert (conner--pp-list val))
                 (prin1 val (current-buffer)))
               (newline))
      (delete-char -1)
      (insert ")")
      (indent-region (point-min) (point-max))
      (buffer-string))))

(defun conner--pp-plist-list (plist-list)
  "Pretty print PLIST-LIST using line breaks."
  (when (not (listp plist-list))
    (error "Not a valid list"))
  (with-temp-buffer
    (let ((inhibit-message t)
          (message-log-max nil))
      (lisp-data-mode)
      (insert "(")
      (dolist (plist plist-list)
        (insert (conner--pp-plist plist) "\n"))
      (backward-delete-char-untabify 1)
      (when (length> (buffer-string) 0)
        (insert ")"))
      (indent-region (point-min) (point-max))
      (buffer-string))))

(defun conner--construct-local-file-path (root-dir)
  "Return the path to the local conner file associated with ROOT-DIR."
  (let* ((backup-directory-alist `(,`("." . ,(file-name-concat user-emacs-directory "conner"))))
	     (name (make-backup-file-name-1 (expand-file-name root-dir))))
    (concat name ".#conner#")))

(defun conner--update-commands-from-disk (root-dir &optional read-project read-local)
  "Update `conner--commands' with values stored on disk.

If READ-PROJECT is non-nil, update with ROOT-DIR's
`conner-file-name' contents.

If READ-LOCAL is non-nil, update with ROOT-DIR's associated local
file.

If both options are nil, read both files and append project
specific commands to the local ones, making the local ones take
precedence."
  (if (or read-project read-local)
      (let ((project-contents (and read-project (conner--read-commands (conner--construct-file-path root-dir))))
            (local-contents (and read-local (conner--read-commands (conner--construct-local-file-path root-dir)))))
        (setq conner--commands (append local-contents project-contents)))
    (let ((project-contents (conner--read-commands (conner--construct-file-path root-dir)))
          (local-contents (conner--read-commands (conner--construct-local-file-path root-dir))))
      (setq conner--commands (append local-contents project-contents)))))

(defun conner--read-commands (conner-file)
  "Read the contents of CONNER-FILE."
  (when (file-exists-p conner-file)
    (with-temp-buffer
      (insert-file-contents (expand-file-name conner-file))
      (condition-case nil
          (read (current-buffer))
        (error nil)))))

(defun conner--write-commands (root-dir)
  "Write the contents of `conner--commands' to disk.

Write to ROOT-DIR's `conner-file-name' by default.

If invoked with \\[universal-argument], write to ROOT-DIR's
associated local file.

This logic is inverted if `conner-default-file-behavior' is set
to `local'."
  (let ((conner-file (if (or
                          (and current-prefix-arg (eq conner-default-file-behavior 'project))
                          (and (not current-prefix-arg) (eq conner-default-file-behavior 'local)))
                         (conner--construct-local-file-path root-dir)
                       (conner--construct-file-path root-dir))))
    (with-temp-buffer
      (insert ";;; -*- lisp-data -*-\n")
      (let ((print-length nil)
            (print-level nil))
        (insert (conner--pp-plist-list conner--commands))
        (write-file conner-file)))))

(defun conner--plist-keys (plist)
  "Get keys of plist PLIST."
  (cl-loop for (k _v) on plist by #'cddr collect k))

(defun conner--clean-command-plist (plist)
  "Remove any keys in PLIST with nil values."
  (dolist (key (conner--plist-keys plist))
    (when (eq nil (plist-get plist key))
      (cl-remf plist key)))
  plist)

(defun conner-expand-command (command)
  "Expand COMMAND's specs to their final values.

If COMMAND is a list of strings, pass it to
`conner--concat-command-list' and use the result.

The spec is defined as follows:

* %f: Filename from where the command was called.
* %F: Full path to the filename from where the command was called.
* %d: Project root directory.
* %a: Arbitrary argument.  User will be prompted for completion.

As with any `format' function, flags are supported in the
following format:

  %<flags><width><precision>character

Allowed flags are:

* 0: Pad to the width, if given, with zeros instead of spaces.
* -: Pad to the width, if given, on the right instead of the left.
* <: Truncate to the width and precision, if given, on the left.
* >: Truncate to the width and precision, if given, on the right.
* ^: Convert to upper case.
* _: Convert to lower case.

For more details read `format-spec'."
  (when (listp command)
    (setq command (conner--concat-command-list command)))
  (format-spec command
               `((?f . ,(file-name-nondirectory (or (buffer-file-name) "")))
                 (?F . ,(or (buffer-file-name) ""))
                 (?d . ,(expand-file-name default-directory))
                 (?a . ,(lambda () (read-string "Argument: "))))))

(defun conner--construct-env-var-list (env-alist)
  "Return a list of strings in the form VAR=val.

ENV-ALIST should be an alist of environment variables where car
is the key and cdr is the value."
  (setq-local conner--env-var-list nil)
  (dolist (element env-alist)
    (let ((key (car element))
          (value (cadr element)))
      (add-to-list 'conner--env-var-list (concat key "=" value))))
  conner--env-var-list)

(defun conner--read-command-env-vars (plist)
  "Read env vars of PLIST's :environment and return list of strings."
  (with-temp-buffer
    (dolist (elem (plist-get plist :environment))
      (insert elem "\n"))
    (let ((env-vars (conner--get-env-vars-in-buffer)))
      (conner--construct-env-var-list env-vars))))

(defun conner--read-env-file (root-dir)
  "Read ROOT-DIR's `conner-env-file' and return a list of strings."
  (let* ((env-file (file-name-concat root-dir conner-env-file))
         (env-vars (conner--load-env-vars env-file)))
    (conner--construct-env-var-list env-vars)))

(defun conner--get-env-vars-in-buffer ()
  "Get a list of all REGEXP matches in a buffer."
  (save-excursion
    (goto-char (point-min))
    (save-match-data
      (let (matches)
        (while (re-search-forward conner--env-var-regexp nil t)
          (push (list
                 (match-string-no-properties 1)
                 (or
                  (match-string-no-properties 2)
                  (match-string-no-properties 3)
                  (match-string-no-properties 4)))
                matches))
        matches))))

(defun conner--load-env-vars (env-file-path)
  "Read env vars in ENV-FILE-PATH.  Return list."
  (with-temp-buffer
    (when (file-exists-p env-file-path)
      (insert-file-contents env-file-path))
    (conner--get-env-vars-in-buffer)))

(defun conner--find-command-with-value (key value &optional plist-list)
  "Find the plist in `conner--commands' where KEY has VALUE.

If PLIST-LIST is non-nil, search it instead."
  (cl-find-if (lambda (plist)
                (equal value (plist-get plist key)))
              (or plist-list conner--commands)))

(defun conner--get-command-names ()
  "Return a list of defined command names as strings."
  (mapcar (lambda (plist) (plist-get plist :name)) conner--commands))

(defun conner--command-annotation-function (candidate)
  "Get CANDIDATE's command and format for use in mini buffer annotation."
  (let* ((max-width (apply #'max (mapcar #'length (conner--get-command-names))))
         (indent (make-string (- max-width (length candidate)) ?\s))
         (command (car
                   (cl-remove-if #'string-blank-p
                                 (split-string
                                  (format "%s"
                                          (conner--concat-command-list
                                           (plist-get
                                            (conner--find-command-with-value :name candidate)
                                            :command))) "\n"))))
         (tabs (make-string 6 ?\t)))
    (format "%s%s%s" indent tabs command)))

(defun conner--edit-move-to-next-command ()
  "Move and select the next value in command plist."
  (interactive)
  (re-search-forward "^\\(:?(\\| *\\):[[:alnum:]]+ ")
  (push-mark nil t t)
  (setq-local next-char (char-to-string (char-after)))
  (forward-sexp)
  (when (member next-char '("\"" "[" "("))
    (let ((rbeg (region-beginning))
          (rend (region-end)))
      (goto-char (1+ rbeg))
      (push-mark nil t t)
      (goto-char (1- rend)))))

(defun conner--edit-move-to-prev-command ()
  "Move and select the previous value in command plist."
  (interactive)
  (re-search-backward "^\\(:?(\\| *\\):[[:alnum:]]+")
  (re-search-backward "^\\(:?(\\| *\\):[[:alnum:]]+")
  (move-beginning-of-line nil)
  (conner--edit-move-to-next-command))

(defun conner--edit-command (&optional command)
  "Open a buffer for the user to edit COMMAND.

If COMMAND is not specified, a template is provided instead.

Once finished, the command is verified to be valid with
`conner--validate-command-plist'.  If no error is raised, the
command is returned."
  (let ((buffer (generate-new-buffer "*conner-edit-command*"))
        (keymap (make-sparse-keymap)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (lisp-data-mode)
      (define-key keymap (kbd "C-c C-c") (lambda ()
                                           (interactive)
                                           (save-excursion
                                             (goto-char (point-min))
                                             (let ((contents (read (current-buffer))))
                                               (conner--validate-command-plist contents))
                                             (exit-recursive-edit))))
      (define-key keymap (kbd "C-c C-k") (lambda ()
                                           (interactive)
                                           (kill-buffer)
                                           (when (not (one-window-p))
                                             (delete-window))
                                           (abort-recursive-edit)))
      (when conner-use-navigation-in-command-edit
        (define-key keymap (kbd "<tab>") #'conner--edit-move-to-next-command)
        (define-key keymap (kbd "<backtab>") #'conner--edit-move-to-prev-command))
      (insert (conner--pp-plist (or command conner--command-template)))
      (goto-char (point-min))
      (conner--edit-move-to-next-command)
      (if conner-use-navigation-in-command-edit
          (setq header-line-format "Submit with ‘C-c C-c’ or abort with ‘C-c C-k’. Use ‘<tab>‘ and ‘<backtab>‘ to navigate.")
        (setq header-line-format "Submit with ‘C-c C-c’ or abort with ‘C-c C-k’."))
      (use-local-map keymap)
      (recursive-edit)
      (goto-char (point-min))
      (let ((contents (read (current-buffer))))
        (kill-buffer)
        (when (not (one-window-p))
          (delete-window))
        (conner--validate-command-plist contents)
        (conner--clean-command-plist contents)))))

(defun conner--act-on-project (func &optional project &rest args)
  "Gets root dir of PROJECT and run FUNC with it.

PROJECT is either a path to a project if `conner-project-backend'
is `projectile', or a project object if using `project.el'."
  (declare-function projectile-relevant-known-projects "ext:projectile.el" nil)
  (declare-function projectile-project-p "ext:projectile.el" nil)
  (declare-function projectile-completing-read "ext:projectile.el" _ _)
  (declare-function projectile-project-root "ext:projectile.el" _)
  (cond
   ((equal conner-project-backend 'projectile)
    (let* ((projects (projectile-relevant-known-projects))
           (project (or project
                        (projectile-project-p)
                        (projectile-completing-read
                           "Select project: " projects)))
           (root-dir (projectile-project-root project)))
      (apply func root-dir args)))
   ((equal conner-project-backend 'project.el)
    (let* ((project (or project (project-current t)))
           (root-dir (project-root project)))
      (apply func root-dir args)))
   (t (error "Unknown project backend: %s" conner-project-backend))))

;;;###autoload
(defun conner-run-project-command (&optional project command-name)
  "Project aware variant of `conner-run-command'.

PROJECT is either a path to a project if `conner-project-backend'
is `projectile', or a project object if using `project.el'.

If no PROJECT is provided, use current project.  If nil, prompt
the user.

Refer to `conner-run-command' for usage of COMMAND-NAME."
  (interactive)
  (conner--act-on-project #'conner-run-command project command-name))

;;;###autoload
(defun conner-add-project-command (&optional project command-plist)
  "Project aware variant of `conner-add-command'.

PROJECT is either a path to a project if `conner-project-backend'
is `projectile', or a project object if using `project.el'.

If not PROJECT is provided, use current project.  If nil, prompt
the user.

Refer to `conner-add-command' for usage of COMMAND-PLIST."
  (interactive)
  (conner--act-on-project #'conner-add-command project command-plist))

;;;###autoload
(defun conner-delete-project-command (&optional project command-name)
  "Project aware variant of `conner-delete-command'.

PROJECT is either a path to a project if `conner-project-backend'
is `projectile', or a project object if using `project.el'.

If not PROJECT is provided, use current project.  If nil, prompt
the user.

Refer to `conner-delete-command' for usage of COMMAND-NAME."
  (interactive)
  (conner--act-on-project #'conner-delete-command project command-name))

;;;###autoload
(defun conner-update-project-command (&optional project command-name new-command-plist)
  "Project aware variant of `conner-update-command'.

PROJECT is either a path to a project if `conner-project-backend'
is `projectile', or a project object if using `project.el'.

If not PROJECT is provided, use current project.  If nil, prompt
the user.

Refer to `conner-update-command' for usage of COMMAND-NAME and
NEW-COMMAND-PLIST."
  (interactive)
  (conner--act-on-project #'conner-update-command project command-name new-command-plist))

;;;###autoload
(defun conner-run-command (root-dir &optional command-name)
  "Run command COMMAND-NAME.

The user will be prompted for every optional parameter not
specified.

Commands are read from both ROOT-DIR's `conner-file-name' and
ROOT-DIR's associated local file.

The command will be ran in ROOT-DIR.

If `conner-read-env-file' is non-nil, it will read ROOT-DIR's
`conner-env-file' before executing the command."
  (interactive "D")
  (conner--update-commands-from-disk root-dir)
  (let* ((completion-extra-properties
          '(:annotation-function conner--command-annotation-function))
         (process-environment (if conner-read-env-file
                                  (append (conner--read-env-file root-dir) process-environment)
                                process-environment))
         (command-name (or command-name (completing-read "Select a command: " (conner--get-command-names))))
         (plist (conner--find-command-with-value :name command-name))
         (process-environment (append (conner--read-command-env-vars plist) process-environment))
         (command-type (plist-get plist :type))
         (command-workdir (plist-get plist :workdir))
         (command-hook (plist-get plist :hook))
         (command-silent (plist-get plist :silent))
         (command-func (cadr (assoc command-type conner-command-types-alist)))
         (default-directory (file-name-concat root-dir command-workdir))
         ;; If the command should be silent, we add a rule to not
         ;; display a window for any buffer whose name starts with
         ;; Conner.
         (display-buffer-alist (if command-silent
                                   (cons '("\\*conner-.*"
                                           (display-buffer-no-window)
                                           (allow-no-window . t))
                                         display-buffer-alist)
                                 display-buffer-alist)))
    (when (functionp command-hook)
      (funcall command-hook))
    (funcall command-func plist root-dir)))

;;;###autoload
(defun conner-add-command (root-dir &optional command-plist)
  "Add command COMMAND-PLIST.

If no plist is provided, a buffer will open for the user to
configure the command.

Write to ROOT-DIR's `conner-file-name' by default.  If invoked
with \\[universal-argument], write to a local file associated
with ROOT-DIR.

This logic is inverted if `conner-default-file-behavior' is set
to `local'."
  (interactive "D")
  (when command-plist
    (conner--validate-command-plist command-plist))
  (if (or
       (and current-prefix-arg (eq conner-default-file-behavior 'project))
       (and (not current-prefix-arg) (eq conner-default-file-behavior 'local)))
      (conner--update-commands-from-disk root-dir nil t)
    (conner--update-commands-from-disk root-dir t))
  (let* ((new-command (or command-plist (conner--edit-command)))
         (updated-list
          (conner--add-command-to-list conner--commands new-command)))
    (setq conner--commands updated-list)
    (conner--write-commands root-dir)))

;;;###autoload
(defun conner-delete-command (root-dir &optional command-name)
  "Delete command COMMAND-NAME and write to disk.

The user will be prompted for every optional parameter not
specified.

Write to ROOT-DIR's `conner-file-name' by default.  If invoked
with \\[universal-argument], write to a local file associated
with ROOT-DIR.

This logic is inverted if `conner-default-file-behavior' is set
to `local'."
  (interactive "D")
  (if (or
       (and current-prefix-arg (eq conner-default-file-behavior 'project))
       (and (not current-prefix-arg) (eq conner-default-file-behavior 'local)))
      (conner--update-commands-from-disk root-dir nil t)
    (conner--update-commands-from-disk root-dir t))
  (let* ((completion-extra-properties
          '(:annotation-function conner--command-annotation-function))
         (names (conner--get-command-names))
         (command-name (or command-name (completing-read "Delete command: " names)))
         (plist (conner--find-command-with-value :name command-name))
         (updated-list (conner--delete-command-from-list conner--commands plist)))
    (setq conner--commands updated-list)
    (conner--write-commands root-dir)))

;;;###autoload
(defun conner-update-command (root-dir &optional command-name new-command-plist)
  "Update command COMMAND-NAME to NEW-COMMAND-PLIST.

Command will be read from ROOT-DIR's `conner-file-name' by
default.  If invoked with \\[universal-argument], read from a
local file associated with ROOT-DIR.

This logic is inverted if `conner-default-file-behavior' is set
to `local'.

The user will be prompted for every optional parameter not
specified.

If a non-existent COMMAND-NAME is provided, it will be created
instead."
  (interactive "D")
  (if (or
       (and current-prefix-arg (eq conner-default-file-behavior 'project))
       (and (not current-prefix-arg) (eq conner-default-file-behavior 'local)))
      (conner--update-commands-from-disk root-dir nil t)
    (conner--update-commands-from-disk root-dir t))
  (let* ((completion-extra-properties
          '(:annotation-function conner--command-annotation-function))
         (names (conner--get-command-names))
         (command-name (or command-name (completing-read "Update command: " names)))
         (command-plist (conner--find-command-with-value :name command-name))
         (new-command (or new-command-plist (conner--edit-command (conner--find-command-with-value :name command-name))))
         (updated-list
          (conner--update-command-from-list
           conner--commands command-plist new-command)))
    (setq conner--commands updated-list)
    (conner--write-commands root-dir)))

(defun conner--add-command-to-list (command-list command-plist)
  "Add command COMMAND-PLIST to COMMAND-LIST."
  (conner--validate-command-plist command-plist)
  (if (and command-list
       (conner--find-command-with-value
        :name (plist-get command-plist :name) command-list))
      (user-error "A command with this name already exists"))
  (push command-plist command-list))

(defun conner--delete-command-from-list (command-list command-plist)
  "Delete COMMAND-PLIST from COMMAND-LIST."
  (delete command-plist command-list))

(defun conner--update-command-from-list (command-list command-plist new-command-plist)
  "Update command COMMAND-PLIST from COMMAND-LIST with NEW-COMMAND-PLIST."
  (let* ((command-deleted (conner--delete-command-from-list command-list command-plist))
         (updated-list
          (conner--add-command-to-list
           command-deleted new-command-plist)))
    updated-list))

(defun conner--concat-command-list (command-list &optional separator)
  "Concat all strings in COMMAND-LIST with SEPARATOR.

If SEPARATOR is nil, default to \" && \"."
  (if (stringp command-list)
      command-list
    (let ((separator (or separator " && ")))
      (mapconcat 'identity command-list separator))))

(defun conner--run-compile-command (plist &rest _)
  "Run the command PLIST in an unique compilation buffer.

Optional PLIST keys:

* :comint When non-nil the compilation buffer will be run in
  comint mode which makes it interactive."
  (let* ((command-name (plist-get plist :name))
         (comint (plist-get plist :comint))
         (compilation-buffer-name-function
          (lambda (_) (concat "*conner-compilation-" command-name "*"))))
    (compile (conner-expand-command (plist-get plist :command)) comint)))

(defun conner--run-term-command (plist &rest _)
  "Run the command PLIST in an unique and interactive term buffer.

The command is interpreted by bash."
  (require 'term)
  (let* ((command-name (plist-get plist :name))
         (buffer-name (concat "*conner-term-" command-name "*"))
         (buffer (get-buffer-create buffer-name))
         (command (conner-expand-command (plist-get plist :command))))
    (pop-to-buffer buffer)
    (term-mode)
    (term-exec buffer command-name "bash" nil `("-c" ,command))))

(defun conner--run-eat-command (plist &rest _)
  "Run the command PLIST in an unique and interactive eat buffer.

If eat is not available, fallback on term instead.

The command is interpreted by bash."
  (if (not (require 'eat nil t))
      (conner--run-term-command plist)
    (progn
      (declare-function eat-exec "ext:eat.el")
      (declare-function eat-mode "ext:eat.el" nil)
      (let* ((command-name (plist-get plist :name))
             (buffer-name (concat "*conner-eat-" command-name "*"))
             (buffer (get-buffer-create buffer-name))
             (command (conner-expand-command (plist-get plist :command))))
        (pop-to-buffer buffer)
        (with-current-buffer buffer
          (eat-mode)
          (eat-exec buffer command-name "bash" nil `("-c" ,command)))))))

(defun conner--run-vterm-command (plist &rest _)
  "Run the command PLIST in an unique and interactive vterm buffer.

If vterm is not available, fallback on term instead.

The command is interpreted by bash."
  (if (not (require 'vterm nil t))
      (conner--run-term-command plist)
    (progn
      (defvar vterm-kill-buffer-on-exit)
      (defvar vterm-shell)
      (declare-function vterm-mode "ext:vterm.el" nil)
      (let* ((command-name (plist-get plist :name))
             (buffer-name (concat "*conner-vterm-" command-name "*"))
             (buffer (get-buffer buffer-name))
             (vterm-kill-buffer-on-exit nil)
             (command (conner-expand-command (plist-get plist :command)))
             (vterm-shell (concat "bash -c '" command ";exit'")))
        (when buffer
          (kill-buffer buffer))
        (let ((buffer (generate-new-buffer buffer-name)))
          (pop-to-buffer buffer)
          (with-current-buffer buffer
            (vterm-mode)))))))

(defun conner--run-elispf-command (plist &rest _)
  "Run the command PLIST as an Emacs Lisp function.

The function takes no arguments."
  (let* ((command (plist-get plist :command))
         (command (if (stringp command)
                      (intern command)
                    command)))
    (funcall command)))

(defun conner--run-meta-command (plist root-dir)
  "Run all the commands in PLIST at once in ROOT-DIR.

The command must be a list of strings consisting of the names of
the other commands you want to run.

Commands will be run sequentially, but since most command types
are async, it won't wait for them to finish before running the
next one.  If a command type (such as elispf) is synchronous,
then it must finish before calling the next command.

Format specifiers are supported for each string in the list.
Read `conner-expand-command' for details.

WARNING.  You can include in your command list another meta
command, or even the same one.  You can create an endless loop
like this.  No checks are in place to prevent it."
  (let ((commands (plist-get plist :command)))
    (dolist (command-name commands)
      (conner-run-command root-dir (conner-expand-command command-name)))))


(provide 'conner)

;;; conner.el ends here

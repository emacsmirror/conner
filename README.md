# Conner

Conner is a **Co**mmand Ru**nner** for GNU emacs.

---

Conner allows you to define arbitrary commands for each of your
projects. Every project could have a different way to compile it, to
run it, to test it, to prettify it, to watch for changes, to debug it,
to install it, or any other thing. With conner, you can define a
command for each of these actions, or any other you want.

Commands are defined in the conner file, by default called `.conner`,
situated at the root of your project. Inside it, you'll find a lisp
object that contains a list of command names, and the commands
themselves.

Conner also provides a multitude of functions to add, delete, update,
and of course, run these commands from within emacs. It integrates
with `project.el`, so you can run these commands on arbitrary folders,
or have it automatically detect the current project's root.

Additionally, conner also has support for `.env` files. By default,
conner will look in the root directory of your project for a `.env`
file and load any environment variables found within. These variables
are then accessible to conner commands, and won't pollute the regular
emacs session.


## Usage

The first thing you'll want to do is to add a command, simply run `M-x
conner-add-project-command` or `M-x conner-add-command` to get
started. After it has been defined, you can run `M-x
conner-run-project-command` or `M-x conner-run-command` to run it.

A compilation buffer will open and run your command. Separate buffers
are assigned to each command based on their names, so if one takes too
long, or it simply doesn't exit, you can still run other commands in
the meantime.


## Acknowledgments

The source code for the processing of `.env` files was taken from
[diasjorge's load-env-vars](https://github.com/diasjorge/emacs-load-env-vars).
AQUEOUS(1)

; SPDX-FileCopyrightText: © 2020 Seafoam Labs
; SPDX-License-Identifier: CC-BY-SA-4.0

# NAME

aqueous - Aqueous Wayland compositor

# SYNOPSIS

*aqueous* [_options_]

# DESCRIPTION

Aqueous is a Wayland compositor focused on ultrawide displays. During the
in-process policy migration it uses the transitional *aqueous-wm-client*(1)
through the river-window-management-v1 protocol.

This migration build is not useful without a compatible window manager. A list
of compatible implementations can be found on the river wiki:
https://codeberg.org/river/wiki/src/branch/main/pages/wm-list.md

# OPTIONS

*-h*
	Print a help message and exit.

*-version*
	Print the version number and exit.

*-c* _shell_command_
	Override the default search paths for an init executable: instead
	_shell_command_ will be run with _/bin/sh -c_. See the *CONFIGURATION*
	section for more details.

*-log-level* [*error*|*warning*|*info*|*debug*]
	Set the log level of aqueous. At the *error* log level, only errors
	are logged.  At the *debug* log level, everything is logged including
	verbose debug messages.

*-policy* [*external*|*internal*|*compare*]
	Select the migration-time window-management policy mode. *external* uses
	the transitional Wayland client and is the default. *internal* runs only
	the in-process policy. *compare* runs internal observation alongside the
	external client and emits comparable state traces.

*-no-xwayland*
	Disable Xwayland at runtime even if aqueous has been built with support.

# KEYBINDINGS

The following keybindings are always active:

*Ctrl+Alt+F1* - *Ctrl+Alt+F12*
	Switch to VT 1-12

Window managers may add additional keybindings but cannot override these builtin
keybindings.

# CONFIGURATION

On startup aqueous will run an executable file at $XDG_CONFIG_HOME/aqueous/init if
such an executable exists. If $XDG_CONFIG_HOME is not set, ~/.config/aqueous/init
will be used instead.

The executable init file will be run as a process group leader after aqueous's
Wayland server is initialized but before entering the main loop. On exit,
aqueous will send SIGTERM to this process group.

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs. For example, *kanshi*(1) could be started
to manage output configuration.

# AUTHORS

Maintained by Isaac Freund <mail@isaacfreund.com> who is assisted by open
source contributors. For more information about river's development, see
<https://isaacfreund.com/software/river>.

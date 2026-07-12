AQUEOUS(1)

; SPDX-FileCopyrightText: © 2020 Seafoam Labs
; SPDX-License-Identifier: CC-BY-SA-4.0

# NAME

aqueous - Aqueous Wayland compositor

# SYNOPSIS

*aqueous* [_options_]

# DESCRIPTION

Aqueous is a single-process Wayland compositor and window manager focused on
ultrawide displays. Layout, focus, workspace, input, and output policy run
inside the compositor.

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
	Select the window-management policy mode. *internal* is the default.
	*external* and *compare* are available only in builds compiled with
	*-Dexternal-policy=true* for legacy protocol compatibility testing.

*-no-xwayland*
	Disable Xwayland at runtime even if aqueous has been built with support.

# KEYBINDINGS

The following keybindings are always active:

*Ctrl+Alt+F1* - *Ctrl+Alt+F12*
	Switch to VT 1-12

Configured bindings are read from Aqueous's TOML configuration.

# CONFIGURATION

On startup aqueous will run an executable file at $XDG_CONFIG_HOME/aqueous/init if
such an executable exists. If $XDG_CONFIG_HOME is not set, ~/.config/aqueous/init
will be used instead.

The executable init file will be run as a process group leader after aqueous's
Wayland server is initialized but before entering the main loop. On exit,
aqueous will send SIGTERM to this process group.

Usually this executable is a shell script that exports the live Wayland
environment or starts session services. A separate window manager or output
manager is not required.

# AUTHORS

Maintained by Isaac Freund <mail@isaacfreund.com> who is assisted by open
source contributors. For more information about river's development, see
<https://isaacfreund.com/software/river>.

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

*-drm-overlay-planes*
	Enable the startup-only DRM overlay-plane promotion path, overriding
	*[render].overlay_planes*. One rule-selected window may be promoted per
	output after an atomic TEST_ONLY commit succeeds.
	If the optional overlay backend cannot initialize or accept an unpromoted
	startup commit, Aqueous falls back to ordinary atomic composition.

*-no-drm-overlay-planes*
	Disable DRM overlay-plane promotion, overriding the configuration and any
	inherited *WLR_DRM_FORCE_LIBLIFTOFF* setting.

# KEYBINDINGS

The following keybindings are always active:

*Ctrl+Alt+F1* - *Ctrl+Alt+F12*
	Switch to VT 1-12

Configured bindings are read from Aqueous's TOML configuration.

In the integrated policy's scrolling layout, hold the configured primary
modifier (*Super* by default) and turn the vertical scroll wheel to navigate
left or right by column. Add the alternate modifier (*Alt* by default) to
navigate up or down within the focused column. If *AQUEOUS_MOD=Alt*, *Super*
becomes the alternate modifier. Natural-scroll input policy reverses the wheel
directions automatically. These wheel chords also apply to scrolling game-mode
remainders and scrolling composable children. Instances arranged vertically by
*prefer_vertical_on_portrait* swap the two chord axes, so the primary chord
navigates within the focused column and the alternate chord pans columns.

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

# GPU SELECTION

*AQUEOUS_RENDER_GPU_PREFERENCE* accepts *auto* (default), *integrated*, or
*discrete*. This is a soft Vulkan renderer preference: other usable hardware
remains eligible if the preferred type is absent or initialization fails.
The backend device breaks ties within each type; software remains last and
requires a presentation mode that permits it. Invalid values use *auto*.
*WLR_RENDER_DRM_DEVICE* remains an explicit device restriction and takes
precedence. GPU vendor names and DRM card numbering do not determine GPU type.

Automatic CPU-copy presentation fallback requires five consecutive failed frame
commits on the affected output. A successful frame or output reinitialization
resets the count. Scene-build failures and failed group configurations do not
trigger copying. Explicitly forced copy and renderers requiring copy remain
supported; automatic return to direct presentation is not implemented.

Display-device discovery remains automatic, including GPU hotplug. An explicit
*WLR_DRM_DEVICES* list is honored, but disables wlroots GPU hotplug monitoring.
The compositor does not migrate its running renderer when devices are attached;
restart the session to reevaluate the rendering preference.

*AQUEOUS_GPU_POLICY=follow* (default) requests that clients follow the renderer
that successfully initialized. *inherit* retains caller-managed application
selectors. Client support for these selectors varies; selection logs report
renderer identity separately from unverified client agreement. Applications
can still request another GPU explicitly.

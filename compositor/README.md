<!--
SPDX-FileCopyrightText: © 2026 Seafoam Labs
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">
  <img src="logo/logo_text_adaptive_color.svg" width="600em">
</div>

## Overview

Aqueous is a Wayland compositor based on
[river](https://codeberg.org/river/river), retaining compatibility with the
River protocol ecosystem while integrating Aqueous-specific policy.

During the in-process policy migration, Aqueous continues to support a separate
window manager implementing the [river-window-management-v1] protocol. The
shipped transitional implementation is `aqueous-wm-client`.

Read my blog post, [Separating the Wayland Compositor and Window Manager](https://isaacfreund.com/blog/river-window-management/),
for an in-depth explanation.

There is a [list of compatible window managers](https://codeberg.org/river/wiki/src/branch/main/pages/wm-list.md)
on our [wiki](https://codeberg.org/river/wiki).

> *If you are looking for the old dynamic tiling version of river, see
[river-classic](https://codeberg.org/river/river-classic).*

## Links

- [Protocol Docs](https://isaacfreund.com/docs/wayland/)
- [tinyrwm](https://codeberg.org/river/tinyrwm) example window manager
- [Wiki](https://codeberg.org/river/wiki)
- IRC: [#river](https://web.libera.chat/?channels=#river) on irc.libera.chat ([logs](https://libera.catirclogs.org/river))
- [Zulip](https://river-compositor.zulipchat.com) (new)
- [Issue Tracker](https://codeberg.org/river/river/issues)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Features

Aqueous currently defers window management policy to a separate window manager
implementing the [river-window-management-v1] protocol. This includes window
position/size, pointer/keyboard bindings, focus management, window decorations,
desktop shell graphics, and more.

Aqueous itself provides frame perfect rendering, good performance, support for
many Wayland protocol extensions, robust Xwayland support, the ability to
hot-swap window managers, and more.

The [river-window-management-v1] protocol and other river protocol extensions
are stable.  We do not break window managers.

## Motivation

Why split the window manager to a separate process?

- Significantly lower the barrier to entry for writing a Wayland window manager.
- Allow implementing Wayland window managers in high-level garbage collected
  languages without impacting compositor performance and latency.
- Allow hot-swapping between window managers without restarting the compositor
  and all Wayland programs.
- Promote diversity and experimentation in window manager design.

## Building

Note: If you are packaging Aqueous for distribution, see [PACKAGING.md](PACKAGING.md).

To compile Aqueous first ensure that you have the following dependencies
installed. The "development" versions are required if applicable to your
distribution.

- [zig](https://ziglang.org/download/) 0.16
- wayland
- wayland-protocols
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.20
- xkbcommon 1.12 or newer
- libevdev
- pixman
- pkg-config
- scdoc (optional, but required for man page generation)

Then run, for example:
```
zig build -Doptimize=ReleaseSafe -Dxwayland --prefix ~/.local install
```

To enable Xwayland support pass the `-Dxwayland` option as well.
Run `zig build -h` to see a list of all options.

## Usage

Aqueous can either be run nested in an X11/Wayland session or directly
from a tty using KMS/DRM. Simply run the `aqueous` command.

During migration, `-policy external` (the default) uses the transitional
`aqueous-wm-client`, `-policy internal` runs only the in-process policy, and
`-policy compare` emits internal/external state traces for parity testing.

On startup Aqueous will run an executable file at `$XDG_CONFIG_HOME/aqueous/init`
if such an executable exists. If `$XDG_CONFIG_HOME` is not set,
`~/.config/aqueous/init` will be used instead.

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs.

For complete documentation see the `aqueous(1)` man page.

The headless migration harness can be run after building both binaries:

```sh
scripts/test-policy-parity.sh
```



## TODO

- Hook up config reloading

## Licensing

This project follows the [REUSE Specification](https://reuse.software/spec-3.3/),
all files have SPDX copyright and license information.

In overview:

- Aqueous's source code is released under the GPL-3.0-only license.
- Aqueous's River-derived Wayland protocols are released under the MIT license.
- Aqueous's logo and documentation are released under the CC-BY-SA-4.0 license.

[river-window-management-v1]: https://isaacfreund.com/docs/wayland/river-window-management-v1
[liberapay]: https://liberapay.com/ifreund
[github sponsors]: https://github.com/sponsors/ifreund
[ko-fi]: https://ko-fi.com/ifreund

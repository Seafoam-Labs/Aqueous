AQUEOUSCTL(1)

; SPDX-FileCopyrightText: © 2026 Seafoam Labs
; SPDX-License-Identifier: CC-BY-SA-4.0

# NAME

aqueousctl - inspect Aqueous windows and outputs and author window rules

# SYNOPSIS

*aqueousctl windows* [*--json*]

*aqueousctl inspect --rule*

*aqueousctl scene* [*--dot*]

*aqueousctl outputs*

# DESCRIPTION

*aqueousctl* is a read-only Wayland client for Aqueous's window information
protocol. It enumerates mapped windows through ext_foreign_toplevel_list_v1 and
uses their stable identifiers to request compositor-owned state. Output mode
information is read from the standard wl_output protocol.

# COMMANDS

*windows*
	Print a tabular list containing the stable identifier, backend, application
	identity, title, output, workspace, geometry, layout, and state.

*windows --json*
	Print the same snapshot as a JSON array for scripts and diagnostics.

*inspect --rule*
	Print one ready-to-paste rules.toml entry per mapped window. Native Wayland
	windows use *app_id*; XWayland windows use *class*. The title is included as
	a commented optional matcher.

*scene*
	Print a tree representation of the compositor scene graph. With *--dot*,
	print Graphviz DOT instead.

*outputs*
	Print each active output and every mode it advertises. Each mode includes its
	physical resolution and refresh rate; the current and preferred modes are
	marked explicitly.

# SECURITY

The Aqueous introspection protocol is read-only and is hidden from clients
running through a Wayland security context, along with the foreign-toplevel
protocols it extends. The *outputs* command uses the standard read-only
wl_output interface.

# SEE ALSO

*aqueous*(1)

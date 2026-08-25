AQUEOUSCTL(1)

; SPDX-FileCopyrightText: © 2026 Seafoam Labs
; SPDX-License-Identifier: CC-BY-SA-4.0

# NAME

aqueousctl - inspect Aqueous state and control workspace layouts

# SYNOPSIS

*aqueousctl windows* [*--json*]

*aqueousctl inspect --rule*

*aqueousctl scene* [*--dot*]

*aqueousctl outputs* [*--json*]

*aqueousctl layout --output* _NAME_ [*--set* _LAYOUT_] *--json*

# DESCRIPTION

*aqueousctl* is a Wayland client for Aqueous's window information protocol. It
enumerates mapped windows through ext_foreign_toplevel_list_v1 and uses their
stable identifiers to request compositor-owned state. Output information is
read from the event stream of zwlr_output_manager_v1. Its only mutating
operation is an output-scoped active-workspace layout change.

# COMMANDS

*windows*
	Print a tabular list containing the stable identifier, backend, application
	identity, title, output, workspace, geometry, layout, committed
	wp_content_type_v1 content type, and state.

*windows --json*
	Print the same snapshot as a JSON array for scripts and diagnostics. The
	content_type field is null when the client has not committed a content
	type.

*inspect --rule*
	Print one ready-to-paste rules.toml entry per mapped window. Native Wayland
	windows use *app_id*; XWayland windows use *class*. The title is included as
	a commented optional matcher.

*scene*
	Print a tree representation of the compositor scene graph. With *--dot*,
	print Graphviz DOT instead.

*outputs*
	Print every output head and all information exposed to wlr-randr: connector
	identity and description, make, model, serial, a quoted stable EDID identifier,
	physical size, enabled state, advertised modes, position, transform, scale, and
	adaptive-sync state. Current and preferred modes are marked explicitly. With
	*--json*, print the same snapshot using the wlr-randr JSON field names and value
	types plus the *edid_sha256* field.

*layout --output NAME --json*
	Print the active workspace number and effective runtime layout for _NAME_ as
	a JSON object.

*layout --output NAME --set LAYOUT --json*
	Immediately change that output's active workspace to *tile*, *monocle*,
	*grid*, *rows*, *dwindle*, *reverse-dwindle*, *scrolling*, *float*, *game-mode*, or
	*composable*, then print the resulting state. This creates a runtime override
	and does not edit configuration files.

# SECURITY

The Aqueous protocol is hidden from clients running through a Wayland security
context, along with the foreign-toplevel protocols it extends. The output
management global used by *outputs* is also hidden because the protocol contains
configuration requests, although aqueousctl only reads its event stream. Layout
mutation is limited to the active workspace of an explicitly named output.

# SEE ALSO

*aqueous*(1)

AQUEOUSCTL(1)

; SPDX-FileCopyrightText: © 2026 Seafoam Labs
; SPDX-License-Identifier: CC-BY-SA-4.0

# NAME

aqueousctl - inspect and control Aqueous compositor state

# SYNOPSIS

*aqueousctl windows* [*--json*]

*aqueousctl inspect --rule*

*aqueousctl scene* [*--dot*]

*aqueousctl outputs* [*--json*]

*aqueousctl overlay-planes* [*--json*]

*aqueousctl layout --output* _NAME_ [*--set* _LAYOUT_] *--json*

*aqueousctl cursor* [*--json*]

*aqueousctl cursor set --theme* _NAME_ *--size* _SIZE_ [*--json*]

*aqueousctl shell* _capabilities|snapshot|watch_ *--json*

*aqueousctl window* _activate|close|state|move_ *--id* _ID_ [_OPTIONS_] *--json*

*aqueousctl workspace* _activate|rename_ *--id* _ID_ [_OPTIONS_] *--json*

*aqueousctl keyboard* _query|set|next_ [_OPTIONS_] *--json*

*aqueousctl overview* _show|hide|toggle_ [*--output* _NAME_] *--json*

*aqueousctl session exit --json*

# DESCRIPTION

*aqueousctl* is a Wayland client for Aqueous's window information protocol. It
enumerates mapped windows through ext_foreign_toplevel_list_v1 and uses their
stable identifiers to request compositor-owned state. Output information is
read from the event stream of zwlr_output_manager_v1. Its mutating operations
include layout and cursor updates. Shell commands use the separate versioned
aqueous_shell_manager_v1 protocol for live state and typed policy actions.

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

*overlay-planes*
	Report the DRM overlay promotion state for every output: backend capability,
	current phase, stable rejection reason, candidate geometry and
	format/modifier, retry backoff, and cumulative test, fallback, promotion,
	and demotion counters. With *--json*, print a machine-readable array.

	An attempt is an atomic layer test, not a blank or rendered frame. Equivalent
	rejected assignments use an exponential 250 ms to 4 second retry backoff. A
	nonzero fallback counter means a promoted final commit failed and Aqueous
	retried that frame with full composition.

	Set *AQUEOUS_OVERLAY_TRACE_BUDGET* before starting Aqueous to emit at most
	that many detailed overlay test/backoff records. Values above 10000 are
	clamped; the default is zero.

*layout --output NAME --json*
	Print the active workspace number and effective runtime layout for _NAME_ as
	a JSON object.

*layout --output NAME --set LAYOUT --json*
	Immediately change that output's active workspace to *tile*, *monocle*,
	*grid*, *rows*, *dwindle*, *reverse-dwindle*, *scrolling*, *float*, *game-mode*, or
	*composable*, then print the resulting state. This creates a runtime override
	and does not edit configuration files.

*cursor [--json]*
	Print the effective compositor cursor theme and base size. With *--json*,
	print a stable object containing *ok*, *status*, *theme*, and *size*.

*cursor set --theme NAME --size SIZE [--json]*
	Immediately apply an Xcursor theme and base size from 1 through 512 to every
	seat. The compositor and XWayland default cursors update without a restart,
	and applications subsequently launched by Aqueous inherit matching
	*XCURSOR_THEME* and *XCURSOR_SIZE* values. Native Wayland clients may provide
	their own cursor surfaces and are not forcibly restyled.
	With *--json*, print the resulting state using the same fields as the query.

	Environment files are read when a session starts and cannot mutate an
	existing compositor. Desktop settings tools making a live change should
	invoke this command and separately update the systemd user and D-Bus
	activation environments for other application launch paths.

*shell capabilities|snapshot|watch --json*
	Discover schema and capabilities, read one atomic snapshot, or subscribe to
	a snapshot followed by deltas as newline-delimited JSON. Window, workspace,
	output, seat, keyboard group/device and session records use runtime IDs
	scoped to a compositor session token. Apply deltas atomically and require
	base_sequence to match the last accepted sequence. Restart a failed watch
	with bounded backoff and replace the model with its new snapshot.

*window activate|close --id ID [--seat SEAT] --json*
	Activate a stable window ID or request client close. Activation accepts an
	optional seat, reveals the workspace and restores a minimized window.
	Close does not accept a seat and reports acceptance, not client termination.

*window state --id ID --minimized|--maximized|--fullscreen true|false --json*
	Set exactly one presentation state. Minimize/maximize eligibility follows
	the existing floating-window policy; unsupported requests fail explicitly.

*window move --id ID --workspace-id ID|--output NAME --json*
	Move to a runtime workspace ID or the named output's active workspace.
	This does not request focus-following or workspace activation.

*workspace activate --id ID [--seat SEAT] --json*
	Activate a workspace and select its output for the seat, including when empty.

*workspace rename --id ID --name NAME --json*
	Change a workspace display name without changing its runtime identity.

*keyboard query|set|next [--seat SEAT] [--group ID] [--index INDEX] --json*
	Query returns the complete shell snapshot and takes no extra options. Set
	requires a zero-based index; next wraps. Control defaults to the seat's
	active group. Changes affect live XKB state and do not rewrite configuration.

*overview show|hide|toggle [--output NAME] --json*
	Control Aqueous's existing overview. Show and toggle require an output;
	hide takes no output. Repeated show/hide are idempotent.

*session exit --json*
	Request orderly compositor termination after an accepted acknowledgement.

Shell commands requiring a seat may omit it only when exactly one seat exists.
Mutations fail while locked or under external/comparison policy. JSON results
include ok, status and sequence. Initial state and commands have a five-second
deadline; an established watch has no idle timeout. Do not automatically retry
a timed-out mutation because it may already have executed. Exit codes are 0 for
success, 2 for malformed arguments and 1 for operation/transport failure.

The full wire contract and schema are installed under
_share/aqueous-protocols/stable/aqueous-shell-v1.md_ and
_share/aqueous-protocols/stable/aqueous-shell-v1.schema.json_.

# SECURITY

The Aqueous protocol is hidden from clients running through a Wayland security
context, along with the foreign-toplevel protocols it extends. The output
management global used by *outputs* is also hidden because the protocol contains
configuration requests, although aqueousctl only reads its event stream. Layout
mutation is limited to the active workspace of an explicitly named output;
cursor mutation accepts only validated theme names and sizes.

# SEE ALSO

*aqueous*(1)

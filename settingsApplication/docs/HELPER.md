# Canonical Aqueous configuration helper

Build with Zig 0.16.0 from `settingsApplication/` in a full Aqueous checkout
(the helper imports the sibling compositor's canonical configuration sources):

```sh
zig build config -Dhelper-only=true -Doptimize=ReleaseSafe
```

Every build is helper-only; the GUI build and Quark dependency are removed.
`zig build` and `zig build config` both install the canonical helper. The older
helper-only/model-only options remain accepted. `zig build test` runs the backend,
shared parser and subprocess tests without GUI development libraries.

Stage a package without an old settings executable:

```sh
DESTDIR=/tmp/aqueous-config-package PREFIX=/usr \
  AQUEOUSCTL_BINARY=/path/to/matching/aqueousctl \
  packaging/install.sh --helper-only
```

This installs `aqueous-config`, the canonical `aqueousctl` reload command, GPL
license and backend/command documentation. It installs no desktop entry, icon,
theme, Quark files or DMS/Noctalia integration. DESTDIR stages files only. For
distribution packaging, declare runtime dependencies on libc and the libraries
used by the matching aqueousctl build (including libwayland-client). Font
inspection/synchronization uses fontconfig (`fc-list`, `fc-match`); optional
toolkit targets use GLib/GSettings and their desktop schemas when installed.
Package managers must resolve these runtime dependencies; this staging script
does not invoke a package manager. Distribution packages can explicitly add
`--with-dms-appearance` to `packaging/install.sh` to stage the backend-only DMS
typography bridge; default and `--helper-only` installs remain neutral. A running
Aqueous compositor supplies reload acknowledgements. Pearl and these helper executables are sufficient for the
settings frontend; the retired GUI is not required.

Executables are discovered through PATH. Protocol 1 retains `version`,
`snapshot`, `validate`, `apply`, `raw`, `--request -`, and `--shell none`.
Use neutral shell mode for Pearl. Apply performs the canonical save and one
reload; a successful command exit or `accepted` reply does not count as an
`applied` acknowledgement. `--report-reload yes` keeps the legacy stderr report.
Clients must inspect capabilities before using additive interfaces.

`candidate_impact_v1` classifies window-rule, custom-binding, named snap-layout
and legacy snap-zone changes through their collection semantics. The helper
validates both the original and candidate collections, including rule ordering,
explicit false/zero and field removal, command arguments, layout references and
zone geometry. Known collection changes report `runtime_non_display`; proven
equivalent collections report `none`. Classification comes from the canonical
sources, including raw edits, rather than the caller's mutation type or a file
name. Mixed display changes still require native display projection and preview.

Unknown collection fields, malformed original values, unsupported commands,
ambiguous declarations and multiline source remain `complete:false`; protected
apply rejects them. The classifier uses native binding parsing/command decoding
and native storage limits, so a legacy writer accepting a value does not by
itself prove that the compositor can represent it.

Helper 0.8.1 adds [protected collection transactions](PROTECTED_COLLECTIONS.md).
Negotiate `protected_collection_apply_v1` and `collection_preconditions_v2` for
source-checked rebasing and mandatory full-candidate digest enforcement. Legacy
requests retain their existing behavior; mixed display changes still use the
native preview contract.

Helper 0.8.2 adds [structured display declarations](DISPLAY_MUTATIONS.md).
Negotiate `display_declaration_mutations_v1` for source-bound declaration IDs,
explicit set/unset edits, profile CRUD/order and membership operations. Full
candidate validation, digest binding and native preview protections still apply.
Legacy monitor mutations now reject unknown fields instead of ignoring them.

Always use a private HOME, XDG_CONFIG_HOME, XDG_STATE_HOME, XDG_RUNTIME_DIR and
private bus/compositor for integration testing. Do not point tests at a running
desktop. Hardware feature acceptance is separate from headless testing.

The additive observation and result contracts are defined in the
[helper schema](aqueous-config-additions-v1.schema.json); protected collection
requests are documented in [PROTECTED_COLLECTIONS.md](PROTECTED_COLLECTIONS.md). For recoverable
results use `apply --result v1 --operation-id ID`; query lost replies with
`operation-status --operation-id ID`. The shared document and journal sources
now live at `compositor/aqueous/ConfigDocument.zig` and `ConfigTransaction.zig`;
backend imports retain their compatibility wrapper.


Helper 0.8.3 adds negotiated display preview feature diagnostics. Use
`aqueous-config preview-features --shell none` for capability and qualification
status, or append `--token TOKEN` for target/observed/restoration evidence from
an existing lease. These read-only commands require native
`display_preview_feature_policy_v1`; they do not create or confirm a preview.
The existing snapshot/result contracts remain unchanged. See
[physical preview qualification](../../docs/physical-display-preview.md#negotiated-feature-diagnostics)
for reason codes, response semantics, and acceptance-only feature selection.

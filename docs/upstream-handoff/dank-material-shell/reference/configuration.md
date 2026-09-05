# Aqueous configuration contract for shell providers

This is the A6 contract from the [DMS implementation plan](../PLAN.md).
The compositor shell protocol owns runtime observation and typed actions.
`aqueous-config` owns persistent configuration and toolkit synchronization.
The existing Aqueous Settings plugin remains supported alongside future upstream
DMS settings providers. Adding these contracts does not implement those upstream
providers or change user enablement preferences.

## Discover the helper

Helper 0.7.1 adds an additive `capabilities` array to version and snapshot JSON,
retaining protocol version 1. Existing frontends requiring 0.7.0 remain compatible.
A provider should check both protocol version and the capabilities it uses.

```sh
aqueous-config version
aqueous-config snapshot --shell dms
aqueous-config validate --shell dms --request -
aqueous-config apply --shell dms --request -
```

Use JSON stdin for requests. The existing 4 MiB limit and expected-generation
check apply. An old helper without capabilities requires its existing documented
version-specific contract; absence is not permission to silently ignore fields.

| Capability | Existing contract |
| --- | --- |
| `schema_fields` | Snapshot `fields`, categories, defaults, aliases and typed constraints |
| `validate` | Validate the complete request without saving |
| `generation_check` | `expected_generation` prevents saving over external configuration edits |
| `stdin_requests` | `--request -` accepts bounded JSON on stdin |
| `atomic_file_replace` | Individual TOML files are replaced atomically with backups; multi-file saves are not one filesystem transaction |
| `monitor_modes` | Configured monitor changes include mode, position, scale and transform |
| `live_outputs` | Advertised live monitor modes accompany configured/offline monitors |
| `keybinds` | Schema-backed built-ins, unbound actions and custom bindings |
| `window_rules` | Ordered rules and raw configuration access |
| `cursor_sync` | Canonical cursor settings, live compositor update and toolkit adapter reports |
| `typography_sync` | Canonical typography, available fonts/faces and adapter reports |
| `shell_dms` | DMS mode avoids Noctalia writes/reloads |

These are helper capabilities, not a promise that every external toolkit, font,
monitor mode or runtime compositor is available. Inspect individual adapter
reports and live capabilities. For the complete request format, inspect the tested Aqueous helper and plugin
sources (`plugin/helper/` and `dms-plugin/README.md` in the Aqueous repository).
Capture their version/snapshot output as fixtures; reuse the shared helper rather
than introducing a second persistent configuration implementation.

## Preview, Apply and conflict handling

1. Obtain a fresh snapshot and retain its generation with the draft.
2. Stage typed or raw edits. Resolve conflicts between them before validation.
3. Validate the complete intended request.
4. Apply through the helper with the retained `expected_generation`.
5. Read the response and observe the resulting compositor state separately.

The helper does not offer a new persistent display-preview API. A DMS provider
can preview connected displays using existing wlr output management: test the
configuration, retain the live configuration, apply the candidate, and offer
Keep/Revert. Propagate the actual asynchronous apply result. Persist only after
Keep through the helper. A successful file save does not by itself prove that a
physical monitor accepted the configuration; report subsequent runtime failures.

Revert a preview only if the current live configuration still matches that
provider's candidate. If another tool changed it, show a conflict instead of
restoring an obsolete snapshot over newer state. Hotplug and configuration reload
also require a fresh snapshot. Preserve offline entries, EDID identities, custom
modes and fractional refresh rates. DPMS and automatic battery refresh changes
are runtime policy, not changes to canonical preferences.

On stale generation, retain the draft and ask the user to reload/reconcile it.
On uncertain apply timeout, inspect saved state before retrying. On toolkit sync
failure after a successful canonical save, show partial success and use the
existing explicit retry flags (`sync_cursor`, `sync_typography`). Do not overwrite
TOML directly from QML or add a second serializer in DMS core.

## Ownership with multiple frontends

Aqueous TOML is canonical. Both the plugin and an upstream provider may edit it
through the same generation contract; opening either UI does not authorize an
automatic rewrite. Keep DMS-specific typography adaptation in the active DMS
frontend. Do not have two background color/font/cursor synchronizers repeatedly
writing each other's output. Automatic synchronization should be explicitly owned
by one enabled provider; manual Apply remains available through either UI.

The existing plugin maps Aqueous typography into DMS family, weight and scale.
Exact face/slant/width and separately scaled bars are partially represented;
retain that reporting. Cursor control updates the compositor and supported launch
paths, while existing clients that supply cursor surfaces retain their own policy.
The portal plugin has a separate purpose and lifecycle; do not couple screen
sharing to settings-provider enablement.

## Frame reservations and appearance

At audited DMS commit `59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`,
`Modules/Frame/FrameExclusions.qml` creates one thin layer-shell surface per frame
edge using namespace `dms:frame-exclusion` and a positive exclusive zone. Aqueous's
existing layer-shell arrangement subtracts those reservations from the usable
output area and releases them when the client disappears.

The isolated shell integration test maps all four edge reservations, verifies
width/height shrink by the sum of opposite edges, kills the client, and verifies
full restoration. Therefore this implementation adds no second margin lease.
The normal Wayland resource lifetime already provides the needed lease. Keep
configured Aqueous gaps separate; do not reserve the same frame edge twice.
Physical mixed-scale rendering and the full upstream connected-mode UI remain
release checks.

Use ordered `[[layer]]` rules in `rules.toml` for explicit layer namespaces. The
first match wins. A frame exclusion is an invisible reservation and should not
receive blur. For example, place this before any intentional broader DMS rule:

```toml
[[layer]]
namespace = "dms:frame-exclusion"
blur = false
blur_popups = false
```

Inspect `aqueousctl scene` to identify actual visible DMS surface namespaces on
the target version, then add exact rules for those surfaces where blur is desired.
Do not blanket-match every Quickshell application. For ordinary DMS toplevel
windows, inspect `aqueousctl windows --json` or `inspect --rule` and match the
actual application identity. No user appearance configuration is installed or
rewritten by the shell API implementation.

## Evidence and remaining upstream work

The helper's existing tests cover generation conflicts, validation, raw/typed
writes, monitor modes and adapter retries. The 0.7.1 change adds discovery metadata;
it does not replace those paths. The [DMS implementation plan](../PLAN.md)
separates native DMS settings providers and its asynchronous output-apply result
fix. Those changes belong upstream and are not prerequisites for the local
Aqueous Settings plugin.

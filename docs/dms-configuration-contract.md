# Aqueous embedded configuration contract

The canonical `aqueous-config` helper owns persistent configuration and toolkit
synchronization through `settingsApplication/src/backend/`. Pearl supplies the
settings UI; the former GUI and shell settings plugins are retired. DMS providers
and external scripts use the same helper backend. It retains
protocol 1, capability discovery, and `version`, `snapshot`, `validate`, `apply`,
and `raw` commands. Requests accept `--shell dms|noctalia|none` and
`--request PATH|-`; the default shell remains `noctalia` for compatibility.
The compositor shell protocol owns runtime observation and typed actions.

## Backend API and ownership

`backend.execute(allocator, io, command, shell, request, control, writer)` accepts
in-memory requests for snapshot, raw, Validate, and Apply. It does not read stdin,
parse CLI arguments, mutate process environment, or terminate the caller. The
caller owns operation memory and control state until completion. CLI clients use
protocol/version metadata and capability discovery before using additions.

The CLI preserves the JSON response and capability contract used by existing
providers. Its Apply also requests the backend's normal compositor reload;
canonical persistence and target synchronization keep their existing semantics.

The operation retains the six-file document model, schema fields and aliases,
unknown keys/comments, inherited overrides, generation checks, window-rule order,
snap layouts/zones, keybindings, output modes/scale/mirroring, and explicit cursor
and typography synchronization. Request data is bounded to 4 MiB and each raw
TOML file to 1 MiB. Validate uses the same structural checks without writing.

## Apply and recovery

1. Retain the loaded generation with the draft and resolve raw/typed overlap.
2. Validate and Apply the complete intended request in the backend worker.
3. Cancellation can stop preparation. Once commit begins, finish the existing
   backup/save/rollback procedure before reporting completion or accepting another job.
4. Individual files use atomic replacement; a multi-file update is not one
   filesystem transaction. Failed writes retain drafts and require inspecting
   saved state before another Apply if the outcome is uncertain.
5. Report canonical save separately from toolkit/shell synchronization and from
   physical display acceptance. Explicit retry flags remain `sync_cursor` and
   `sync_typography`.

External commands have bounded output, reaped process groups, and a five-second
maximum within the operation's thirty-second budget. Filesystem calls complete
normally; clients must treat an interrupted write as uncertain.
Opening settings or refreshing outputs does not authorize synchronization.

## Shell adapters

Shell mode is explicit: `none`, `dms`, or `noctalia`. Neutral mode preserves
canonical/toolkit behavior while skipping shell writes and reloads. Noctalia's
existing typography adapter remains compiled into the helper. The optional DMS
`aqueousSettingsAppearance` bridge uses SettingsData and checks durable storage,
returning a request ID and pending/saved/failed status. It provides no settings UI
and does not observe configuration in the background. Family, weight, and normal
text size are supported; exact face/slant/width and separately scaled bars remain
partial. Portal plugins have their own lifecycle.

See [the helper guide](../settingsApplication/README.md) for interfaces,
installation, upgrade, and remaining platform validation details.

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
it does not replace those paths. The [upstream PR guide](dms-upstream-pr-guide.md)
separates native DMS settings providers and its asynchronous output-apply result
fix. Those changes belong upstream and are not prerequisites for the local
canonical configuration helper.

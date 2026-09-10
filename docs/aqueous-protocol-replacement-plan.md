# Replace inherited River protocols with Aqueous protocols

Status: implemented and locally validated.

## Decision

Aqueous will completely replace the six inherited River protocol families with
Aqueous protocol families. The River names are inherited from the project's
origin; they are not a compatibility contract Aqueous intends to maintain.

The completed compositor will expose only the new Aqueous names for these
interfaces. Ship no River aliases, parallel globals, compatibility option,
fallback discovery, or deprecation period. Update all in-tree consumers in the
same change. External clients using these River interfaces must migrate to the
new XML definitions and regenerate their bindings.

This is a protocol namespace replacement. Preserve the existing functionality,
request/event order, argument types, enum values, interface versions, and
`since` annotations. Retain the `v1` family suffixes and current per-interface
versions; do not reset versions or redesign protocol behavior during this work.

## Scope

Replace all 23 interfaces across these six XML files:

| Existing file | Replacement file | Interfaces |
| --- | --- | --- |
| `river-window-management-v1.xml` | `aqueous-window-management-v1.xml` | 8 |
| `river-input-management-v1.xml` | `aqueous-input-management-v1.xml` | 2 |
| `river-xkb-bindings-v1.xml` | `aqueous-xkb-bindings-v1.xml` | 3 |
| `river-xkb-config-v1.xml` | `aqueous-xkb-config-v1.xml` | 3 |
| `river-libinput-config-v1.xml` | `aqueous-libinput-config-v1.xml` | 4 |
| `river-layer-shell-v1.xml` | `aqueous-layer-shell-v1.xml` | 3 |

Within these families, replace the `river_` prefix with `aqueous_` in protocol
names, interfaces, and references, including child objects such as
`aqueous_window_v1`, `aqueous_seat_v1`, and `aqueous_input_device_v1`.

Keep the existing Aqueous shell, window-info, capture-color, and socket IPC APIs.
Keep standard Wayland and upstream extension names (`wl_*`, `xdg_*`, `wp_*`,
`zwp_*`, `zwlr_*`, and `ext_*`). The inherited River layer-shell companion is
separate from the standard `zwlr_layer_shell_v1` implementation.

Preserve copyright and license notices and accurate historical attribution.
Unrelated internal River-named symbols are outside this protocol replacement.

## Implementation sequence

1. **Replace protocol definitions.** Rename the six files under
   `compositor/protocol/`. Update protocol/interface names, object argument
   references, enum references, and protocol descriptions. Handle references
   between window management, bindings, and layer shell together; likewise
   handle input management, libinput configuration, and XKB configuration
   together. Remove the old XML files rather than retaining copies.

2. **Regenerate bindings and migrate the server.** Update custom protocol inputs,
   generated interface names, and installed filenames in `compositor/build.zig`.
   Migrate uses of `wayland.server.river` and any client equivalent to the
   generated `aqueous` namespace, resolving local identifier conflicts. Update
   global creation, resource types, handlers, enum uses, addon interface strings,
   and protocol-related diagnostics throughout `compositor/aqueous/`, including
   types used by the integrated window manager. Keep global access restrictions
   and object lifecycle behavior intact.

3. **Migrate consumers and build fixtures.** Update all repository clients,
   registry name comparisons, generated C symbols/header filenames, XML paths,
   and scripts. Known consumers include `scripts/fixtures/exit-session.c`,
   `scripts/fixtures/xdg-dialog.c`, `scripts/test-xdg-dialog.py`, and Vulkan test
   scripts that build the exit-session client. Audit the CLI, shell adapters,
   packaging recipes, and integration fixtures for further dependencies.
   Regenerate bindings from the renamed XML instead of editing generated output.

4. **Update distribution and documentation.** Continue installing under
   `share/aqueous-protocols/stable/` with `aqueous-protocols.pc`; publish only the
   new filenames for these six families. Document that River-specific clients
   must migrate. Update README, architecture and interaction documentation,
   examples, and build-option descriptions to describe Aqueous protocols.
   Preserve the existing `external-policy` option and its behavior while changing
   the protocol it uses to `aqueous_window_manager_v1`. Removing that optional
   execution mode would be a separate architectural change.

5. **Validate the complete replacement.** Run the checks below and resolve
   failures before considering the migration complete.

## Validation and acceptance

- Parse all renamed XML and generate bindings successfully. Compare each
  definition with its predecessor after normalizing the prefix to verify that
  names and documentation are the only protocol changes.
- Build and run the existing relevant tests with default settings and with
  `-Dexternal-policy=true`. Exercise the optional external/compare modes using
  migrated clients as supported by the existing harnesses.
- Add a focused registry integration check that verifies the expected Aqueous
  globals and versions and rejects any advertised `river_*` interface. Exercise
  bindings and child objects through migrated clients; preserve restricted-client
  visibility and the single active external window-manager constraint.
- Run affected input/seat, XKB, libinput, layer-shell, dialog, window-management,
  and rendering checks where available. Report unavailable hardware-dependent
  coverage explicitly rather than treating a successful build as runtime proof.
- Verify the installation in a clean staging prefix contains the new XML files
  and no `river-*.xml` files. Audit packaging for stale-file handling on upgrades;
  do not delete arbitrary files from a user's existing installation.
- Audit maintained source, scripts, docs, and packaging for active `river_*`,
  `river-*.xml`, and generated `.river` namespace dependencies. Exclude generated
  caches and preserved historical/license material from the acceptance scan;
  references explaining this migration are also intentional.
- Confirm existing Aqueous shell/IPC consumers still work without introducing
  River fallback code. No live-session restart or installation is needed to
  prepare and test this change.

The migration is complete when the build, installed protocol definitions,
runtime registry, and in-tree clients consistently use the Aqueous names with
the existing protocol behavior preserved.

## Implementation results

- Replaced the six XML files and all 23 interfaces, generated binding inputs,
  compositor types, fixture clients, scripts, and active documentation references.
  A comparison against the previous definitions confirms that all content is
  preserved after normalizing namespace changes and protocol description names.
- Updated all source package variants and release/Gentoo staging to recreate
  generated protocol metadata before building. Package checks require all six
  new definitions; the binary package check also rejects retired River XML.
  Nix already builds in a fresh temporary prefix. Manual existing installations
  are not modified; the README explains the clean-prefix requirement.
- Added `compositor/scripts/test-aqueous-protocols.py` and its generated-binding
  C fixture, and wired the internal/external/compare matrix into CI. The fixture
  checks names and versions, cross-protocol seat/output objects, bindings, shell
  surfaces/nodes, keymap creation, acceleration configuration, virtual-device
  exclusion, exclusive window-manager ownership, sandbox visibility, and cleanup.
  The harness also builds the migrated exit-session fixture and uses it to end
  the optional external/compare sessions.

Local validation:

- Default Vulkan, diagnostic Pixman, external-policy Vulkan, and Xwayland-enabled
  external-policy Pixman builds succeeded.
- All 458 unit tests passed in each of the default and external-policy build
  configurations.
- Protocol integration passed in internal, external, and compare modes with
  Pixman and Vulkan. All four clean staging prefixes contain the new definitions
  and no retired XML files.
- Existing dialog/multi-seat, shell, and IPC integration suites passed. The dialog
  suite also covers layer-shell focus, session lock, overview, fullscreen pixels,
  and hit testing with the migrated input-management client.
- Shell/Python syntax, workflow YAML parsing, Zig formatting, and whitespace
  checks passed. The binary package check rejected a deliberately stale archive.

Reproduce the focused runtime check with:

```sh
python3 compositor/scripts/test-aqueous-protocols.py \
  --compositor /path/to/aqueous --renderer pixman --policy internal
```

Use `--policy external` or `--policy compare` with an external-policy build and
`--renderer vulkan` with a Vulkan build. The test uses private headless sessions
and retains its artifacts under `/tmp`.

Physical input-device enumeration and hardware-specific libinput settings are
not covered by these headless tests. Virtual keyboards are intentionally excluded
from those APIs. Full Arch/Nix/Gentoo package builds and remote CI execution were
not run. Existing Wayland scanner warnings about non-monotonic `since` annotations
remain unchanged because reordering messages would change the protocol.

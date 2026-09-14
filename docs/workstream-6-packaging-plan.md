# Workstream 6: separate core packages from desktop integration

Status: implementation is present in the working tree; platform and release
acceptance remain pending. Original inspected revision:
`28bfe788ca97aa46e64b11a6204b266a4e630143`. See the
[implementation/validation record](workstream-6-validation.md) and
[component packaging guide](packaging-components.md) for delivered behavior and
remaining checks. The sequence below remains the acceptance checklist.

The deliverable is a shell-independent package containing the compositor,
matching configuration helper and inspection client. Pearl can depend on that
package without pulling in welcome, another shell, session setup or host-policy
changes. Users who explicitly install the full Aqueous desktop retain a supported
session, welcome flow and their existing shell selection.

Compatibility constraint: `aqueous-git` and `aqueous-git-intel` remain legacy,
integrated desktop packages with their existing DMS integration. Do not split
them, turn them into metapackages, remove their bundled integration or migrate
their users to the new component packages on upgrade. Preserve their current
dependencies, build options, installed payload and session behavior. DMS
integration does not authorize overriding an existing shell selection. The new
core/session split is a separate packaging path for Pearl and opt-in consumers.

## 1. Current implementation and concrete gaps

| Area | Inspected behavior | Required change |
| --- | --- | --- |
| Arch source recipes | Shell selection is already neutral, but `aqueous` includes GTK welcome, session startup, portals, defaults and desktop dependencies | Split the non-legacy path; retain `aqueous-git` and `aqueous-git-intel` as integrated legacy packages |
| Helper staging | `settingsApplication/packaging/install.sh` defaults to helper-only; `install-config.sh` also installs the matching `aqueousctl` and docs | Reuse this neutral path in core; give `aqueousctl` one owner |
| DMS integration | Most source recipes invoke `--with-dms-appearance` and the DMS portal installer | Give the new component path an explicit DMS integration package; preserve legacy DMS staging |
| Welcome staging | `install-welcome.sh` also creates conditional shell units, global wants links, external shell-unit drop-ins, portal configuration and compositor defaults | Separate welcome UI, session runtime and shell-specific assets |
| Session startup | `aqueous-init` prepares selection, seeds defaults, exports environment and starts/restarts session services | Install only with the optional session component; preserve explicit startup behavior |
| Nix | One derivation bundles core/session/portal assets; it references Noctalia directly; the module defaults Noctalia on | Separate derivations/closures and require explicit session/shell selection |
| Binary distribution | `release.yml` assembles a combined tree independently; `PKGBUILD-bin` imports broad archive trees | Build component archives through shared staging and consume their verified manifests |
| Other installers | Fedora sources a single `package()` function; Gentoo stages a combined desktop separately | Update both consumers when changing the recipe interface |
| Existing hooks | `aqueous.install` and `aqueous-meta.install` print setup commands; those commands are not currently executed by the hooks | Keep documentation separate from executable actions; do not misreport printed commands as enablement |

This is no longer a fix for an unconditional Arch DMS dependency. The remaining
problem is component ownership and integration bundled into the compositor
package. The retired settings GUI must remain absent throughout the split.

## 2. Target package graph and file ownership

Use the following package roles for the new component path. Binary variants map
to those roles. Any future development or Intel core variants need distinct new
package names; the existing legacy names are reserved for integrated packages.

| Package | Owns | Dependencies and behavior |
| --- | --- | --- |
| `aqueous-core` | `aqueous`, `aqueousctl`, `aqueous-config`; private patched wlroots; compositor/helper licenses, manuals, schemas and protocol metadata | Required native runtime dependencies only; no package hook or session integration |
| `aqueous-session` | `aqueous-init`, `aqueous-wm`, session desktop entry, session target, environment/menu/default files, selection/action runtime and generic dispatch configuration | Matching core and session runtime tools; no shell or GTK welcome dependency |
| `aqueous-welcome` | GTK welcome executable, application entry, welcome autostart and UI/setup resources | Matching session, GTK and the installation/authentication tools actually used by welcome |
| `xdg-desktop-portal-aqueous` | Renamed portal backend, D-Bus descriptor, user service, portal descriptor and its license | Portal/PipeWire dependencies; no shell chooser, routing override or enablement links |
| `aqueous-integration-dms` | Aqueous DMS startup unit, appearance bridge, portal chooser/bridge and DMS plugin discovery assets | Matching session/portal components; integration assets alone do not install DMS |
| `aqueous-integration-noctalia` | Aqueous Noctalia startup unit and Noctalia-specific defaults/chooser integration | Matching session/portal components; integration assets alone do not install Noctalia |
| `aqueous-integration-pearl` | Aqueous-specific Pearl startup integration, including locker-survival semantics | Matching session; integration assets alone do not install Pearl |
| `aqueous-shell-dms`, `aqueous-shell-noctalia`, `aqueous-shell-pearl` | Dependency-only presets | Respective integration package plus its actual shell package |
| `aqueous` | Compatibility desktop metapackage and informational documentation | Core, session, welcome, portal and all three thin integration packages; preserves existing selection without installing all three shells |
| `aqueous-meta` | Existing optional full application suite | Compatibility desktop plus its explicit application choices |
| `aqueous-git`, `aqueous-git-intel` (existing legacy packages) | Their existing combined compositor/helper/session/welcome/DMS integration payloads | Preserve existing dependencies, Intel build behavior and session integration; remain independently installable without depending on the new component packages |

Pearl's standalone dependency must be `aqueous-core`, never `aqueous`, a shell
preset or `aqueous-meta`. The Aqueous Pearl session preset depends on Pearl;
core must never depend back on it. Confirm Pearl's package naming in its owning
repository before publishing the dependency change.

Legacy packages overlap the new components' installed paths. Model them as
alternative installations with explicit conflicts for overlapping owners; never
use `replaces` to force legacy users onto the split path or advertise legacy
packages as providers of the shell-independent `aqueous-core` contract. Switching
from a legacy package to core is an explicit user transaction, not an upgrade.

Thin integration packages solve the upgrade-selection problem: package metadata
cannot choose a dependency by inspecting each user's `session.toml`. The full
desktop keeps the small existing integration assets available for every previous
choice, while explicit presets carry actual shell dependencies. A new minimal
session can install only its desired integration or preset. The full desktop's
extra assets never enter the core dependency closure.

Ownership rules:

- Core owns each executable once. Reuse the helper stager's `aqueousctl` copy and
  require it to match the compositor build; do not ship a second standalone owner.
- Core has no `/etc` payload, Wayland session entry, user units, wants links,
  external service drop-ins, tmpfiles rules, udev rules, autostart entries,
  portal preferences or shell-plugin discovery links. Examples may live under
  `share/doc/aqueous-core/` without becoming active configuration.
- Portal implementation and portal routing have different owners. Session owns
  Aqueous desktop routing and a single generic chooser configuration; adapters
  provide implementations without overwriting that common file.
- Move `70-aqueous-uaccess.rules` out of core. Audit whether it is needed for the
  supported seat-management path; if retained, make it optional session/seat
  integration, with its input-access effect documented and tested.
- Keep wallpapers, Ghostty defaults and shell defaults out of core. Place each
  under the session/desktop or relevant shell package according to its consumer.
- Shared directories are allowed; shared regular files and symlinks are not.
  Assign license paths explicitly where current names use `$pkgname`. This rule
  applies within a co-installable component set; legacy packages keep their
  combined ownership and conflict with overlapping component owners.

## 3. Implementation sequence

### 6.1 Establish a machine-readable package contract

Create `packaging/components.json` with component roles, owned path patterns,
required files, forbidden core paths and dependency categories. Generate a
concrete manifest from each staged tree containing path, file type, permissions,
symlink target and content digest. Reject duplicate ownership and missing assets.
Record separate legacy baseline manifests and dependency/build metadata so the
split cannot silently alter their integrated payloads. Compare duplicate ownership
within supported installation sets, not across mutually conflicting alternatives.

Audit dependencies in all recipes against ELF dependencies, wrapper paths and
subprocess use. Classify each as build-only, core runtime, optional helper
integration, session, portal, welcome or shell-specific. In particular, trace
GTK, Python, Shelly, sudo, Ghostty, screenshot tools, clipboard tools, UWSM,
PipeWire, Fontconfig and GLib before moving them. Do not remove a dependency solely
because its name looks desktop-related; prove the remaining runtime works.

Record a release cohort: repository revision, component versions, architecture,
build variant, wlroots archive/patch digests, binaries and protocol capabilities.
The helper's version is independent of the compositor/package version; do not
require their numeric versions to be equal. Require the tested combination.

Completion gate: every existing installed path has one proposed owner, and the
core runtime dependency list has a concrete justification.

### 6.2 Implement shared, relocatable component staging

Introduce component stagers under `packaging/`, with a common entry point such as
`stage-component.sh COMPONENT`. Accept explicit built artifact paths,
`DESTDIR`, `PREFIX` and `SYSCONFDIR`. Package builds always stage into disposable
roots; staging performs file operations only.

Implement core first using the compositor install tree and
`settingsApplication/packaging/install-config.sh`. Copy only the declared core
payload, check the private-library RPATH and binary match, and preserve helper
documentation/schema installation. Missing binaries or optional-component
leakage are hard failures.

Separate `install-welcome.sh` into session-runtime and welcome-UI staging. Extract
selection loading, `prepare-session`, conditions and action dispatch from
the welcome backend into a shell runtime owned by session. Keep staging, manifest/release orchestration and new packaging tests in shell; use jq for JSON. Welcome implements
its reviewed setup transaction and installation UI, but removing welcome must not
break a configured session, its shortcuts or a shell unit's `ExecCondition`.

Make DMS appearance staging and DMS chooser staging independent of core. Remove
their writes to the shared portal configuration when installed as adapters.
Keep existing staging entry points and their default behavior available to legacy
recipes. New component callers must explicitly select the separated path. Shared
implementation may be refactored only with legacy payload and runtime parity;
otherwise leave legacy staging intact. Apply the session changes below to the
new path without changing legacy behavior through shared scripts or runtime code.

Completion gate: stage core, session, welcome, portal and each adapter separately
under `/usr` and a relocated prefix; verify manifests and zero host side effects.

### 6.3 Make session and shell integration explicitly selected

Preserve `session.toml` and current-session selection semantics. Installing core,
an adapter or upgrading packages must not write a selection or infer a replacement
from whichever executable happens to be present.

Move conditional Aqueous shell units into their adapters. Each must start only
for the selected shell in the Aqueous session. Preserve Pearl's existing locker
survival behavior and DMS's notification-bus ownership requirements.

Remove unconditional external-unit drop-ins from generic welcome staging. If
the optional session integration needs duplicate-start prevention, keep it scoped
to that explicit integration and make its condition permissive outside Aqueous.
It must not suppress DMS, Noctalia or Pearl in unrelated desktop sessions.

Define behavior for all selection states: Pearl, DMS, Noctalia, Nothing, missing
selected executable, missing adapter, malformed selection and ambiguous legacy
selection. Missing dependencies must produce a recoverable explanation; absence
of welcome must not cause a restart loop. Do not install a shell automatically
as a consequence of starting core or the neutral session runtime.

Keep compositor TOML mutations routed through `aqueous-config`. Package hooks
must not migrate per-user display/profile/keybind files. Explicit welcome setup
retains its existing review/conflict/rollback checks.

Completion gate: private-session tests prove exactly the selected shell starts;
Nothing starts none; unrelated graphical sessions remain unaffected; selection
and user-edited files survive upgrades and component removal.

### 6.4 Split Arch recipes and preserve provider compatibility

Convert the stable/source recipe to split package functions backed by the shared
stagers. Move runtime `depends`, `optdepends`, `backup`, `install`, `provides` and
`conflicts` to the correct package role. A source package may share a build step;
installing its core subpackage must not pull in optional runtime components.

Update `PKGBUILD`, `PKGBUILD-bin`, `PKGBUILD-meta` and the non-legacy
`PKGBUILD-DMS` path to use the component interfaces where appropriate.
Keep `PKGBUILD-git` and `GitPKGBUILD/PKGBUILD` (`aqueous-git`), plus
`PKGBUILD-intel` and `IntelPKGBUILD/PKGBUILD` (`aqueous-git-intel`), as legacy
combined recipes. Preserve their DMS appearance/portal integration, welcome,
session units, dependency behavior and Intel-specific build options.
`gitNoctalia/PKGBUILD` also publishes the `aqueous-git` identity: retain its
existing variant behavior and exclude it from the split rather than changing its
shell integration based on the package name. Do not rename or retire these
recipes as part of workstream 6.

New component providers provide the core interface and conflict
only with incompatible owners of that interface. Do not have core provide the
full `aqueous` desktop role: that could satisfy a desktop dependency without its
session. Bind tightly coupled components to the tested release/version/provider
cohort and exercise the dependency solver for mixed variants. Legacy packages
retain their existing provider semantics; component metadata must prevent
overlapping installations without making a normal legacy upgrade pull in core
or remove legacy integration.

Keep current desktop package names as compatibility entry points. Historical
names containing DMS or Noctalia must not silently select a shell: current
recipes already allow shell selection, so the old package name is not evidence
of the user's choice.

Do not attach `aqueous.install` to core. Keep informational desktop messages with
the desktop/session packages and update stale settings-UI dependency comments.
Preserve administrator-managed configuration through the package manager's
configuration-file mechanism.

Completion gate: real package-manager transactions in disposable roots install
core alone and complete desktops, upgrade legacy packages in place with their
DMS integration intact, and switch to components only when explicitly requested.
Verify no file conflicts, unintended dependency removal or shell selection
changes. Legacy builds must remain usable independently of component artifacts.

### 6.5 Split Nix derivations and explicit module integration

Extract independently consumable core, portal, session, welcome and adapter
derivations from `nix/default.nix`. Preserve a compatibility desktop composition
through the overlay/default facade and export a clearly named core attribute,
for example `aqueousCore`. Do not merely create multiple outputs while wrappers
still reference Noctalia or session paths from core.

Remove shell references, session substitutions, `providedSessions`, portal
registration and host-integration assets from the core derivation. Audit runtime
closure edges, including wrapper PATHs; core may retain required native tools
but must not retain shells/welcome through hidden references.

Keep importing a package separate from enabling `nix/module.nix`. Installing
`aqueousCore` alone must not set display-manager, UWSM, XWayland service, PipeWire,
portal, udev, tmpfiles or systemd-user options. Those remain explicit session
module behavior, with `sessionPackages` pointing at the session derivation.

Replace default-on Noctalia with explicit shell selection. Use an unset/default
selection that requires an explicit choice when enabling the managed session;
`none` is a valid choice. Map explicitly set legacy `noctalia.enable` values with
a deprecation message, and reject contradictory old/new settings. A configuration
that relied on implicit Noctalia must receive a migration error explaining the
new explicit choice before activation, rather than silently losing its shell.

Update `nix/overlay.nix`, source filtering and dependency inputs. Welcome's source
tree and all documentation installed by the helper must be included: the current
source filter does not include top-level `welcome` or `docs`.

Completion gate: evaluate/build core and each session choice; inspect actual
runtime closures; test legacy module migration, package-only installation and
explicit session activation in NixOS tests.

### 6.6 Publish component artifacts and update every consumer

Change `.github/workflows/release.yml` to build once and stage each component via
the shared entry point. Publish versioned core, session, welcome, portal and
adapter archives with manifests, cohort metadata and checksums. Use a documented
archive-root convention, preferably package-root `usr/` and optional `etc/`.

Maintain the existing full-desktop archive during migration by composing verified
component trees. Preserve its legacy root layout through an explicit conversion
step. The existing compositor-only archive lacks the helper; do not relabel it
as the complete core artifact without adding and validating that payload.

Update `PKGBUILD-bin` to select matching component archives and fail on checksum,
cohort, architecture or manifest mismatch. Replace broad copying followed by
deleting retired GUI files with verified component payloads. Inspect the final
archives as well as staging directories.

Update `scripts/fedora-install.sh` and its tests: it currently assumes one
`package()` and one RPM. Produce explicit component RPMs or expose a component
selector that preserves equivalent ownership/dependencies. Update
`scripts/gentoo-install.sh` to use shared component staging rather than its own
combined copy list. Keep existing full-desktop invocation semantics documented;
add an explicit core-only path to both.

Production artifact checks must reject the backend test driver and builds with
`display_preview_acceptance_build` or output fault injection enabled. Packaging
cannot turn workstream 5's test build into a production capability.

Completion gate: component source recipes, binary recipes, release archives, Nix
and other maintained component installers agree on contents and dependency roles.
Legacy recipes continue to build and stage their original integrated payloads
without depending on the new release archive layout.

## 4. Migration and removal matrix

Run these as actual package transactions with fixture user/system configuration,
not just static recipe checks:

| Starting state | Operation | Required outcome |
| --- | --- | --- |
| Clean system | Install core, then Pearl | No Aqueous session/welcome/other shell or active host-policy files |
| Existing non-legacy full desktop, each shell selected | Upgrade to split desktop | Existing selection and required adapter survive; no switch or extra shell installation |
| `aqueous-git` or `aqueous-git-intel` | Normal upgrade or reinstall | Same legacy package and integrated DMS/session payload; no component migration, missing integration or changed selection |
| Clean system | Install either legacy package | Existing integrated desktop behavior, including DMS integration and Intel options where applicable |
| Existing Nothing selection | Upgrade | Nothing remains selected |
| Custom TOML, portal configuration, unit overrides | Upgrade | User bytes preserved; documented package-manager merge files where applicable |
| Existing monolithic package | Replace with core-only explicitly | Old package-owned integration leaves the package database; personal files are retained |
| Core plus session plus welcome | Remove welcome | Session runtime and selected shell still work |
| Several shell adapters installed | Change selection explicitly | Exactly one selected shell starts; no ownership conflict on shared portal config |
| Selected adapter removed | Next session | No fallback shell selected automatically; clear recovery behavior |
| Legacy git/Intel package installed | Explicit switch to component packages, or back | Conflicting package-owned files transition cleanly; coherent compositor/helper/library cohort; personal state retained |
| Component provider installed | Switch component provider | Coherent core/helper/library cohort and no conflicting file owners |
| Existing Nix implicit Noctalia setup | Evaluate upgrade | Explicit migration guidance before activation, preserving the opportunity to keep Noctalia |

Never recursively delete user homes, mask user services, rewrite a greeter,
change device permissions or run `systemctl enable` from core packaging. The
operator may choose to remove package-owned session integration; that does not
authorize deleting personal configuration or editing it to select a new shell.

## 5. Validation and delivery gates

1. **Manifest tests:** required and forbidden paths, duplicate ownership,
   symlink resolution, permissions, licenses, prefix relocation, staged-tree
   composition and artifact extraction. Retain the legacy combined-package
   assertions in `packaging/tests/test-dms-git-packaging.py`, including
   GTK/Shelly/etc., DMS assets and conditional session behavior. Add separate
   component assertions instead of replacing legacy expectations with core-only
   expectations. Compare legacy dependency metadata and staging manifests before
   and after shared installer changes.
2. **Side-effect tests:** run stagers and hooks with private HOME/XDG roots and
   command spies for service management, package installation and privilege
   escalation. Verify executable behavior, not substring matches against printed
   documentation. No writes outside the staging root.
3. **Runtime tests:** real staged core binaries, helper version/snapshot/validate,
   schema availability, matching `aqueousctl` reload, private headless startup,
   bundled-library resolution and missing-optional-tool behavior. Do not count
   placeholder binaries in packaging fixtures as runtime evidence.
4. **Session tests:** extend `welcome/tests/test-worker.sh`,
   `packaging/tests/test-aqueous-init.sh`, portal tests and helper retirement/DMS
   bridge tests for separated runtime/UI/adapters and upgrade preservation.
5. **Package tests:** clean-chroot Arch builds, disposable upgrade/remove
   transactions, actual binary archive installation, Fedora RPM component tests
   and Gentoo component staging. Cover supported architectures/variants or mark
   a missing build as unverified rather than passing it by manifest similarity.
   Include clean installation and in-place upgrades of both legacy package names,
   their mirrored recipes, and explicit transitions in both directions between
   legacy and component installations. Test real legacy DMS session behavior
   after changes to shared runtime or staging code.
6. **Nix tests:** evaluate explicit options and migrations, build components,
   inspect closures and run session integration tests. Core evaluation/build
   must not require selecting a shell.
7. **Release test:** unpack the exact publishable archives into clean roots,
   recheck manifests/cohort hashes and smoke-test their binaries before
   publication. A combined release may not supply missing files to a core test.

Deliver in reviewable changes: (1) ownership contract and core stager, (2)
session/runtime/welcome/adapter extraction, (3) Arch split and migration tests,
(4) Nix split and module migration, (5) releases/Fedora/Gentoo consumers, and
(6) packaged-artifact acceptance plus Pearl dependency handoff. Changes 3–5
depend on the shared component interfaces from 1–2; release acceptance depends
on all of them.

Workstream 6 is complete only when installing Pearl with core provides the
matching compositor/helper/client without shell/session side effects, explicit
desktop installs still work, existing selections survive migration, and the
legacy `aqueous-git` and `aqueous-git-intel` packages continue to work with their
existing DMS integration. The actual distributed artifacts must satisfy their
respective component or legacy contracts. Publish the exact package
names/versions, component manifests, source revision, helper/protocol capabilities,
test results and any unverified platform limitations with the handoff.

# Workstream 6 implementation and validation

Implementation is in the working tree on top of
`28bfe788ca97aa46e64b11a6204b266a4e630143`. This is not a released package or full
platform acceptance. The detailed plan remains the acceptance checklist.

The packaging/session Python added in the first implementation has been removed.
Staging, manifests, composition, release checks, session runtime and their new
regression/smoke tests are now Bash with jq/coreutils/libarchive. Fedora package
file lists and core spec adaptation also run in shell. Welcome's setup worker has
since moved into its Zig executable; pre-existing packaging Python test suites
remain build-time checks.

Implemented:

- Independent core/session/welcome/portal/integration staging and a machine-readable
  ownership contract. Core has no active host or shell integration.
- Session runtime independent of welcome; explicit selection, missing-adapter
  recovery, current-session snapshots and conditional shell units.
- Stable Arch and binary split packages, explicit shell presets, release-coupled
  dependencies and versioned conflicts with the old monolith. The legacy git and
  Intel recipes retain their combined desktop payload. The native welcome port
  removes their Python runtime dependency and updates shared session callers.
- Separate Nix derivations and explicit NixOS shell selection with legacy-option
  migration checks. The welcome dependency is checksum-pinned separately.
- Component release manifests/cohorts/checksums, real-binary verification,
  safe extraction checks, combined-archive compatibility and a generated,
  checksum-pinned binary recipe.
- Explicit Fedora/Gentoo core selectors. Fedora's default keeps its legacy git
  desktop recipe. Gentoo records only known installed payload paths and protects
  edited system configuration on reinstall/removal.

Local evidence (x86_64):

| Check | Result |
| --- | --- |
| Shell component tests | Passed: composition, ownership, tampering, unsafe archives, build policy, relocation, independent runtime, missing adapters, snapshots and Gentoo reinstall/removal |
| Fedora orchestration tests | 7 existing tests passed; shell regressions cover core RPM metadata and no-dependency-install mode |
| Existing welcome tests | 17 passed |
| Legacy packaging regression | All six retained combined recipes passed, including git/Intel mirrors and the Noctalia variant |
| Existing session wrapper checks | Config seeding, cursor environment, IPC exports and nested isolation passed |
| Compositor build | ReleaseSafe build completed with the repository's patched wlroots and generated production metadata |
| Portal and chooser builds | Both completed from their pinned sources |
| Shell core runtime smoke | Private headless startup, staged wlroots mapping, helper snapshot/validate and aqueousctl output inspection passed |
| Portal checks | Actual backend config precedence and packaging checks passed |
| Arch source packaging | All 11 subpackages created with makepkg from prepared real build artifacts; dependency checks/build phases skipped for this packaging-only run |
| Arch binary packaging | All 11 binary subpackages created from the verified component payloads; archive download/dependency checks skipped for this local packaging-only run |
| Release artifacts | All components and the combined archive created; manifests, cohorts, helper metadata and extracted archive contents verified |
| Nix | All expressions parsed; core/desktop and managed Noctalia system derivations evaluated; implicit selection, explicit none/Noctalia, legacy mapping, conflicts and missing Pearl package assertions behaved as expected |

The runtime smoke used helper `0.8.2`, protocol `1`. The helper was the existing
workstream 3 build; helper source was not changed by workstream 6. The compositor,
portal and chooser were rebuilt for this work. Local release candidates record
that the source tree is dirty and report their actual compositor/helper versions.

Still required before declaring distribution acceptance:

- Clean-chroot source builds and dependency-solving install/upgrade/remove tests,
  including legacy-to-component transitions and both legacy DMS desktop sessions.
- Full Nix builds and runtime closure inspection, followed by NixOS session boots.
  Evaluation does not prove a derivation builds or a desktop starts.
- Native Fedora RPM builds and Gentoo host testing. Local installer tests use
  fixtures at the package-manager boundary and do not install packages on the host.
- Non-x86_64 builds, physical seat/login testing and the full migration matrix.
- A release tag containing these changes, publication of its generated component
  archives/binary recipe, and Pearl's dependency update in its owning repository.

No host packages were installed or services enabled while implementing this work.
Downloaded build/evaluation dependencies and test artifacts were kept under `/tmp`.
Workstream 5's physical display preview acceptance remains independently pending.

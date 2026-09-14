**Aqueous dependencies for Pearl: implementation plan**

Status: workstreams 1–4 are implemented locally. Workstream 5 has runtime/recovery hardening and an isolated SDR acceptance harness; physical execution and feature acceptance remain pending. Workstream 6 remains proposed.

Original inspected baseline: `1d038dc3bafa0044d9599f8f51f84105a6a85bb3`, helper `0.8.0`, protocol `1`. This plan was prepared against `de1d4fe015ad8ef01066c3e5350484ce609ff825`. The relevant helper/compositor implementation is unchanged between these revisions; Arch packaging now supports explicit shell selection. Do not describe the current Arch package as requiring DMS or starting it unconditionally.

The outcome is six independently reviewable workstreams: semantic collection classification, protected collection transactions, structured display declarations, isolated capture color metadata, physical display previews, and core/session packaging separation. Capability names and new module names for pending workstreams are proposals to finalize with their schemas, not existing APIs.

**Delivery order and shared requirements**

Implement steps 1 and 2 first to unblock ordinary protected collection edits. Step 3 builds on their candidate validation discipline. Steps 4 and 6 can be developed independently. Step 5 can develop backend support against existing raw candidates while step 3 is underway, but acceptance must exercise the final structured path too.

| Workstream | Deliverable | Completion gate |
| --- | --- | --- |
| 1 | Collection semantics in candidate impact | Valid collections classify completely; ambiguity remains blocked |
| 2 | Collection preconditions compose with protected apply | Fresh candidate validation and digest binding survive races/rebasing |
| 3 | Structured display declaration/profile API | Exact declaration edits produce canonical sources and native projections |
| 4 | Scene capture destination color description | Metadata and reference pixels agree before successful frame readiness |
| 5 | Physical preview and recovery | Recorded acceptance for each supported backend/feature combination |
| 6 | Separate core and optional session packages | Core installation leaves shell selection and host integration alone |

Keep the helper as the only component that edits configuration TOML. Preserve native display leases, writer locking, journal recovery, operation receipts, generation checks and digest binding. `store:true` never substitutes for the required protected display transaction, including deferred outputs. Unknown request fields must not appear to succeed without implementing their meaning.

Use additive negotiated contracts where possible and retain protocol 1 compatibility. New protected behavior must have an explicit advertised capability and schema; do not silently reinterpret older requests. Increase the helper version when shipping the changes. Runtime display capabilities must describe the running backend and supported operations, not merely compiled code.

**1. Complete semantic collection classification**

Implementation status: completed locally. Shared collection schema primitives and ordered semantic comparison now feed candidate impact. The backend collection regression suite covers structured and raw operations, malformed original/candidate semantics, ordering and protected saves. Helper and compositor unit tests, existing helper contract/transaction suites, and the native headless mixed collection/display preview/commit regression pass. This is software evidence only; it does not accept physical display support or complete workstream 2's digest/rebase contract.

Primary files: `settingsApplication/src/backend/impact.zig`, `operations.zig`, `schema.zig`; canonical rule, command/keybind and layout parsers under `compositor/aqueous/`.

Implementation:

- Extract reusable collection validation/description from `writeCollectionSchema`, `validateWindowRules`, `validateCustomKeybind`, `validateConfiguredSnapZones` and their mutation helpers. A proposed `collection_semantics.zig` module should share the compositor's semantic definitions instead of creating a second rule or command language.
- Parse original and candidate collections into ordered semantic records. Preserve repeated declarations, rule order, missing/inherited fields, explicit false/zero, and custom command arguments. Validate names, references, geometry and limits for named layouts and zones.
- Classify add/update/delete/move and field removal through those records. Respect the existing operation surface: rules have move operations, bindings have add/update/delete, and named layouts currently use replacement. Detect reorder effects within replacement without inventing unsupported request operations.
- Recognized collection changes yield `runtime_non_display`; proven semantic equivalence yields `none`. A malformed original cannot become a complete proof merely because the candidate is valid. Preserve diagnostics and uncertainty for unknown fields, sections or unsupported syntax.
- Replace the blanket multiline-string uncertainty only where a quote-aware parser can prove the relevant semantics. Otherwise retain `complete:false`. Never scan apparent tables inside string contents. Raw changes may classify when their complete before/after semantics are proven; request provenance is not evidence of correctness.
- Compute changes per file before combining effects. Fix the current empty-declaration check so changes in another file cannot hide an unclassified table addition/removal. Preserve order-sensitive effects even when keys/values are unchanged.
- Keep display sections on the existing native display path in mixed candidates. Never mark entire rules, wm or layout files non-display.

Tests: extend backend tests with the reported `{app_id:"pearl-test-*",floating:false,opacity:0.8}` case; every supported collection operation; null removal; repeated/identical rules and reorder; empty declarations; command quoting/arguments; named layout defaults, references and geometry; malformed original/candidate extensions; multiline strings containing fake headers; and mixed scalar/collection/display/raw changes.

Acceptance: all known valid cases produce complete, correct effects; malformed or ambiguous semantics cannot pass protected apply. Assert classification as well as mutation results, not only successful validation.

**2. Compose collection preconditions with protected transactions**

Implementation status: completed locally in helper `0.8.1`, protocol `1`. Clients negotiate `protected_collection_apply_v1` and `collection_preconditions_v2`, then opt in with `collection_apply_version:1`. Source descriptors bind the selected path, existence and exact bytes; apply requires the freshly calculated full candidate digest even without a preview token. Validation and apply report requested/effective generations, rebasing and verified base preconditions. Existing clients retain their contract. See [PROTECTED_COLLECTIONS.md](../settingsApplication/docs/PROTECTED_COLLECTIONS.md) for the request schema, client flow and error handling.

Validation: helper unit tests, backend collection/transaction suites, request/response schema checks, deterministic source races, crash/receipt recovery and staged packaging pass. The native headless suite verifies collection saves with generation/digest-bound reload acknowledgments and preserves mixed display preview protection. This is software evidence only; physical display acceptance remains pending.

Primary files: `operations.zig:checkCollectionPreconditions`, `operations.zig:handleRequest`, `candidate_review.zig`, `control.zig`, `receipts.zig`, and the shared `ConfigDocument.zig`/`ConfigTransaction.zig` where needed.

Implemented contract: `protected_collection_apply_v1` with `collection_preconditions_v2`, documented alongside the legacy `collection_preconditions_v1` behavior. Contract parsing, source binding and shared digest checks live in `collection_transaction.zig`.

Implementation:

- Separate mutation keys from permitted transaction metadata. Allow protected-apply and digest fields for an otherwise collection-only request; continue rejecting unrelated mutations, raw-file edits and display edits from the stale-generation exception.
- Require an exact precondition for every affected collection source. Include selected path, source bytes and source existence in a versioned precondition representation so an absent/empty source or source-precedence change cannot silently reuse old IDs. Account for layout-default changes even when they accompany another collection mutation.
- Re-read and verify those sources under the writer lock. Resolve collection IDs against the verified source. Permit a stale global generation only when every affected source is unchanged. External edits, reorders or retargeting of an affected source require a new snapshot.
- Rebuild and validate the candidate against current files, recompute impact and calculate its full canonical digest. A supplied digest must be enforced for the negotiated protected collection contract even when no `preview_token` is present; today the comparison occurs in the preview-token branch.
- Missing/malformed/mismatched digest rejects the protected apply before writes or synchronization side effects. Preserve the existing mandatory digest comparison for preview commits and use one shared implementation for comparison/error handling.
- Report the original requested generation, effective base generation, whether rebasing occurred, canonical candidate sources and fresh digest in validation results. Retain the final under-lock source check, operation identity, recovery journal and reload acknowledgment requirements.
- Keep raw/structured overlap rejection. Continue requiring native preview authorization for mixed display changes; collection preconditions cannot authorize that path.

The normal client flow is: validate with generation/preconditions, review the returned fresh candidate, then apply with its effective generation and digest. If an unrelated file changes between review and apply, the full candidate digest may change despite safe collection IDs; reject the old digest and require fresh validation/review. A matching collection precondition authorizes ID reuse, not approval of changed candidate bytes.

Tests: unrelated-source edits before validation and between validation/apply; touched-source edits/reorder; missing or extra preconditions; absent/empty sources; source-precedence changes; incorrect, omitted and malformed digests; protected apply without preview token; raw/structured conflicts; mixed display requests; lock races; duplicate operation IDs/lost replies; and helper failure around persistence/reload.

Acceptance: protected collection editing succeeds against a freshly validated matching candidate and cannot save a different candidate through stale indices or a stale digest. Old protocol clients retain their documented behavior outside the new negotiated contract.

**3. Add structured display declarations and profile mutations**

Implementation status: completed locally in helper `0.8.2`, protocol `1`, with capability `display_declaration_mutations_v1` and request `display_declaration_changes`. Declaration IDs and mandatory source tokens bind the generation, selected path, existence and source bytes. Ordered batches support explicit set/unset, profile CRUD/order, membership and references to newly created nodes. Source overlap, stale IDs, ambiguous display syntax and contradictory operations fail before persistence. Primary-only declarations now participate in the canonical configured fold.

Validation: 61 helper and 502 compositor unit tests pass, along with the backend/source-race suite and request/response schemas. The private native headless suite verifies structured profile/raw projection equivalence, preview rollback and a mixed declaration/collection protected Keep with receipt replay and digest-bound reload acknowledgment. See [DISPLAY_MUTATIONS.md](../settingsApplication/docs/DISPLAY_MUTATIONS.md) for the implemented contract. Physical previews and feature acceptance remain pending under workstream 5.

Primary files: `operations.zig:writeDisplayDeclarations`, `operations.zig:applyMonitorChanges`, `schema.zig`, shared `ConfigDocument.zig`, `DisplayConfig.zig`, `DisplayModel.zig`, and `wm/output/config.zig`.

Implemented contract: `display_declaration_mutations_v1`, with a new request field separate from legacy `monitor_changes`; batch staging and strict validation live in `display_mutations.zig`.

Implementation:

- Publish a strict schema covering declaration add/update/delete/move, display policy fields, profile create/rename/delete/reorder, and output membership. Derive field types/ranges from the canonical display parser, including enabled, primary, identity matchers, HDR/VRR, mirroring and inheritance-related fields actually supported by that parser. Add parser support explicitly if a desired semantic is absent.
- Issue opaque IDs scoped to snapshot generation, source and exact declaration/profile occurrence. Duplicate declarations remain distinct. Never identify a writable declaration solely by monitor name or live connector. Validate ID shape, ownership and generation before staging edits.
- Use an explicit patch representation such as `set:{...}` plus `unset:[...]`: omitted keys are unchanged, false/zero/empty values are explicit values where valid, and unset removes the local value so canonical inheritance applies. Reject overlapping set/unset keys and unknown fields.
- Require source selection (`wm` or `outputs`) and parent/profile selection for creation. Editing legacy declarations must not silently migrate them or pick the first same-name declaration. Preserve the existing explicit user-override policy for system sources.
- Resolve all existing IDs against the initial snapshot before applying the batch. Define operation ordering and request-local references for newly created profiles/declarations. Reject contradictory updates, references to deleted parents and invalid moves. Profile deletion must explicitly choose whether to delete members or move them to a specified valid parent; no silent orphaning.
- Reject overlapping raw edits, legacy monitor mutations and other structured edits to the same affected source. Initially use conservative source-level conflicts. Stage all edits in memory through the shared document editor and validate the entire candidate before persistence.
- Return canonical candidate sources, fresh declaration IDs, configured/inherited values, candidate digest, impact and the existing native projection. Configuration editing capability does not imply physical preview support; retain per-feature unavailable reasons.
- Keep `monitor_changes` for compatibility and add strict unknown-key rejection so extra settings cannot be silently ignored. Do not claim support for enabled/primary/HDR/etc. through that legacy request.

Tests: every mutation and profile operation; duplicate names/declarations; disabled and offline outputs; inherited values versus unset/false/zero; profile order and membership; source precedence; malformed/cross-source/stale IDs; external reorder; multiple operations shifting indices; invalid references; protected raw/structured equivalence; and native preview/commit of valid candidates.

Acceptance: every advertised field has observable canonical semantics and a validated write path. Physical operations remain unavailable until step 5 acceptance; candidate generation alone cannot authorize unprotected persistence.

**4. Describe the destination colors of isolated scene captures**

Implementation status: completed locally. Scene render completion carries a destination SDR qualification through SHM and DMA-BUF copy to per-frame metadata. Actual foreign-toplevel capture remains isolated; mapped/unlocked checks gate source requests and copies. Disabled/empty sources and render failures terminate pending frames. Protocol version 1 is unchanged.

Validation: the complete pinned wlroots patch build, 502 compositor unit tests, CPU/Vulkan capture fixtures and private Pixman/Vulkan compositor checks pass. Independent PQ/sRGB and PQ/BT.2020 reference samples verify SDR conversion, with separate DMA-BUF SDR pixel checks. Tests cover overlapping windows, security-context restrictions, lock/unmap denial, repeated frames, failed formats and source destruction. See [isolated-capture-color.md](isolated-capture-color.md) for the supported paths and remaining limitations. This render-only GPU evidence does not accept physical display previews.

Primary files: `compositor/patches/wlroots/0015-ext-capture-formats-and-color.patch`, `compositor/protocol/aqueous-capture-color-v1.xml`, `compositor/aqueous/Server.zig:handleToplevelCaptureRequest`, and window capture-source lifecycle code.

Implementation:

- Trace the wlroots scene source render/copy path and identify the actual destination encoding for each supported renderer and buffer path. Carry that description from the operation that chooses/converts the pixels to the frame's color-info sender.
- For supported SDR capture, produce a documented sRGB-primary destination with a supported SDR transfer function. HDR input must be converted through the renderer's supported color pipeline before that description is emitted. Unsupported conversion paths remain unavailable/fail safely.
- Send exactly one terminal metadata result (`done` or `unavailable`) before a successful frame's `ready`; metadata becomes usable only if the frame succeeds. Handle source/frame destruction and listener cleanup without stale descriptions or use-after-free.
- Retain true foreign-toplevel scene isolation. Never substitute output capture/cropping or derive transfer/gamut from pixel format/bit depth. Do not attach source HDR mastering metadata to converted SDR output as though it described the destination.
- Update both protocol XML copies and generated integration metadata. Existing v1 permits scene descriptions, so valid additional metadata need not itself break the wire protocol. If clients need an advertised guarantee beyond per-frame results, define/version that guarantee explicitly rather than changing v1 expectations silently.

Tests: extend `scripts/fixtures/ext-capture-formats.c` and `scripts/test-ext-capture-formats.sh`, plus a real compositor scene-capture fixture. Exercise overlapping unrelated windows, protected/unmapped sources, source destruction before ready, failed frames, repeat capture, SDR reference patches and HDR-to-SDR reference patches. Compare decoded destination pixels with an independent expected conversion/tolerance. Test supported SHM/DMA-BUF paths separately and record unsupported ones.

Acceptance: isolated captures have correct reference pixels and matching metadata in the required event order. A Pearl-compatible client can export supported SDR captures and rejects missing/unsupported gamut or transfer descriptions. Gamma 2.2 conversion must occur once at the client boundary, not be mislabeled as sRGB.

**5. Enable physical previews only after backend and recovery acceptance**

Implementation status: runtime/recovery hardening and the acceptance harness are implemented locally. Confirmation now waits for complete observed output state and presentation, rollback survives partial backend commits, inactive sessions defer restoration until resume, and commit deadlines wait for the canonical writer's decision. Per-output backend/feature reasons and presentation evidence are exposed with `display_preview_completion_v1`.

The non-shipping `-Ddisplay-preview-acceptance=true` build permits explicitly selected DRM connectors to exercise ordinary SDR with advertised modes. Production still advertises `display_preview_hardware:false`. HDR, VRR, hardware mirroring and custom modes remain separately gated. The physical harness uses disposable configuration, preserves per-case evidence, and never promotes simulated or incomplete results to acceptance. See [physical-display-preview.md](physical-display-preview.md).

Acceptance status: incomplete. No dedicated physical seat/recovery console was confirmed for this run, so physical modesetting, hotplug/lease/suspend faults and hardware rollback have not been accepted. Hardware-specific enablement requires those recorded results; software and simulated-harness passes cannot close this workstream.

Primary files: `compositor/aqueous/DisplayPreview.zig`, `OutputManager.zig`, `Output.zig`, `wm/output/Service.zig`, `ConfigTransaction.zig`, IPC capability reporting, and relevant renderer/output integration.

Implementation:

- Inventory backend support for state testing, commit completion and restoration. Replace the broad headless-only gate only for specifically supported operation/backend paths, with runtime capability reporting and precise rejection reasons for the remainder.
- Test the complete intended output state before apply; track asynchronous completion across all participating outputs. Start the confirmation interval only once the intended state is actually applied. Reject unsupported or partial plans and retain at least one usable non-mirrored output.
- Verify restoration of mode, enablement, position, transform, scale, profile selection, mirror relationships and color/adaptive-sync state. Handle hotplug, lease loss, competing state changes, suspend/resume and delayed/failed commits. Report partial rollback and fallback honestly.
- Audit crash recovery at every lease/commit/journal boundary. An unconfirmed preview must not become persistent startup configuration. A confirmed transaction must have a deterministic recover-or-rollback result after helper or compositor death; extend durable state only where existing recovery cannot establish that result.
- Keep ordinary SDR modesetting, HDR, VRR and mirroring as separate acceptance groups. Enable each only after its backend/renderer tests pass. Rejection remains the correct behavior for unsupported groups, including deferred/store-only requests that still require a native lease.

Tests: retain `scripts/test-display-preview.py` as the headless regression suite. Add an explicitly selected physical test harness that records GPU/driver/kernel, connector, monitor EDID/model, renderer, modes and feature support, source revision and helper version. Cover Keep, explicit revert, timeout, owner disconnect, helper crash, compositor restart, failed test/commit, partial multi-output commit, hotplug during preview/commit and fallback when restoration is impossible. Use a recovery console and disposable configuration/session for destructive fault scenarios.

Acceptance: publish an artifact per supported backend/feature group showing restored usable output and consistent disk configuration/receipts after every relevant failure. Hardware availability and execution are required inputs; headless success cannot close this workstream or justify enabling untested HDR/VRR/mirroring paths.

**6. Split compositor/helper packaging from session and shell presets**

Detailed implementation sequence, package ownership, migration matrix and release
gates: [workstream-6-packaging-plan.md](workstream-6-packaging-plan.md).
Implementation is now in the working tree. See
[workstream-6-validation.md](workstream-6-validation.md) for passing checks and
pending platform/release acceptance; full distribution acceptance is not claimed.

Primary files: non-legacy `PKGBUILD*` paths, `aqueous.install`, `aqueous-meta.install`, `settingsApplication/packaging/install.sh`, `packaging/install-welcome.sh`, session/portal installers, `nix/default.nix`, `nix/module.nix`, release workflows and affected installer documentation/tests. Legacy git/Intel recipes and mirrors remain compatibility regression targets, not split-package conversion targets.

Implementation:

- Preserve `aqueous-git` and `aqueous-git-intel` as legacy integrated packages with their existing DMS integration, dependencies, payload, build options and session behavior. Do not split them, convert them to metapackages or migrate their users automatically. Preserve legacy staging entry points and shared runtime behavior; the new components are a separate opt-in packaging path. Keep the `gitNoctalia/PKGBUILD` variant's existing behavior under its legacy `aqueous-git` identity.
- Define package ownership before moving files. Proposed `aqueous-core` owns compositor, helper, aqueousctl, bundled wlroots, required runtime libraries, licenses, protocol data and manuals. Optional session/welcome packages own GTK welcome, session launchers, autostart, shell selection units/drop-ins and session defaults. Shell-specific presets own their shell dependency, appearance bridges and chooser integration. Decide portal backend ownership explicitly; its shell-dependent chooser/routing configuration belongs with the relevant integration package.
- Preserve a compatibility `aqueous` desktop/metapackage for users who want the existing full session. Pearl should depend on the core package, never that desktop metapackage. Version-couple compositor/helper/library artifacts and define exact file ownership/conflicts to avoid duplicate installs.
- Use helper-only staging for the core. Keep DMS appearance integration opt-in on the component path and preserve it in the legacy packages. Do not install the retired settings GUI. Keep GTK/shelly/sudo and optional terminal/shell dependencies out of the core unless a demonstrated core runtime requirement exists.
- Core package installation/upgrade must not enable services, seed user TOML, select/replace a shell, install shell service overrides, rewrite portal preferences or modify host display-manager configuration. Move those assets and actions to the explicitly selected session/preset path.
- Split Nix package outputs/options consistently. A core install must not import the session module; explicit session integration may configure the host. Make shell activation opt-in, including the current default-on Noctalia option.
- Update source and binary package metadata, release artifact publication, migration notes and ownership transitions together. Retain existing user files and state on upgrade/removal; do not silently turn an existing selected session into a different shell.
- Make legacy packages and overlapping component owners conflict explicitly. Do not use automatic replacement or have legacy packages provide the shell-independent core contract; a legacy-to-component switch requires an explicit user transaction.

Tests: extend `packaging/tests/test-dms-git-packaging.py`, helper retirement/packaging tests, relevant portal tests and installer checks. Stage core and each optional preset separately; inspect dependencies, file manifests, hooks and symlinks. Test full-session upgrades, core-only installation, package removal, source/binary variant parity and Nix core/session selections. Inspect shipped binary artifacts, not only local staging fixtures.

Legacy validation: retain combined-package and DMS integration assertions for `aqueous-git` and `aqueous-git-intel`; verify clean installs, in-place upgrades, mirrored recipe parity and explicit switches to/from components. Shared installer/runtime refactors must preserve their behavior.

Acceptance: installing Pearl plus core provides matching compositor/helper tools without installing or enabling a shell, legacy GUI or session setup. Explicitly installing a session/preset retains documented integration behavior. Existing selections/configurations survive migration. `aqueous-git` and `aqueous-git-intel` continue to work as legacy DMS-integrated packages without automatic conversion to the new packaging path.

**Validation, documentation and release handoff**

For helper changes, run `zig build test test-driver` from `settingsApplication/`, then relevant backend transaction/integration suites using private HOME/XDG directories and a private bus/compositor. For compositor changes, use the build and relevant checks in `docs/contributing.md`; rebuild patched wlroots for capture changes. Never run automated mutation/fault tests against the user's live desktop. Packaging checks should stage into temporary roots. These are implementation acceptance tasks, not tests claimed by this planning change.

Update `settingsApplication/docs/aqueous-config-additions-v1.schema.json`, helper/native capability schemas, `settingsApplication/docs/HELPER.md` and client examples with each contract. Workstream 2 replaced HELPER.md's missing `T11.md` and `T11_TRANSACTIONS.md` links with shipped contract documentation.

Each workstream should ship its tests and docs in the same review. Use separate commits/PRs for collection semantics, transaction/digest composition, display mutations, capture metadata, physical backend support/acceptance, and package separation. Physical feature acceptance may require multiple subsequent reviews, and must remain visibly pending until evidence exists.

The final Pearl handoff must include exact source revision, helper version, protocol/capability versions, supported backend/renderer combinations, canonical request/response examples, regression results and physical acceptance artifacts. Pearl can then repin and enable only capabilities actually negotiated. Keep unsupported controls and PNG export restrictions until the corresponding implementation and evidence are available.

# Document the supported Aqueous session

Copy this file into the DankLinux-Docs checkout. It describes the documentation
work accompanying Aqueous integration in DankMaterialShell. DMS upstream support
and released dependency versions must be verified before publishing support claims.

## Objective and baseline

Add an Aqueous setup guide and an accurate feature/support statement. Integrate
with the repository's existing compositor guide structure, navigation and style.

Aqueous now has a versioned shell protocol, live `aqueousctl` state/actions,
keyboard layout control, shortcut inhibition, overview control and graceful
logout. Helper `aqueous-config` 0.7.1 adds capability discovery while retaining
protocol 1. These Aqueous changes were implemented in its working tree; identify
the actual released version that includes them before writing requirements.

The previous integration audit used DMS commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3` and common QML commit
`26396ce432d6c71c3f5367438f96f4a8d667e160`. This is a historical prospective 1.7
baseline, not a released minimum version. No upstream PRs were opened as part of
the Aqueous implementation. Check current merged work rather than assuming the
planned adapters/settings providers are available.

## Implementation steps

1. Read project instructions and find the current compositor guides, navigation,
   supported-compositor table, installation and portal troubleshooting pages.
2. Establish exact released Aqueous, aqueousctl, aqueous-config, DMS and
   Quickshell dependencies. Correlate each documented feature with merged DMS
   support and desktop test evidence. Describe development builds explicitly if
   documentation precedes a release.
3. Add an Aqueous session guide covering installation through the supported
   packaging source, session startup, DMS launch, session environment and
   compositor keybindings using the actual released syntax. Respect existing
   direct-session and UWSM guidance; do not start duplicate shell processes.
4. Explain configuration ownership: Aqueous TOML is canonical, persistent writes
   go through `aqueous-config`, and the Aqueous Settings plugin can coexist with
   merged native DMS providers. State which features require which frontend.
   Runtime layout/keyboard/DPMS changes do not imply persistent configuration.
   Only one provider should own automatic cursor/font/color synchronization.
5. Document portal routing and screen sharing separately from screenshots.
   Preserve the independent `aqueousPortal` plugin and user enable/disable
   preference. Verify exact portal packages, service names and configuration
   from the released integration; do not invent generic replacement settings.
6. Document native overview controls and standard frame exclusive zones.
   Aqueous already supports four frame-edge reservations and automatic cleanup.
   Do not instruct users to add an unimplemented margin command or duplicate
   frame reservation using persistent gaps.
7. Add diagnostics and failure guidance: missing/outdated CLI, unsupported
   protocol, wrong/nested session, stream disconnect, stale IDs, locked-session
   rejection, ambiguous seat and partial toolkit synchronization. Explain that
   runtime IDs expire on compositor restart and timed-out mutations may have
   executed already.
8. Update navigation/support tables to match verified capabilities, link to the
   setup guide, and run the repository's documentation build/link checks.

## Diagnostic commands

Run in the Aqueous session being diagnosed:

```sh
aqueousctl shell capabilities --json
aqueousctl shell snapshot --json
aqueousctl shell watch --json
aqueous-config version
aqueous-config snapshot --shell dms
```

The watch command intentionally remains running and prints an initial snapshot
then changes. Stop it with Ctrl+C. Window titles and configuration paths can
appear in output; request only the relevant redacted diagnostics in bug reports.
Capability discovery is more reliable than assuming support from executable names.

## Verification and review evidence

Verify setup instructions in a fresh session with the real DMS daemon and
Quickshell. Record package/revision versions and results for workspace/taskbar
integration, focused-output routing, keyboard layout changes, logout, lock,
overview, frame layout, screenshots, settings save/restart and plugin coexistence.
Use physical outputs for DPMS, hotplug, fractional scale/rotation and resume.
Test a real browser/recorder stream for portal support.

Distinguish unsupported features from untested combinations. Existing Aqueous
headless protocol and DMS QML settings-host tests do not certify a full desktop
session. Submit packaging fixes in their owning repositories and plugin registry
submissions separately. A Quickshell dependency change is only needed if DMS
actually chooses a native identity bridge; the aqueousctl adapter avoids that
requirement.

Suggested PR title: `docs: add the verified Aqueous session setup guide`.
Lead the description with the supported setup and tested dependency set; include
the documentation build/link checks and any outstanding feature limitations.

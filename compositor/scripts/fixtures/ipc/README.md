# IPC v1 fixtures

Captured from the isolated headless test in `scripts/test-ipc-integration.py`.
The session token is sanitized; IDs and sequences illustrate one run and must
not be treated as persistent desktop identities. Snapshots contain a complete
empty desktop with two outputs, workspaces, seat and session entities.

Validate frames against `protocol/aqueous-ipc-v1.schema.json`, resolving its
`aqueous-shell-v1.schema.json` reference locally. Sequencing, byte limits and
transaction ordering are additionally tested against the running compositor.

To deliberately regenerate, set `AQUEOUS_IPC_FIXTURES_DIR` to this directory
when invoking the isolated IPC test with a freshly built diagnostic compositor.
Ordinary test runs never rewrite fixtures.

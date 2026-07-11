## Aqueous Architecture

Aqueous is split across two cooperating components that share a single
git repository:

1. **`Aqueous` (and friends)** — the transitional .NET 10 / C# 14 policy client.
   Talks Wayland to the compositor, owns layout/workspaces/rules, drives the
   bar, the input daemon, and the output daemon.
2. **`compositor/`** — Aqueous, based on the Zig
   [River](https://codeberg.org/river/river) compositor. Produces the `aqueous`
   binary that the transitional `aqueous-wm-client` connects to.

### Why monorepo

- **Tight Wayland-protocol coupling.** The WM and the compositor agree
  on a specific set of Wayland protocols and `river-control-unstable`
  revisions. Changes to those usually need to land in lockstep; a
  monorepo lets that happen in a single PR.
- **Atomic cross-component changes.** Refactors that touch both sides
  land in one commit — `git bisect` then works across the boundary.
- **One clone, one CI, one release cadence.** No submodule init,
  no detached HEADs, no "did you forget `--recurse-submodules`?".
- **Single packaging artifact.** The Arch package (`PKGBUILD`) builds
  both binaries from the same source tree and ships them together.

### Layout

```
Aqueous/                       # repo root
├── Aqueous/                   # transitional policy client (.NET, AOT-published)
├── Aqueous.OutputDaemon/      # output config sidecar
├── Aqueous.Tests/
├── Aqueous.OutputDaemon.Tests/
├── compositor/                # Aqueous compositor (Zig) — see ORIGIN.md
│   ├── build.zig
│   ├── river/
│   ├── protocol/
│   └── LICENSES/
├── scripts/
│   └── build-compositor.sh    # canonical Zig builder
├── bin/                       # build outputs (gitignored)
│   └── aqueous
├── launch_river.sh            # dev launcher; calls build-compositor on demand
├── PKGBUILD                   # Arch package; builds WM + compositor
└── docs/
```

### Build flow

- `dotnet build` only builds the .NET side. It does **not** invoke
  `zig` — contributors who only touch C# do not need a Zig toolchain
  for that command to succeed.
- `scripts/build-compositor.sh` is the canonical builder for the
  compositor. It runs `zig build` inside `compositor/` and stages the
  resulting compositor binary as `./bin/aqueous`.
- `launch_river.sh` is the dev-time orchestrator: it triggers a
  `dotnet build`, calls `scripts/build-compositor.sh` if `bin/aqueous`
  is stale/missing, then launches the transitional policy client under the compositor.
- `PKGBUILD` mirrors the same two-step flow: `dotnet publish` for the
  WM, then `zig build --prefix …` for the compositor, and installs both
  binaries into one Arch package.

### Compositor source provenance

`compositor/` was imported from the upstream RiverDelta repository via
`git subtree`; see `compositor/ORIGIN.md` for the exact commit and date.
There is no live link to upstream — pulling future RiverDelta changes is
a manual cherry-pick or a `git subtree pull` after temporarily re-adding
the upstream remote. License texts under `compositor/LICENSES/` are
preserved verbatim.

### Override knobs

| Env / property         | Effect                                                         |
|------------------------|----------------------------------------------------------------|
| `AQUEOUS_COMPOSITOR_BIN` | Path to a prebuilt compositor; bypasses the in-tree build.     |
| `AQUEOUS_OPTIMIZE`     | Zig optimize mode (`Debug`, `ReleaseSafe`, …). Default: `Debug`. |
| `AQUEOUS_MOD`          | Modifier key for WM bindings (`Super` / `Alt`).                |
| `AQUEOUS_NESTED`       | Set to `1` when running inside a host Wayland session.         |

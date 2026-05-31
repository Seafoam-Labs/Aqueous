# Building riverdelta

## Quick start

```sh
cd compositor
zig build -Dllvm=true
```

The resulting binary is `zig-out/bin/riverdelta`.

## Why `-Dllvm=true` is required

By default `build.zig` builds the compositor with Zig's self-hosted x86_64
backend and self-hosted ELF linker (`use_llvm = false`, `use_lld = false`).
On toolchains shipping **gcc 16.x** the system C runtime startup object
`crt1.o` contains an `.sframe` section with `R_X86_64_PC64` relocations that
Zig's self-hosted linker (as of 0.16.0) does not yet handle:

```
error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c
    note: in /usr/lib/gcc/x86_64-pc-linux-gnu/16.1.1/../../../../lib/crt1.o:.sframe
```

This is a toolchain/linker limitation, not a riverdelta source issue: all Zig
sources compile cleanly (35/38 build steps) and only the final link fails.

The `-Dllvm=true` flag forces the LLVM backend together with the `lld` linker
(`use_llvm = use_lld = true`), which handles the `.sframe` relocations and
links successfully.

Alternatives if you prefer the self-hosted backend:

- Use a toolchain with gcc <= 15 (its `crt1.o` has no `.sframe` section).
- Build inside a container that ships an older gcc.

## Running the tests

```sh
cd compositor
zig build test -Dllvm=true
```

This runs the `common/slotmap.zig` tests and the pure output-scaling logic
tests in `river/scaling.zig` (clamp, 1/120 round, preferred-buffer-scale ceil).

## Scaling integration harness

A headless end-to-end harness for the output-scaling pipeline lives at
`scripts/test-scaling.sh`. It launches `riverdelta` under the wlroots headless
backend and asserts the scale-change behavior. See `doc/scaling-test-matrix.md`
for what it covers and the manual matrix it complements.

```sh
cd compositor
zig build -Dllvm=true
bash scripts/test-scaling.sh
```

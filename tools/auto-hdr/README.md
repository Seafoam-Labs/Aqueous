# Auto HDR Training Stack

Execution tooling for Stage B of the Auto HDR work — implements the M0 data
pipeline and the M1–M3 training loops of `docs/auto-hdr-model-training-plan.md`
on the ship-quality corpus from `docs/auto-hdr-ship-corpus-training-plan.md`.

## Layout

```
tools/auto-hdr/
  autohdr/
    color.py      PQ/sRGB/working-unit color math (1.0 == 203 nits)
    tonemap.py    SDR degradation ensemble: bt2390, bt2446a, hable, aces, reinhard
    exr_io.py     EXR read/write (OpenEXR >= 3.2)
    dataset.py    pair dataset + class-balanced sampler (index from generate_pairs)
    models.py     Option A GainNet / Option B LUTPredictor / Option C ParamRegressor
    losses.py     PQ L1 + expansion-only + UI-identity (+TV, LUT-floor)
    metrics.py    PQ delta (primary), PU21 (verify constants), histogram distance
  tools/
    download_polyhaven.py   CC0 HDRI bulk pull via the verified public API
    generate_pairs.py       HDR -> tone-mapper ensemble -> 8-bit SDR pairs + index
    train.py                training loop (AMP, AdamW, cosine+warmup, per-class val)
    evaluate.py             test-split metrics vs no-op and analytic-curve baselines
    export.py               ONNX export, .cube bakes, gain-map demo (helper shape)
  fish/
    setup.fish download_data.fish make_corpus.fish
    train.fish evaluate.fish export.fish
```

## Quickstart

```fish
cd tools/auto-hdr
fish fish/setup.fish                          # ROCm venv + tensor probe
fish fish/download_data.fish --limit 25       # smoke pull (~2 GB)
fish fish/download_data.fish                  # full 4k catalog (~82 GB)
set UI_DIR ~/screenshots                      # optional negative-class source
fish fish/make_corpus.fish
set AUTO_HDR_OPTION C
fish fish/train.fish --smoke 64 --epochs 2 --workers 0 # pipeline shakedown
fish fish/train.fish --epochs 40                     # Option C (M1)
set AUTO_HDR_OPTION A
fish fish/train.fish                                 # Option A (M3)
fish fish/evaluate.fish
fish fish/export.fish --demo some_sdr_screenshot.png
```

Environment overrides: `DATA_DIR`, `RUN_DIR`, `EXPORT_DIR`, `UI_DIR`,
`AUTO_HDR_OPTION` (A|B|C), `AUTO_HDR_CKPT`, `AUTO_HDR_DEVICE`
(`rocm` by default in `train.fish`), `AUTO_HDR_VENV`, and
`AUTO_HDR_PYTHON`. `AUTO_HDR_PYTHON` takes precedence in the launcher
scripts, so it can point directly at a server-managed ROCm environment.
`AUTO_HDR_VENV` relocates the managed environment, including onto shared
storage. Setup creates `.venv-rocm` by default, keeping it separate from
any existing CPU-only `.venv`.

The Linux x86-64 requirements install AMD's validated PyTorch 2.9.1 and
Triton wheels for ROCm 7.2 on Ryzen AI Max/gfx1151. Those wheels require
Python 3.12; setup uses `python3.12` by default, or
`AUTO_HDR_BOOTSTRAP_PYTHON` when it lives elsewhere. `setup.fish` runs a
real GPU tensor operation and fails if it cannot initialize ROCm, preventing
a full training run from silently using CPU. To use a prebuilt environment,
skip setup and set `AUTO_HDR_PYTHON` to its Python executable. Set
`AUTO_HDR_REQUIRE_ROCM 0` only when preparing the venv on a node where the
GPU is intentionally unavailable; training still requires ROCm by default.

## Hardware expectations (96 GB shared-memory machine)

Assumption: an APU with unified memory (e.g. Ryzen AI Max-class iGPU, ~40 CU)
where "96 GB shared" is system RAM the GPU draws from, and a ROCm/PyTorch
build that supports the iGPU (`setup.fish` probes it). If the box
has a discrete GPU instead, scale the numbers by its throughput.

Setup installs the Python stack, not the host driver. The server must expose
`/dev/kfd` and `/dev/dri/renderD*` to the training process; AMD's validated
Ryzen ROCm 7.2 configuration also requires Python 3.12 and the supported
Ubuntu 24.04/kernel stack.

Workload model: Option A (base 32, ~180k params) does roughly 8–12 GFLOP
forward+backward per 256² sample. A modern iGPU sustains ~3–10 effective
TFLOP/s on conv workloads with AMP, i.e. ~300–800 samples/s. A corpus of
~250k pairs then costs ~5–15 min/epoch.

| Run | Estimate (iGPU, AMP) | CPU-only fallback |
| --- | --- | --- |
| Option C shakedown (`--smoke 64`) | minutes | minutes |
| Option C full (40–100 epochs) | 2–6 h | 1–2 days |
| Option B full (200–300 epochs) | 12–36 h | weeks — don't |
| Option A full (200–400 epochs) | **1.5–4 days** | weeks — don't |

The 96 GB of shared RAM is a genuine asset: the pair store (HDR EXR + 8-bit
SDR PNGs) fits in the page cache, and the dataset lazy-loads, so I/O stops
being the bottleneck after the first pass. Nothing in the stack assumes more
than ~8–16 GB for the model/batches themselves.

If `setup.fish` reports no CUDA/ROCm device, use CPU only for `--smoke`
pipeline checks; do the real runs once a supported ROCm stack is installed
(ROCm exposes the device through PyTorch's CUDA path).

## Model sizes

| Option | Params (base 32) | fp16 artifact | Runtime form |
| --- | --- | --- | --- |
| A GainNet | ~180k (≤1M budget; scale with `--base`) | ~0.4 MB ONNX (~0.8 MB fp32) | gain texture per surface |
| B LUTPredictor | ~200k encoder | ~0.4 MB ONNX | + 9³ LUT ≈ 4.4 KB fp16 (17³ ≈ 29 KB) |
| C ParamRegressor | ~150k | ~0.3 MB ONNX | or a baked `.cube` — zero runtime ML |

## Coordinate contract (must match the compositor)

- Working units: linear, `1.0 == 203 cd/m²` (wlroots `sdr_white_level`).
- Training SDR inputs are white-normalized (diffuse white at 1.0), mirroring
  the shader's `white` placement; HDR targets are the original scene in
  working units; `peak_rel = HdrLevel.nits() / 203`.
- Peaks are sampled from the compositor's expansion-capable presets
  (400 and 1000 nits → 1.97 / 4.93) with optional jitter.
- Option C's `analytic_expand` is a literal mirror of
  `compositor/aqueous/auto_hdr.zig` (knee 0.8, smoothstep mask, peak clamp).

## Verification caveats (be honest about these)

- `bt2390` follows the ITU-R BT.2390 EETF structure (PQ-domain smoothstep
  knee, KS = L_target, luminance-ratio chroma scaling). Cross-check against
  HDRTV4K's BT.2390 variant during M0 validation.
- `bt2446a` is an approximation of ITU-R BT.2446 Method A — fine as ensemble
  diversity, not standards-conformant until verified.
- PU21 constants in `autohdr/metrics.py` are from memory of the reference
  implementation; verify before quoting absolute PU21 numbers. PQ delta is
  the trustworthy primary metric until then.

## Milestone mapping

| Plan milestone | Tooling here |
| --- | --- |
| M0 data pipeline | `download_polyhaven.py`, `generate_pairs.py`, `dataset.py`, `tonemap.py` |
| M1 Option C | `train.py --option C` |
| M2 Option B | `train.py --option B` |
| M3 Option A | `train.py --option A` |
| M4 evaluation | `evaluate.py` (no-op + Stage A curve baselines built in) |
| M5 export | `export.py` (ONNX, .cube, gain-map helper artifacts) |

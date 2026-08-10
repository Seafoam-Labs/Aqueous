#!/usr/bin/env python3
"""Pair synthesis: HDR ground truth -> tone-mapper ensemble -> paired SDR
(docs/auto-hdr-ship-corpus-training-plan.md S5).

Scans --hdr-root recursively for EXR files, and for each asset writes one
8-bit sRGB PNG per (exposure jitter x tone mapper), plus a JSONL index that
the dataset consumes. The HDR side is *not* duplicated: index entries point
at the original EXR with an `hdr_scale` factor (scene-white placement in
working units, 1.0 == 203 nits).

EXRs under auxiliary modality directories (S2R stores depth/diffuse/flow/
normal maps next to its frames) are not training frames and are skipped;
see --exclude-dirs.

The SDR side includes real-world quantization (8-bit), which is part of the
degradation the model must invert.

Splits are assigned at source-ID granularity (hash of the asset path), so no
asset leaks across train/val/test.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from autohdr.color import SDR_WHITE_NITS, luminance, srgb_oetf  # noqa: E402
from autohdr.exr_io import read_exr  # noqa: E402
from autohdr.tonemap import MAPPERS  # noqa: E402


def split_for(source_id: str) -> str:
    bucket = int(hashlib.md5(source_id.encode()).hexdigest(), 16) % 1000
    if bucket < 850:
        return "train"
    if bucket < 925:
        return "val"
    return "test"


def quantize(srgb: torch.Tensor) -> np.ndarray:
    """8-bit with triangular-ish dither, returns (H,W,3) uint8."""
    noise = torch.rand_like(srgb) - 0.5
    q = (srgb * 255.0 + noise).round().clamp(0, 255).to(torch.uint8)
    return q.permute(1, 2, 0).cpu().numpy()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--hdr-root", required=True,
                    help="directory scanned recursively for .exr")
    ap.add_argument("--out-dir", required=True,
                    help="writes sdr/ PNGs and the index")
    ap.add_argument("--index", required=True, help="output index.jsonl")
    ap.add_argument("--ui-dir", default=None,
                    help="directory of UI/desktop screenshots (negatives)")
    ap.add_argument("--mappers", default=",".join(MAPPERS),
                    help=f"comma list from: {','.join(MAPPERS)}")
    ap.add_argument("--exposures", type=int, default=2,
                    help="exposure-jitter variants per asset")
    ap.add_argument("--white-nits", type=float, default=SDR_WHITE_NITS,
                    help="scene white for EXR value 1.0, in nits")
    ap.add_argument("--sdr-white-nits", type=float, default=SDR_WHITE_NITS,
                    help="SDR target white of the degradation")
    ap.add_argument("--default-class", default="scene",
                    choices=["scene", "video"])
    ap.add_argument("--video-substrings", default="s2r,sequence",
                    help="paths containing these become class 'video'")
    ap.add_argument("--exclude-dirs",
                    default="depth,diffuse,flow,normal,camera_params",
                    help="skip EXRs under any directory with one of these "
                         "names (S2R auxiliary modalities are not frames)")
    ap.add_argument("--max-assets", type=int, default=None)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    root = Path(args.hdr_root).resolve()
    out_dir = Path(args.out_dir).resolve()
    sdr_dir = out_dir / "sdr"
    sdr_dir.mkdir(parents=True, exist_ok=True)
    mapper_names = [m for m in args.mappers.split(",") if m]
    video_subs = [s for s in args.video_substrings.split(",") if s]

    all_exr = sorted(root.rglob("*.exr"))
    exclude = {d for d in args.exclude_dirs.split(",") if d}
    exr_files = [p for p in all_exr
                 if not exclude & set(p.relative_to(root).parts)]
    if args.max_assets:
        exr_files = exr_files[:args.max_assets]
    print(f"{len(exr_files)} EXR assets under {root} "
          f"({len(all_exr) - len(exr_files)} excluded)")

    entries = []
    stats = {"pairs": 0, "assets": 0, "skipped": 0}
    for p in exr_files:
        rel = p.relative_to(root)
        stem = "_".join(rel.with_suffix("").parts)
        try:
            arr = torch.from_numpy(
                np.ascontiguousarray(read_exr(p)).astype(np.float32)
            ).permute(2, 0, 1)
        except Exception as exc:  # noqa: BLE001
            print(f"skip {rel}: {exc}")
            stats["skipped"] += 1
            continue
        arr = torch.nan_to_num(arr, nan=0.0, posinf=0.0, neginf=0.0)
        arr = arr.clamp(0.0, 3.0e4)
        _, h, w = arr.shape
        equirect = w == 2 * h
        is_video = any(s in str(rel).lower() for s in video_subs)
        split = split_for(stem)

        for j in range(args.exposures):
            ev = float(rng.uniform(-1.5, 1.5))
            white_eff = args.white_nits * (2.0 ** ev)
            hdr_nits = arr * white_eff
            flat = arr.flatten()
            sample = flat[:: max(1, flat.numel() // 1_000_000)]
            src_peak = float(sample.quantile(0.9995)) * white_eff
            src_peak = max(src_peak, 2.0 * args.sdr_white_nits)

            for name in mapper_names:
                sdr_nits = MAPPERS[name](hdr_nits, src_peak, args.sdr_white_nits)
                disp = (sdr_nits / args.sdr_white_nits).clamp(0.0, 1.0)
                srgb = srgb_oetf(disp)
                png_rel = Path("sdr") / f"{stem}_e{j}_{name}.png"
                Image.fromarray(quantize(srgb), "RGB").save(
                    out_dir / png_rel, optimize=False)
                entries.append({
                    "hdr": str(rel),
                    "hdr_scale": white_eff / SDR_WHITE_NITS,
                    "sdr": str(png_rel),
                    "class": "video" if is_video else args.default_class,
                    "mapper": name,
                    "exposure_ev": round(ev, 4),
                    "src_peak_nits": round(src_peak, 1),
                    "source_id": stem,
                    "split": split,
                    "equirect": equirect,
                })
                stats["pairs"] += 1
        stats["assets"] += 1
        if stats["assets"] % 25 == 0:
            print(f"  {stats['assets']} assets, {stats['pairs']} pairs")

    if args.ui_dir:
        ui_root = Path(args.ui_dir).resolve()
        for p in sorted(ui_root.rglob("*.png")) + sorted(ui_root.rglob("*.jpg")):
            rel_ui = p.relative_to(ui_root)
            # Copy-less reference: store absolute path, dataset resolves.
            entries.append({
                "hdr": str(p),
                "hdr_scale": 1.0,
                "sdr": str(p),
                "class": "ui",
                "mapper": "identity",
                "source_id": f"ui_{'_'.join(rel_ui.with_suffix('').parts)}",
                "split": split_for(str(rel_ui)),
                "equirect": False,
            })

    # Rewrite paths relative to the index directory for portability.
    index_path = Path(args.index).resolve()
    index_path.parent.mkdir(parents=True, exist_ok=True)
    idx_root = index_path.parent
    for e in entries:
        for key in ("hdr", "sdr"):
            path = Path(e[key])
            if not path.is_absolute():
                path = root / path if key == "hdr" else out_dir / path
            try:
                e[key] = str(path.resolve().relative_to(idx_root))
            except ValueError:
                e[key] = str(path.resolve())  # outside; keep absolute

    with open(index_path, "w", encoding="utf-8") as fh:
        for e in entries:
            fh.write(json.dumps(e) + "\n")

    by_split = {}
    for e in entries:
        by_split[e["split"]] = by_split.get(e["split"], 0) + 1
    print(f"index: {index_path}")
    print(f"pairs: {stats['pairs']} from {stats['assets']} assets "
          f"(skipped {stats['skipped']}), ui: "
          f"{sum(1 for e in entries if e['class'] == 'ui')}")
    print(f"splits: {by_split}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

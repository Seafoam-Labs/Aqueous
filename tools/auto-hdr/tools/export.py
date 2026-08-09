#!/usr/bin/env python3
"""Export trained models to deployment artifacts
(docs/auto-hdr-model-training-plan.md S8).

Option A: ONNX graph (sdr, peak_rel) -> gain field, plus a demo mode that
writes the gain map as EXR (the offline/helper generation shape the
compositor consumes).
Option B: ONNX encoder (sdr -> 3D LUT coefficients) plus a .cube bake.
Option C: ONNX regressor (sdr -> boost scalar); with --demo also bakes the
analytic curve at the predicted boost into a .cube (zero-ML deployment).

Usage:
  python tools/export.py --ckpt runs/optiona/best.pt --out export/gain.onnx
  python tools/export.py --ckpt runs/optiona/best.pt --demo input.png \
      --peak-nits 1000 --demo-out export/demo
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch import nn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from autohdr.color import SDR_WHITE_NITS, srgb_eotf  # noqa: E402
from autohdr.exr_io import write_exr  # noqa: E402
from autohdr.models import (GainNet, LUTPredictor,  # noqa: E402
                            ParamRegressor, analytic_expand, clamp_at_peak)


class LutEncoderWrapper(nn.Module):
    def __init__(self, model: LUTPredictor):
        super().__init__()
        self.model = model

    def forward(self, sdr: torch.Tensor) -> torch.Tensor:
        return self.model.encode(sdr)


def build_model(option: str, args_ckpt: dict):
    if option == "A":
        return GainNet(base=args_ckpt.get("base", 32))
    if option == "B":
        return LUTPredictor(lut_size=args_ckpt.get("lut_size", 9),
                            base=args_ckpt.get("base", 32))
    return ParamRegressor(base=args_ckpt.get("base", 32))


def write_cube(path: Path, lut: torch.Tensor) -> None:
    """lut: (3, s, s, s), layout [ch, b, g, r] (matches models.identity_lut).
    .cube lists colors with the first component (R) varying fastest."""
    s = lut.shape[-1]
    lut = lut.clamp(0.0, 1.0)
    lines = [f"LUT_3D_SIZE {s}",
             "DOMAIN_MIN 0.0 0.0 0.0",
             "DOMAIN_MAX 1.0 1.0 1.0"]
    for b in range(s):
        for g in range(s):
            for r in range(s):
                v = lut[:, b, g, r]
                lines.append(f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def analytic_cube(boost: float, peak_rel: float, size: int = 33) -> torch.Tensor:
    """Bake the Stage A analytic curve into a 3D LUT (Option C export)."""
    coords = torch.linspace(0.0, 1.0, size)
    z, y, x = torch.meshgrid(coords, coords, coords, indexing="ij")
    rgb = torch.stack([x, y, z], dim=0).unsqueeze(0)  # (1,3,s,s,s)
    peak = torch.tensor([peak_rel])
    boost_t = torch.tensor([boost])
    expanded, _ = analytic_expand(rgb, boost_t, peak)
    return expanded.squeeze(0)


def load_sdr_image(path: Path) -> torch.Tensor:
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    return srgb_eotf(torch.from_numpy(img).permute(2, 0, 1)).unsqueeze(0)


def pad_to_multiple(x: torch.Tensor, m: int = 8):
    _, _, h, w = x.shape
    ph = (m - h % m) % m
    pw = (m - w % m) % m
    if ph or pw:
        x = torch.nn.functional.pad(x, (0, pw, 0, ph), mode="replicate")
    return x, h, w


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--out", default=None, help="ONNX output path")
    ap.add_argument("--demo", default=None, help="sRGB image for a demo run")
    ap.add_argument("--demo-out", default="export/demo",
                    help="demo artifact directory")
    ap.add_argument("--peak-nits", type=float, default=1000.0,
                    help="HDR peak for demo/export sanity (compositor levels: "
                         "100/400/1000)")
    ap.add_argument("--opset", type=int, default=18)
    args = ap.parse_args()

    device = torch.device("cpu")
    ckpt = torch.load(args.ckpt, map_location=device)
    option = ckpt["option"]
    model = build_model(option, ckpt.get("args", {}))
    model.load_state_dict(ckpt["model"])
    model.eval()
    peak_rel = args.peak_nits / SDR_WHITE_NITS

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        dummy = torch.zeros(1, 3, 256, 256)
        if option == "A":
            torch.onnx.export(
                model, (dummy, torch.tensor([peak_rel])), str(out),
                input_names=["sdr", "peak_rel"], output_names=["gain"],
                dynamic_axes={"sdr": {0: "batch", 2: "height", 3: "width"},
                              "gain": {0: "batch", 2: "height", 3: "width"}},
                opset_version=args.opset)
        elif option == "B":
            torch.onnx.export(
                LutEncoderWrapper(model), (dummy,), str(out),
                input_names=["sdr"], output_names=["lut"],
                dynamic_axes={"sdr": {0: "batch", 2: "height", 3: "width"},
                              "lut": {0: "batch"}},
                opset_version=args.opset)
        else:
            torch.onnx.export(
                model, (dummy,), str(out),
                input_names=["sdr"], output_names=["boost"],
                dynamic_axes={"sdr": {0: "batch", 2: "height", 3: "width"},
                              "boost": {0: "batch"}},
                opset_version=args.opset)
        print(f"onnx: {out}")

    if args.demo:
        demo_dir = Path(args.demo_out)
        demo_dir.mkdir(parents=True, exist_ok=True)
        sdr, oh, ow = pad_to_multiple(load_sdr_image(Path(args.demo)))
        with torch.no_grad():
            if option == "A":
                gain = model(sdr, torch.tensor([peak_rel]))[:, :, :oh, :ow]
                write_exr(demo_dir / "gain.exr",
                          gain.squeeze(0).permute(1, 2, 0).repeat(
                              1, 1, 3).numpy())
                expanded = clamp_at_peak(sdr * gain,
                                         torch.tensor([peak_rel]))
                print(f"gain range: [{gain.min():.3f}, {gain.max():.3f}]")
            elif option == "B":
                lut = model.encode(sdr).squeeze(0)
                write_cube(demo_dir / "lut.cube", lut)
                print(f"lut: {demo_dir / 'lut.cube'}")
            else:
                boost = float(model(sdr).item())
                write_cube(demo_dir / "lut.cube",
                           analytic_cube(boost, peak_rel))
                print(f"predicted boost: {boost:.3f}; baked analytic curve "
                      f"to {demo_dir / 'lut.cube'}")
        print(f"demo artifacts: {demo_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

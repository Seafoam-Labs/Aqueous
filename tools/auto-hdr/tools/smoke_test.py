#!/usr/bin/env python3
"""CPU end-to-end smoke test for the training stack.

Verifies: PQ/sRGB roundtrips, tone-mapper ensemble sanity (white anchoring,
finiteness), EXR I/O roundtrip, pair index + dataset + sampler, all three
models' forward/backward, and the analytic curve against hand-computed
values from compositor/aqueous/auto_hdr.zig.

Run:  .venv-rocm/bin/python tools/smoke_test.py
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from autohdr import exr_io, losses  # noqa: E402
from autohdr.color import (SDR_WHITE_NITS, luminance, nits_to_pq,  # noqa: E402
                           pq_to_nits, srgb_eotf, srgb_oetf)
from autohdr.dataset import CLASS_NAMES, PairDataset, make_sampler  # noqa: E402
from autohdr.models import (GainNet, LUTPredictor, ParamRegressor,  # noqa: E402
                            analytic_expand, clamp_at_peak)
from autohdr.tonemap import MAPPERS  # noqa: E402


def forward_outputs(option, model, sdr, peak_rel):
    """Mirror of tools/train.py:forward_outputs."""
    if option == "A":
        gain = model(sdr, peak_rel)
        return clamp_at_peak(sdr * gain, peak_rel), gain, {}
    if option == "B":
        expanded_raw, lut = model(sdr)
        expanded = clamp_at_peak(expanded_raw, peak_rel)
        gain = luminance(expanded) / luminance(sdr).clamp_min(1e-6)
        return expanded, gain, {"lut": lut}
    boost = model(sdr)
    expanded, gain = analytic_expand(sdr, boost, peak_rel)
    return expanded, gain, {}


def main() -> int:
    torch.manual_seed(0)

    # 1. PQ roundtrip on representative nit levels. Tolerance is loose:
    # float32 PQ roundtrips drift ~0.05 nits around 1000 nits because the
    # inverse power curve amplifies mantissa error (expected, not a bug).
    nits = torch.tensor([0.0, 0.5, 100.0, 203.0, 400.0, 1000.0, 10000.0])
    assert torch.allclose(pq_to_nits(nits_to_pq(nits)), nits, atol=0.1)

    # 2. sRGB roundtrip.
    x = torch.rand(3, 8, 8)
    assert torch.allclose(srgb_eotf(srgb_oetf(x)), x, atol=1e-3)

    # 3. Tone mappers: finite, non-negative, white-anchored.
    hdr = torch.rand(3, 16, 16) * 50.0 + 0.01
    flat_white = torch.full((3, 4, 4), SDR_WHITE_NITS)
    for name, m in MAPPERS.items():
        sdr = m(hdr, 2000.0, SDR_WHITE_NITS)
        assert torch.isfinite(sdr).all(), name
        assert sdr.min() >= -1e-3, name
        l_white = float(luminance(m(flat_white, 2000.0, SDR_WHITE_NITS)).mean())
        assert abs(l_white - SDR_WHITE_NITS) < 30.0, (name, l_white)

    # 4. EXR I/O roundtrip.
    tmp = Path(tempfile.mkdtemp(prefix="autohdr_smoke_"))
    arr = (np.random.rand(32, 64, 3) * 4.0).astype(np.float32)
    exr_io.write_exr(tmp / "scene.exr", arr, half=False)
    back = exr_io.read_exr(tmp / "scene.exr")
    assert np.allclose(back, arr, atol=1e-3)

    # 5. Synthetic pair index -> dataset -> sampler.
    (tmp / "sdr").mkdir(exist_ok=True)
    png = (np.random.rand(32, 64, 3) * 255).astype(np.uint8)
    Image.fromarray(png, "RGB").save(tmp / "sdr" / "scene_e0_bt2390.png")
    ui_png = (np.random.rand(32, 64, 3) * 255).astype(np.uint8)
    Image.fromarray(ui_png, "RGB").save(tmp / "ui.png")
    entries = [
        {"hdr": "scene.exr", "hdr_scale": 1.0,
         "sdr": "sdr/scene_e0_bt2390.png", "class": "scene",
         "mapper": "bt2390", "source_id": "scene", "split": "train",
         "equirect": False},
        {"hdr": "ui.png", "hdr_scale": 1.0, "sdr": "ui.png",
         "class": "ui", "mapper": "identity", "source_id": "ui",
         "split": "train", "equirect": False},
    ]
    index = tmp / "index.jsonl"
    index.write_text("\n".join(json.dumps(e) for e in entries))
    ds = PairDataset(index, split="train", crop=16)
    assert len(ds) == 2
    item = ds[0]
    assert item["sdr"].shape == (3, 16, 16)
    assert item["hdr"].shape == (3, 16, 16)
    sampler = make_sampler(ds)
    assert len(list(sampler)) == 2

    # 6. Forward + backward for all three options.
    sdr = torch.rand(2, 3, 16, 16, requires_grad=False)
    hdr_t = torch.rand(2, 3, 16, 16) * 3.0
    peak = torch.tensor([400.0 / SDR_WHITE_NITS, 1000.0 / SDR_WHITE_NITS])
    is_ui = torch.tensor([False, True])
    models = [("A", GainNet(base=16)),
              ("B", LUTPredictor(lut_size=9, base=16)),
              ("C", ParamRegressor(base=16))]
    for option, model in models:
        expanded, gain, extras = forward_outputs(option, model, sdr, peak)
        assert expanded.shape == sdr.shape, option
        assert gain.shape[0] == 2, option
        loss = (losses.pq_l1(expanded, hdr_t, peak) +
                0.1 * losses.expansion_only(gain) +
                1.0 * losses.identity_on_ui(gain, is_ui))
        if option == "A":
            loss = loss + 0.01 * losses.total_variation(gain)
        if option == "B":
            loss = loss + 0.05 * losses.lut_floor(extras["lut"],
                                                  model.identity)
        loss.backward()
        n_params = sum(p.numel() for p in model.parameters())
        print(f"  option {option}: loss {loss.item():.4f}, "
              f"{n_params:,} params")

    # 7. Analytic curve vs hand-computed values from auto_hdr.zig:
    #    white=1, peak=1000/203, boost=0.5 -> gain at white ==
    #    1 + 0.5 * (peak/white - 1).
    img = torch.full((1, 3, 16, 16), 1.0)  # luma == white == 1.0
    _, gain = analytic_expand(img, torch.tensor([0.5]),
                              torch.tensor([1000.0 / SDR_WHITE_NITS]))
    expected = 1.0 + 0.5 * (1000.0 / SDR_WHITE_NITS - 1.0)
    assert abs(float(gain[0, 0, 0, 0]) - expected) < 1e-4, \
        (float(gain[0, 0, 0, 0]), expected)
    # Below the knee (0.8) the gain must be exactly 1.
    dim = torch.full((1, 3, 16, 16), 0.5)
    _, gain_dim = analytic_expand(dim, torch.tensor([0.5]),
                                  torch.tensor([1000.0 / SDR_WHITE_NITS]))
    assert float(gain_dim.max()) == 1.0

    print("SMOKE-OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

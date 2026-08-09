"""Color math shared by the Auto HDR training pipeline.

Coordinate conventions (must stay consistent with the compositor, see
compositor/aqueous/render/shaders/rounded_texture.frag and
compositor/aqueous/auto_hdr.zig):

* "working units": linear light where 1.0 == SDR diffuse white == 203 cd/m2
  (the wlroots sdr_white_level placement used by the compositor).
* Training-space SDR inputs are additionally white-normalized, i.e. the
  SDR diffuse white of each sample sits at 1.0 (the dataset divides by the
  degradation's SDR white), mirroring the shader's `white` placement.
* PQ (SMPTE ST.2084) is defined on absolute nits in [0, 10000].

All functions accept torch tensors and are used both by data generation
(no grad) and the training loop.
"""
from __future__ import annotations

import torch

SDR_WHITE_NITS = 203.0

# SMPTE ST.2084 (PQ) constants.
PQ_M1 = 2610.0 / 16384.0
PQ_M2 = (2523.0 / 4096.0) * 128.0
PQ_C1 = 3424.0 / 4096.0
PQ_C2 = (2413.0 / 4096.0) * 32.0
PQ_C3 = (2392.0 / 4096.0) * 32.0

REC709_LUMA = (0.2126, 0.7152, 0.0722)


def nits_to_working(x: torch.Tensor) -> torch.Tensor:
    return x / SDR_WHITE_NITS


def working_to_nits(x: torch.Tensor) -> torch.Tensor:
    return x * SDR_WHITE_NITS


def nits_to_pq(nits: torch.Tensor) -> torch.Tensor:
    y = torch.clamp(nits, 0.0, 10000.0) / 10000.0
    ym = y.pow(PQ_M1)
    return ((PQ_C1 + PQ_C2 * ym) / (1.0 + PQ_C3 * ym)).pow(PQ_M2)


def pq_to_nits(pq: torch.Tensor) -> torch.Tensor:
    p = torch.clamp(pq, 0.0, 1.0).pow(1.0 / PQ_M2)
    num = torch.clamp(p - PQ_C1, min=0.0)
    den = PQ_C2 - PQ_C3 * p
    return 10000.0 * (num / den).pow(1.0 / PQ_M1)


def working_to_pq(x: torch.Tensor) -> torch.Tensor:
    return nits_to_pq(working_to_nits(x))


def luminance(rgb: torch.Tensor) -> torch.Tensor:
    """Rec.709 luma. Accepts (3,H,W) or (B,3,H,W); returns keepdim."""
    w = torch.tensor(REC709_LUMA, device=rgb.device, dtype=rgb.dtype)
    shape = [1] * rgb.ndim
    shape[-3] = 3
    return (rgb * w.view(shape)).sum(dim=-3, keepdim=True)


def srgb_oetf(linear: torch.Tensor) -> torch.Tensor:
    """Linear [0,inf) -> sRGB encoded [0,1] (clamped)."""
    x = torch.clamp(linear, min=0.0)
    low = 12.92 * x
    high = 1.055 * x.pow(1.0 / 2.4) - 0.055
    return torch.where(x <= 0.0031308, low, high).clamp(0.0, 1.0)


def srgb_eotf(encoded: torch.Tensor) -> torch.Tensor:
    """sRGB encoded [0,1] -> linear."""
    v = torch.clamp(encoded, 0.0, 1.0)
    low = v / 12.92
    high = ((v + 0.055) / 1.055).pow(2.4)
    return torch.where(v <= 0.04045, low, high)

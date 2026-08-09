"""Loss terms from docs/auto-hdr-model-training-plan.md S5."""
from __future__ import annotations

import torch
from torch.nn import functional as F

from .color import working_to_pq


def _peak_view(peak: torch.Tensor, ref: torch.Tensor) -> torch.Tensor:
    return peak.view(-1, 1, 1, 1).expand_as(ref)


# Floor before PQ encoding to keep the backward pass finite at black.
PQ_EPS = 1e-5


def pq_l1(expanded: torch.Tensor, hdr: torch.Tensor,
          peak: torch.Tensor) -> torch.Tensor:
    """Base term: L1 between PQ encodings, both clamped at the peak.

    Values are floored at PQ_EPS before encoding: the gradient of
    y.pow(PQ_M1) is infinite at y == 0, and 8-bit SDR contains exact
    zeros, so without the floor one black pixel NaNs the whole backward
    pass. The floor (~2e-4 nits) is perceptually nothing.
    """
    peak_v = _peak_view(peak, expanded)
    e = working_to_pq(torch.minimum(expanded.clamp_min(PQ_EPS), peak_v))
    h = working_to_pq(torch.minimum(hdr.clamp_min(PQ_EPS), peak_v))
    return (e - h).abs().mean()


def expansion_only(gain: torch.Tensor) -> torch.Tensor:
    """Never dim content: penalize gain below 1."""
    return F.relu(1.0 - gain).mean()


def identity_on_ui(gain: torch.Tensor, is_ui: torch.Tensor) -> torch.Tensor:
    """Negative-class identity: gain must stay 1 on UI/desktop patches."""
    mask = is_ui.bool()
    if not mask.any():
        return gain.new_zeros(())
    return (gain[mask] - 1.0).abs().mean()


def total_variation(gain: torch.Tensor) -> torch.Tensor:
    """Smoothness prior to suppress halos (weight 0 until halos appear)."""
    dy = (gain[:, :, 1:, :] - gain[:, :, :-1, :]).abs().mean()
    dx = (gain[:, :, :, 1:] - gain[:, :, :, :-1]).abs().mean()
    return dx + dy


def lut_floor(lut: torch.Tensor, identity: torch.Tensor) -> torch.Tensor:
    """Option B: LUT must not dim content (identity is the floor)."""
    return F.relu(identity.unsqueeze(0) - lut).mean()

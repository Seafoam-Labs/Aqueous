"""Evaluation metrics (docs/auto-hdr-model-training-plan.md S7).

Primary metric here is PQ delta (mean absolute difference in PQ space),
which uniformizes error across nits the way PU21 does for perceptual
luminance. A PU21 encoder is included but its constants are from memory of
the reference implementation -- verify against the published PU21
paper/code before quoting absolute PU21 numbers.
"""
from __future__ import annotations

import torch

from .color import luminance, working_to_nits, working_to_pq

# PU21: P(L) = p1 * ((p2 + L^p4) / (L^p3 + p5))^p6, L in cd/m2.
# VERIFY before trusting absolute values (see module docstring).
PU21_P = (1.070275272, 0.4088273932, 0.153224308,
          0.2520326168, 1.063512885, 1.139492997)


def pu21_encode(nits: torch.Tensor) -> torch.Tensor:
    p1, p2, p3, p4, p5, p6 = PU21_P
    l = nits.clamp_min(1e-6)
    return p1 * ((p2 + l.pow(p4)) / (l.pow(p3) + p5)).pow(p6)


def pq_delta_milli(expanded: torch.Tensor, hdr: torch.Tensor,
                   peak: torch.Tensor) -> float:
    """Mean |PQ(E) - PQ(H)| * 1000, both clamped at the peak."""
    peak_v = peak.view(-1, 1, 1, 1).expand_as(expanded)
    e = working_to_pq(torch.minimum(expanded.clamp_min(1e-5), peak_v))
    h = working_to_pq(torch.minimum(hdr.clamp_min(1e-5), peak_v))
    return float((e - h).abs().mean().item()) * 1000.0


def pu21_delta(expanded: torch.Tensor, hdr: torch.Tensor,
               peak: torch.Tensor) -> float:
    """Mean |PU21(E) - PU21(H)| in working units -> nits."""
    peak_v = peak.view(-1, 1, 1, 1).expand_as(expanded)
    e = working_to_nits(torch.minimum(expanded.clamp_min(0.0), peak_v))
    h = working_to_nits(torch.minimum(hdr.clamp_min(0.0), peak_v))
    return float((pu21_encode(e) - pu21_encode(h)).abs().mean().item())


def luminance_histogram_distance(expanded: torch.Tensor, hdr: torch.Tensor,
                                 peak: torch.Tensor,
                                 bins: int = 32) -> float:
    """L1 distance between normalized luminance histograms on [0, peak].

    Proves the expansion actually reaches HDR headroom instead of hovering
    near SDR white (training plan S7).
    """
    peak_f = float(peak.view(-1)[0].item())
    dist = 0.0
    for img in (expanded, hdr):
        luma = luminance(img).clamp(0.0, peak_f).flatten()
        hist = torch.histc(luma, bins=bins, min=0.0, max=peak_f)
        hist = hist / hist.sum().clamp_min(1.0)
        if img is expanded:
            hist_e = hist
        else:
            hist_h = hist
    dist = float((hist_e - hist_h).abs().sum().item())
    return dist

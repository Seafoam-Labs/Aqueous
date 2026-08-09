"""SDR synthesis: HDR ground truth (linear, absolute nits) -> SDR linear.

Every mapper implements
    __call__(rgb_nits, src_peak_nits, sdr_white_nits) -> sdr_rgb_nits
so pair generation (tools/generate_pairs.py) can treat them uniformly.

Filmic mappers (hable/aces/reinhard) are *white-anchored*: their output is
rescaled so the scene's diffuse white lands exactly on `sdr_white_nits`.
That keeps the degradation ensemble consistent — the compositor's white
placement is the reference, and only the highlight roll-off differs between
mappers.

Standards fidelity notes (be honest about these):
* bt2390 implements the ITU-R BT.2390 EETF structure: identity below the
  target peak, smoothstep knee between target peak and source peak in the PQ
  domain, plus luminance-ratio chroma scaling. Knee points default to
  KS = L_target, KE = L_max as in the report.
* bt2446a is an *approximation* of ITU-R BT.2446 Method A (identity below
  SDR white, smooth compression above). Verify against the ITU reference
  before treating results as standards-conformant.
"""
from __future__ import annotations

import torch

from .color import luminance, nits_to_pq, pq_to_nits

_EPS = 1e-6


class ToneMapper:
    name = "base"

    def __call__(self, rgb_nits: torch.Tensor, src_peak_nits: float,
                 sdr_white_nits: float) -> torch.Tensor:
        raise NotImplementedError


class BT2390(ToneMapper):
    """ITU-R BT.2390 EETF (HDR -> SDR), PQ domain."""

    name = "bt2390"

    def __call__(self, rgb_nits, src_peak_nits, sdr_white_nits):
        luma = luminance(rgb_nits)
        pq_in = nits_to_pq(luma)
        l_max = nits_to_pq(torch.tensor(src_peak_nits))
        l_target = nits_to_pq(torch.tensor(sdr_white_nits))
        ks, ke = l_target, torch.maximum(l_max, l_target + 1e-4)
        t = torch.clamp((pq_in - ks) / (ke - ks), 0.0, 1.0)
        t = t * t * (3.0 - 2.0 * t)  # smoothstep
        pq_out = torch.where(pq_in <= ks, pq_in,
                             l_target + (l_max - l_target) * t)
        luma_out = pq_to_nits(pq_out)
        return rgb_nits * (luma_out / torch.clamp(luma, min=_EPS))


class BT2446A(ToneMapper):
    """Approximation of ITU-R BT.2446 Method A (see module note)."""

    name = "bt2446a"

    def __call__(self, rgb_nits, src_peak_nits, sdr_white_nits):
        luma = luminance(rgb_nits)
        x = luma / sdr_white_nits
        # Identity below SDR white; highlights compress smoothly toward an
        # asymptote at ~1.5x white (typical SDR extended-range headroom).
        comp = torch.where(x <= 1.0, x, 1.0 + 0.5 * torch.tanh(x - 1.0))
        return rgb_nits * (comp / torch.clamp(x, min=_EPS))


def _hable(x: torch.Tensor) -> torch.Tensor:
    a, b, c, d, e, f = 0.15, 0.50, 0.10, 0.20, 0.02, 0.30
    return ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f


class Hable(ToneMapper):
    """Uncharted 2 / Hable filmic curve, white-anchored."""

    name = "hable"

    def __call__(self, rgb_nits, src_peak_nits, sdr_white_nits):
        v = rgb_nits / 100.0
        white = torch.tensor(sdr_white_nits / 100.0)
        mapped = _hable(v).clamp_min(0.0)
        anchor = _hable(white).clamp_min(_EPS)
        return sdr_white_nits * mapped / anchor


def _aces(x: torch.Tensor) -> torch.Tensor:
    # Narkowicz fitted ACES (public approximation of the ACES RRT+ODT).
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    return ((x * (a * x + b)) / (x * (c * x + d) + e)).clamp(0.0, 1.0)


class ACES(ToneMapper):
    """ACES filmic (fitted form), white-anchored."""

    name = "aces"

    def __call__(self, rgb_nits, src_peak_nits, sdr_white_nits):
        v = rgb_nits / 100.0
        white = torch.tensor(sdr_white_nits / 100.0)
        mapped = _aces(v)
        anchor = _aces(white).clamp_min(_EPS)
        return sdr_white_nits * mapped / anchor


class Reinhard(ToneMapper):
    """Extended Reinhard (luminance-based), white-anchored."""

    name = "reinhard"

    def __call__(self, rgb_nits, src_peak_nits, sdr_white_nits):
        lw2 = float(src_peak_nits) ** 2
        luma = luminance(rgb_nits)

        def curve(l: torch.Tensor) -> torch.Tensor:
            return l * (1.0 + l / lw2) / (1.0 + l)

        luma_out = curve(luma)
        white = torch.tensor(sdr_white_nits)
        anchor = curve(white).clamp_min(_EPS)
        scaled = luma_out * sdr_white_nits / anchor
        return rgb_nits * (scaled / torch.clamp(luma, min=_EPS))


MAPPERS: dict[str, ToneMapper] = {
    m.name: m for m in (BT2390(), BT2446A(), Hable(), ACES(), Reinhard())
}

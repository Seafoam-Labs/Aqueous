"""Model definitions for the three architecture options of
docs/auto-hdr-model-training-plan.md S4.

All models operate in training coordinates: SDR input is linear with its
diffuse white placed at 1.0, and `peak_rel` is the HDR peak in the same
units (compositor HdrLevel.nits() / 203).
"""
from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F

from .color import luminance


def clamp_at_peak(rgb: torch.Tensor, peak: torch.Tensor) -> torch.Tensor:
    """Luminance clamp at the HDR peak; mirrors the shader's final clamp.

    peak: (B,) or broadcastable; rgb: (B,3,H,W) in working units.
    """
    peak_v = peak.view(-1, 1, 1, 1)
    luma = luminance(rgb)
    over = luma > peak_v
    scale = torch.where(over, peak_v / luma.clamp_min(1e-8),
                        torch.ones_like(luma))
    return rgb * scale


class DWConv(nn.Module):
    """Depthwise-separable conv block (plan S4 Option A backbone)."""

    def __init__(self, cin: int, cout: int, stride: int = 1):
        super().__init__()
        self.dw = nn.Conv2d(cin, cin, 3, stride=stride, padding=1,
                            groups=cin, bias=False)
        self.pw = nn.Conv2d(cin, cout, 1, bias=False)
        self.norm = nn.GroupNorm(8, cout)
        self.act = nn.GELU()

    def forward(self, x):
        return self.act(self.norm(self.pw(self.dw(x))))


class GainNet(nn.Module):
    """Option A: gain-field CNN. Output G(x,y) in [1, peak_rel] by
    construction, so the expansion can never exceed the configured peak."""

    def __init__(self, base: int = 32):
        super().__init__()
        c0, c1, c2, c3 = base, base * 2, base * 4, base * 8
        self.stem = nn.Sequential(
            nn.Conv2d(5, c0, 3, padding=1, bias=False),
            nn.GroupNorm(8, c0), nn.GELU())
        self.down1 = DWConv(c0, c1, 2)
        self.down2 = DWConv(c1, c2, 2)
        self.down3 = DWConv(c2, c3, 2)
        self.mid = DWConv(c3, c3)
        self.up1 = DWConv(c3 + c2, c2)
        self.up2 = DWConv(c2 + c1, c1)
        self.up3 = DWConv(c1 + c0, c0)
        self.head = nn.Conv2d(c0, 1, 1)
        self.up = nn.Upsample(scale_factor=2, mode="nearest")

    def forward(self, sdr: torch.Tensor, peak_rel: torch.Tensor) -> torch.Tensor:
        b, _, h, w = sdr.shape
        luma = luminance(sdr)
        pr = peak_rel.view(b, 1, 1, 1).expand(b, 1, h, w)
        x = torch.cat([sdr, luma, pr], dim=1)
        s0 = self.stem(x)
        s1 = self.down1(s0)
        s2 = self.down2(s1)
        s3 = self.down3(s2)
        m = self.mid(s3)
        u1 = self.up1(torch.cat([self.up(m), s2], dim=1))
        u2 = self.up2(torch.cat([self.up(u1), s1], dim=1))
        u3 = self.up3(torch.cat([self.up(u2), s0], dim=1))
        raw = self.head(u3)
        headroom = (peak_rel - 1.0).view(b, 1, 1, 1).clamp_min(0.0)
        return 1.0 + headroom * torch.sigmoid(raw)


def apply_lut(image: torch.Tensor, lut: torch.Tensor) -> torch.Tensor:
    """Trilinear 3D-LUT fetch via grid_sample.

    image: (B,3,H,W) clamped to [0,1]; lut: (B,3,s,s,s) with the identity
    layout lut[ch, b_idx, g_idx, r_idx] = color for input (r,g,b).
    """
    grid = image.clamp(0.0, 1.0).permute(0, 2, 3, 1)  # (B,H,W,3)
    grid = grid * 2.0 - 1.0
    grid = grid.unsqueeze(1)  # (B,1,H,W,3)
    out = F.grid_sample(lut, grid, mode="bilinear", padding_mode="border",
                        align_corners=True)  # (B,3,1,H,W)
    return out.squeeze(2).clamp_min(0.0)


def identity_lut(size: int, device=None) -> torch.Tensor:
    coords = torch.linspace(0.0, 1.0, size, device=device)
    z, y, x = torch.meshgrid(coords, coords, coords, indexing="ij")
    return torch.stack([x, y, z], dim=0)  # (3, s, s, s): R,G,B channels


class LUTPredictor(nn.Module):
    """Option B: image-conditioned 3D LUT coefficients (cf. Image-Adaptive
    3D LUT). The LUT is expressed as identity + bounded delta for stable
    training start."""

    def __init__(self, lut_size: int = 9, base: int = 32,
                 delta_scale: float = 0.25):
        super().__init__()
        self.lut_size = lut_size
        self.delta_scale = delta_scale
        c0, c1, c2, c3 = base, base * 2, base * 4, base * 8
        self.features = nn.Sequential(
            nn.Conv2d(3, c0, 3, stride=2, padding=1), nn.GELU(),
            DWConv(c0, c1, 2),
            DWConv(c1, c2, 2),
            DWConv(c2, c3, 2),
            DWConv(c3, c3, 2),
            nn.AdaptiveAvgPool2d(1),
            nn.Flatten(),
        )
        self.head = nn.Linear(c3, 3 * lut_size ** 3)
        self.register_buffer("identity", identity_lut(lut_size))

    def encode(self, sdr: torch.Tensor) -> torch.Tensor:
        feat = self.features(sdr)
        delta = torch.tanh(self.head(feat)) * self.delta_scale
        b = sdr.shape[0]
        return (self.identity.unsqueeze(0) +
                delta.view(b, 3, self.lut_size, self.lut_size, self.lut_size))

    def forward(self, sdr: torch.Tensor):
        lut = self.encode(sdr)
        return apply_lut(sdr, lut), lut


class ParamRegressor(nn.Module):
    """Option C: predicts the analytic curve's `boost` knob per image
    (pipeline shakedown model, plan S4)."""

    def __init__(self, base: int = 32):
        super().__init__()
        c0, c1, c2, c3 = base, base * 2, base * 4, base * 8
        self.features = nn.Sequential(
            nn.Conv2d(3, c0, 3, stride=2, padding=1), nn.GELU(),
            DWConv(c0, c1, 2),
            DWConv(c1, c2, 2),
            DWConv(c2, c3, 2),
            DWConv(c3, c3, 2),
            nn.AdaptiveAvgPool2d(1),
            nn.Flatten(),
        )
        self.head = nn.Sequential(
            nn.Linear(c3, 64), nn.GELU(), nn.Linear(64, 1), nn.Sigmoid())

    def forward(self, sdr: torch.Tensor) -> torch.Tensor:
        return self.head(self.features(sdr)).squeeze(-1)  # (B,) in (0,1)


def analytic_expand(sdr: torch.Tensor, boost: torch.Tensor,
                    peak_rel: torch.Tensor, knee: float = 0.8):
    """Mirror of compositor/aqueous/auto_hdr.zig for training coordinates
    (white placed at 1.0). Returns (expanded, gain)."""
    b = sdr.shape[0]
    luma = luminance(sdr)
    t = torch.clamp((luma - knee) / (1.0 - knee), 0.0, 1.0)
    mask = t * t * (3.0 - 2.0 * t)
    pr = peak_rel.view(b, 1, 1, 1).clamp_min(1.0)
    gain = 1.0 + boost.view(b, 1, 1, 1) * (pr - 1.0) * mask
    return clamp_at_peak(sdr * gain, peak_rel), gain

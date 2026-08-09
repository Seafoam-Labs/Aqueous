"""Pair dataset for Auto HDR training.

The index is a JSON-lines file produced by tools/generate_pairs.py; paths
inside are relative to the index file's directory. Entry fields:

    hdr        HDR side (EXR, linear scene-referred), multiplied by
               hdr_scale to reach working units (1.0 == 203 nits)
    hdr_scale  float; working-unit scale for the HDR side
    sdr        SDR side (8-bit sRGB PNG; decoded and white-normalized so
               SDR diffuse white sits at 1.0)
    class      "scene" | "video" | "ui"
    mapper     tone mapper that synthesized the SDR side ("identity" for ui)
    source_id  asset-level identity used for split assignment (no leakage)
    split      "train" | "val" | "test"
    equirect   bool; crops avoid the degenerate polar rows if true

For "ui" entries hdr == sdr (identity target, gain must stay 1).
"""
from __future__ import annotations

import json
import random
from collections import Counter
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset, WeightedRandomSampler

from .color import SDR_WHITE_NITS, srgb_eotf
from .exr_io import read_exr

CLASS_NAMES = ("scene", "video", "ui")

# Compositor HdrLevel presets in working units (output_hdr.zig). The 100-nit
# level has no headroom above white, so it is not sampled for training.
PEAK_LEVELS = (400.0 / SDR_WHITE_NITS, 1000.0 / SDR_WHITE_NITS)


class PairDataset(Dataset):
    def __init__(self, index_path: str | Path, split: str | None = None,
                 crop: int = 256, peak_levels=PEAK_LEVELS,
                 peak_jitter: float = 0.0, classes=None,
                 max_entries: int | None = None, cache_size: int = 8):
        self.root = Path(index_path).resolve().parent
        self.crop = crop
        self.peak_levels = list(peak_levels)
        self.peak_jitter = peak_jitter
        self._cache: dict[str, torch.Tensor] = {}
        self._cache_order: list[str] = []
        self.cache_size = max(1, cache_size)

        entries = []
        with open(index_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                e = json.loads(line)
                if split is not None and e.get("split") != split:
                    continue
                if classes is not None and e.get("class") not in classes:
                    continue
                entries.append(e)
        if max_entries is not None:
            entries = entries[:max_entries]
        self.entries = entries
        self.class_counts = Counter(e["class"] for e in entries)

    def __len__(self) -> int:
        return len(self.entries)

    # ------------------------------------------------------------------ loads
    def _load_sdr(self, rel_path: str) -> torch.Tensor:
        img = np.asarray(
            Image.open(self.root / rel_path).convert("RGB"), dtype=np.float32)
        img /= 255.0
        return srgb_eotf(torch.from_numpy(img).permute(2, 0, 1))

    def _load_hdr(self, entry: dict) -> torch.Tensor:
        rel = entry["hdr"]
        cached = self._cache.get(rel)
        if cached is None:
            arr = read_exr(self.root / rel)
            arr = np.nan_to_num(arr, nan=0.0, posinf=0.0, neginf=0.0)
            cached = torch.from_numpy(
                np.ascontiguousarray(arr).astype(np.float32)).permute(2, 0, 1)
            self._cache[rel] = cached
            self._cache_order.append(rel)
            while len(self._cache_order) > self.cache_size:
                self._cache.pop(self._cache_order.pop(0), None)
        return cached * float(entry.get("hdr_scale", 1.0))

    # ------------------------------------------------------------------- item
    def __getitem__(self, idx: int):
        e = self.entries[idx]
        cls = e["class"]
        sdr = self._load_sdr(e["sdr"])
        hdr = sdr if cls == "ui" else self._load_hdr(e)

        _, h, w = sdr.shape
        c = self.crop
        if h < c or w < c:
            raise RuntimeError(
                f"source smaller than crop {c}: {e['sdr']} ({w}x{h})")

        top_lo = 0
        top_hi = h - c
        if e.get("equirect"):
            # Skip the degenerate polar rows of equirectangular panoramas.
            band = int(0.05 * h)
            top_lo = band
            top_hi = max(top_lo, h - band - c)
        top = random.randint(top_lo, top_hi)
        left = random.randint(0, w - c)
        box = (slice(None), slice(top, top + c), slice(left, left + c))
        sdr = sdr[box]
        hdr = hdr[box]

        if random.random() < 0.5:
            sdr = torch.flip(sdr, dims=[2])
            hdr = torch.flip(hdr, dims=[2])
        k = random.randint(0, 3)
        if k:
            sdr = torch.rot90(sdr, k, dims=[1, 2])
            hdr = torch.rot90(hdr, k, dims=[1, 2])

        peak = random.choice(self.peak_levels)
        if self.peak_jitter > 0:
            peak *= 1.0 + random.uniform(-self.peak_jitter, self.peak_jitter)

        return {
            "sdr": sdr,
            "hdr": hdr,
            "class_idx": CLASS_NAMES.index(cls),
            "peak_rel": torch.tensor(peak, dtype=torch.float32),
            "mapper": e.get("mapper", ""),
        }


def make_sampler(dataset: PairDataset,
                 class_weights=(0.6, 0.2, 0.2)) -> WeightedRandomSampler:
    """Class-balanced sampling (training plan S6: negatives ~10-20%)."""
    weights = {name: w for name, w in zip(CLASS_NAMES, class_weights)}
    per_class = {
        name: weights.get(name, 0.0) / max(1, dataset.class_counts.get(name, 0))
        for name in CLASS_NAMES
    }
    entry_weights = [per_class[e["class"]] for e in dataset.entries]
    return WeightedRandomSampler(entry_weights, len(entry_weights),
                                 replacement=True)

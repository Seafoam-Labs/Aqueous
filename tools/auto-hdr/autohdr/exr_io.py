"""EXR I/O. Prefers OpenEXR >= 3.2 (has binary wheels); falls back to
imageio if that is available instead. Arrays are (H, W, C) float32 RGB."""
from __future__ import annotations

from pathlib import Path

import numpy as np


def read_exr(path: str | Path) -> np.ndarray:
    path = str(path)
    try:
        import OpenEXR

        f = OpenEXR.File(path, separate_channels=True)
        channels = f.channels()
        names = [n for n in ("R", "G", "B") if n in channels]
        if len(names) == 3:
            planes = [np.asarray(channels[n].pixels, dtype=np.float32)
                      for n in names]
            return np.stack(planes, axis=-1)
    except ImportError:
        pass
    try:
        import imageio.v3 as iio

        arr = np.asarray(iio.imread(path), dtype=np.float32)
        if arr.ndim == 2:
            arr = np.stack([arr] * 3, axis=-1)
        return arr[..., :3]
    except ImportError as exc:
        raise RuntimeError(
            "No EXR backend: install OpenEXR (pip install OpenEXR) or "
            "imageio with an EXR plugin") from exc


def write_exr(path: str | Path, arr: np.ndarray, half: bool = True) -> None:
    """Write (H, W, 3) float array as RGB EXR (HALF by default)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    arr = np.ascontiguousarray(arr, dtype=np.float32 if not half else np.float16)
    try:
        import OpenEXR

        h, w = arr.shape[:2]
        header = {"type": OpenEXR.scanlineimage}
        channels = {
            "R": np.ascontiguousarray(arr[..., 0]),
            "G": np.ascontiguousarray(arr[..., 1]),
            "B": np.ascontiguousarray(arr[..., 2]),
        }
        OpenEXR.File(header, channels).write(str(path))
        return
    except ImportError:
        pass
    try:
        import imageio.v3 as iio

        iio.imwrite(str(path), arr)
        return
    except ImportError as exc:
        raise RuntimeError("No EXR backend available for writing") from exc

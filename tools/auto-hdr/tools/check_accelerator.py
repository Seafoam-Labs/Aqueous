#!/usr/bin/env python3
"""Report and validate the PyTorch accelerator used by Auto HDR."""
from __future__ import annotations

import argparse

import torch


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-rocm", action="store_true",
                        help="fail unless a ROCm device can run a tensor op")
    args = parser.parse_args()

    is_rocm_build = torch.version.hip is not None
    available = torch.cuda.is_available()
    print(f"torch: {torch.__version__}")
    print(f"ROCm/HIP build: {torch.version.hip or 'no'}")
    print(f"accelerator available: {available}")

    if args.require_rocm and not is_rocm_build:
        print("error: requirements did not install the ROCm PyTorch wheel")
        return 1
    if args.require_rocm and not available:
        print("error: ROCm build is installed but the GPU is not accessible")
        print("check /dev/kfd, /dev/dri/renderD*, and server/container access")
        return 1
    if not available:
        print("device: CPU")
        return 0

    try:
        probe = torch.ones(1, device="cuda")
        probe.add_(1)
        torch.cuda.synchronize()
    except Exception as exc:  # device initialization failures are runtime-specific
        print(f"error: accelerator tensor probe failed: {exc}")
        return 1

    props = torch.cuda.get_device_properties(0)
    backend = (f"ROCm {torch.version.hip}" if is_rocm_build
               else f"CUDA {torch.version.cuda}")
    print(f"device: {torch.cuda.get_device_name(0)}")
    print(f"backend: {backend}")
    print(f"PyTorch-reported memory: {props.total_memory / 1e9:.1f} GB")
    print(f"tensor probe: {probe.item():.0f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

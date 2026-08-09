#!/usr/bin/env python3
"""Train the Auto HDR models (docs/auto-hdr-model-training-plan.md S6).

Options:
  A  gain-field CNN (the target, plan S4 Option A)
  B  image-conditioned 3D LUT predictor (Option B)
  C  parameter regression on the analytic curve (Option C, shakedown)

Usage:
  python tools/train.py --option A --index data/pairs/index.jsonl \
      --run-dir runs/option-a

The corpus index comes from tools/generate_pairs.py. Class-balanced
sampling keeps UI negatives at ~20% of batches (plan S6); validation is
per-class because aggregate loss hides UI regressions.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from autohdr import losses  # noqa: E402
from autohdr.color import luminance  # noqa: E402
from autohdr.dataset import CLASS_NAMES, PairDataset, make_sampler  # noqa: E402
from autohdr.metrics import pq_delta_milli  # noqa: E402
from autohdr.models import (GainNet, LUTPredictor, ParamRegressor,  # noqa: E402
                            analytic_expand, clamp_at_peak)


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--option", required=True, choices=["A", "B", "C"])
    ap.add_argument("--index", required=True, help="pair index.jsonl")
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--epochs", type=int, default=300)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--warmup", type=int, default=500)
    ap.add_argument("--crop", type=int, default=256)
    ap.add_argument("--base", type=int, default=32,
                    help="channel base width (params scale ~quadratically)")
    ap.add_argument("--lut-size", type=int, default=9)
    ap.add_argument("--amp", choices=["auto", "fp16", "bf16", "off"],
                    default="auto")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--class-weights", default="0.6,0.2,0.2",
                    help="scene,video,ui sampling weights")
    ap.add_argument("--peak-jitter", type=float, default=0.05,
                    help="relative jitter around the HdrLevel peaks")
    ap.add_argument("--w-expand", type=float, default=0.1)
    ap.add_argument("--w-identity", type=float, default=1.0)
    ap.add_argument("--w-tv", type=float, default=0.0,
                    help="total variation on gain (0 until halos appear)")
    ap.add_argument("--w-lut", type=float, default=0.05,
                    help="Option B: identity-floor weight")
    ap.add_argument("--val-every", type=int, default=1)
    ap.add_argument("--log-every", type=int, default=50)
    ap.add_argument("--val-cap", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--resume", default=None, help="checkpoint to resume")
    ap.add_argument("--smoke", type=int, default=0,
                    help="cap train entries to N for a pipeline smoke test")
    return ap.parse_args()


def build_model(args):
    if args.option == "A":
        return GainNet(base=args.base)
    if args.option == "B":
        return LUTPredictor(lut_size=args.lut_size, base=args.base)
    return ParamRegressor(base=args.base)


def forward_outputs(option, model, sdr, peak_rel):
    """Returns (expanded, gain, extras)."""
    if option == "A":
        gain = model(sdr, peak_rel)
        expanded = clamp_at_peak(sdr * gain, peak_rel)
        return expanded, gain, {}
    if option == "B":
        expanded_raw, lut = model(sdr)
        expanded = clamp_at_peak(expanded_raw, peak_rel)
        gain = luminance(expanded) / luminance(sdr).clamp_min(1e-6)
        return expanded, gain, {"lut": lut}
    boost = model(sdr)
    expanded, gain = analytic_expand(sdr, boost, peak_rel)
    return expanded, gain, {}


def validate(model, loader, option, device, amp_dtype, use_amp,
             class_weights):
    model.eval()
    sums = {name: 0.0 for name in CLASS_NAMES}
    counts = {name: 0 for name in CLASS_NAMES}
    with torch.no_grad():
        for batch in loader:
            sdr = batch["sdr"].to(device, non_blocking=True)
            hdr = batch["hdr"].to(device, non_blocking=True)
            peak = batch["peak_rel"].to(device, non_blocking=True)
            ctx = (torch.autocast(device_type=device.type, dtype=amp_dtype)
                   if use_amp else torch.enable_grad())
            with ctx:
                expanded, _, _ = forward_outputs(option, model, sdr, peak)
            err = pq_delta_milli(expanded.float(), hdr, peak)
            for i, name in enumerate(
                    [CLASS_NAMES[c] for c in batch["class_idx"]]):
                sums[name] += err
                counts[name] += 1
    per_class = {n: sums[n] / counts[n] for n in CLASS_NAMES if counts[n]}
    total_w = sum(class_weights.get(n, 0.0) for n in per_class)
    weighted = (sum(class_weights.get(n, 0.0) * v
                    for n, v in per_class.items()) / total_w
                if total_w > 0 else float("inf"))
    model.train()
    return per_class, weighted, sum(counts.values())


def main() -> int:
    args = parse_args()
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    run_dir = Path(args.run_dir) / f"option{args.option.lower()}"
    run_dir.mkdir(parents=True, exist_ok=True)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if device.type == "cuda":
        props = torch.cuda.get_device_properties(0)
        print(f"device: {torch.cuda.get_device_name(0)} "
              f"({props.total_memory / 1e9:.1f} GB)")
    else:
        print("device: CPU (no CUDA/ROCm device visible)")

    amp = args.amp
    if amp == "auto":
        amp = "fp16" if device.type == "cuda" else "off"
    if amp == "fp16" and device.type != "cuda":
        print("fp16 autocast needs CUDA/ROCm; falling back to off")
        amp = "off"
    amp_dtype = torch.float16 if amp == "fp16" else torch.bfloat16
    use_amp = amp != "off"
    use_scaler = amp == "fp16" and device.type == "cuda"

    class_weights = {name: w for name, w in zip(
        CLASS_NAMES, [float(x) for x in args.class_weights.split(",")])}

    train_ds = PairDataset(args.index, split="train", crop=args.crop,
                           peak_jitter=args.peak_jitter,
                           max_entries=args.smoke or None)
    val_ds = PairDataset(args.index, split="val", crop=args.crop,
                         peak_jitter=0.0,
                         max_entries=args.val_cap if not args.smoke else 8)
    print(f"train entries: {len(train_ds)} {dict(train_ds.class_counts)}")
    print(f"val entries:   {len(val_ds)} {dict(val_ds.class_counts)}")
    if len(train_ds) == 0:
        print("no training entries; check --index and splits")
        return 1

    sampler = make_sampler(train_ds, tuple(
        class_weights[n] for n in CLASS_NAMES))
    train_loader = DataLoader(
        train_ds, batch_size=args.batch, sampler=sampler,
        num_workers=args.workers, pin_memory=(device.type == "cuda"),
        drop_last=True)
    val_loader = DataLoader(
        val_ds, batch_size=args.batch, shuffle=False,
        num_workers=min(2, args.workers),
        pin_memory=(device.type == "cuda")) if len(val_ds) else None

    model = build_model(args).to(device)
    n_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"option {args.option}: {n_params:,} trainable parameters")

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr,
                            weight_decay=args.weight_decay)
    total_steps = max(1, args.epochs * len(train_loader))

    def lr_lambda(step: int) -> float:
        if step < args.warmup:
            return (step + 1) / max(1, args.warmup)
        p = (step - args.warmup) / max(1, total_steps - args.warmup)
        return 0.5 * (1.0 + math.cos(math.pi * min(1.0, p)))

    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_lambda)
    scaler = torch.cuda.amp.GradScaler(enabled=use_scaler)

    start_epoch = 0
    best_metric = float("inf")
    if args.resume:
        ckpt = torch.load(args.resume, map_location=device)
        model.load_state_dict(ckpt["model"])
        opt.load_state_dict(ckpt["optimizer"])
        sched.load_state_dict(ckpt["scheduler"])
        if use_scaler and "scaler" in ckpt:
            scaler.load_state_dict(ckpt["scaler"])
        start_epoch = ckpt["epoch"] + 1
        best_metric = ckpt.get("best_metric", float("inf"))
        print(f"resumed from {args.resume} (epoch {start_epoch})")

    train_log = open(run_dir / "train_log.csv", "a", newline="")
    train_csv = csv.writer(train_log)
    val_log = open(run_dir / "val_log.csv", "a", newline="")
    val_csv = csv.writer(val_log)
    with open(run_dir / "args.json", "w") as fh:
        json.dump(vars(args), fh, indent=1)

    global_step = start_epoch * len(train_loader)
    for epoch in range(start_epoch, args.epochs):
        model.train()
        t0 = time.time()
        for step, batch in enumerate(train_loader):
            sdr = batch["sdr"].to(device, non_blocking=True)
            hdr = batch["hdr"].to(device, non_blocking=True)
            peak = batch["peak_rel"].to(device, non_blocking=True)
            is_ui = (batch["class_idx"] == CLASS_NAMES.index("ui")).to(device)

            opt.zero_grad(set_to_none=True)
            ctx = (torch.autocast(device_type=device.type, dtype=amp_dtype)
                   if use_amp else torch.enable_grad())
            with ctx:
                expanded, gain, extras = forward_outputs(
                    args.option, model, sdr, peak)
                l_pq = losses.pq_l1(expanded, hdr, peak)
                l_exp = losses.expansion_only(gain)
                l_id = losses.identity_on_ui(gain, is_ui)
                loss = (l_pq + args.w_expand * l_exp +
                        args.w_identity * l_id)
                if args.w_tv > 0 and args.option == "A":
                    l_tv = losses.total_variation(gain)
                    loss = loss + args.w_tv * l_tv
                else:
                    l_tv = sdr.new_zeros(())
                if args.option == "B" and "lut" in extras:
                    l_lut = losses.lut_floor(extras["lut"],
                                             model.identity)
                    loss = loss + args.w_lut * l_lut

            if use_scaler:
                scaler.scale(loss).backward()
                scaler.unscale_(opt)
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                scaler.step(opt)
                scaler.update()
            else:
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                opt.step()
            sched.step()
            global_step += 1

            if step % args.log_every == 0:
                lr_now = opt.param_groups[0]["lr"]
                print(f"ep {epoch} st {step}/{len(train_loader)} "
                      f"loss {loss.item():.4f} pq {l_pq.item():.4f} "
                      f"exp {l_exp.item():.4f} id {l_id.item():.4f} "
                      f"lr {lr_now:.2e}", flush=True)
                train_csv.writerow([epoch, global_step, loss.item(),
                                    l_pq.item(), l_exp.item(), l_id.item(),
                                    l_tv.item(), lr_now])
                train_log.flush()

        state = {
            "option": args.option,
            "epoch": epoch,
            "model": model.state_dict(),
            "optimizer": opt.state_dict(),
            "scheduler": sched.state_dict(),
            "best_metric": best_metric,
            "args": vars(args),
        }
        if use_scaler:
            state["scaler"] = scaler.state_dict()
        torch.save(state, run_dir / "last.pt")

        if val_loader is not None and epoch % args.val_every == 0:
            per_class, weighted, n = validate(
                model, val_loader, args.option, device, amp_dtype, use_amp,
                class_weights)
            detail = " ".join(f"{k} {v:.2f}" for k, v in per_class.items())
            print(f"  val ep {epoch}: weighted {weighted:.2f} mPQ "
                  f"({detail}; n={n})", flush=True)
            val_csv.writerow([epoch, weighted, n] +
                             [per_class.get(k, "") for k in CLASS_NAMES])
            val_log.flush()
            if weighted < best_metric:
                best_metric = weighted
                state["best_metric"] = best_metric
                torch.save(state, run_dir / "best.pt")
                print(f"  new best ({best_metric:.2f} mPQ) -> best.pt",
                      flush=True)

        print(f"  epoch {epoch} wall {time.time() - t0:.1f}s", flush=True)

    train_log.close()
    val_log.close()
    if not (run_dir / "best.pt").exists() and (run_dir / "last.pt").exists():
        # No validation split available: best == last so downstream tooling
        # (evaluate/export defaults to best.pt) keeps working.
        torch.save(torch.load(run_dir / "last.pt", map_location="cpu"),
                   run_dir / "best.pt")
    print(f"done; best weighted val error: {best_metric:.2f} mPQ")
    print(f"checkpoints: {run_dir}/best.pt, {run_dir}/last.pt")
    return 0


if __name__ == "__main__":
    sys.exit(main())

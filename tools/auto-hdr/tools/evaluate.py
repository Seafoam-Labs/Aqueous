#!/usr/bin/env python3
"""Evaluate a trained Auto HDR checkpoint on the held-out test split
(docs/auto-hdr-model-training-plan.md S7).

Reports per-class PQ delta (primary), PU21 delta (constants need
verification), luminance-histogram distance, and gain behavior on UI
content. Also runs the mandatory baselines: the no-op and the Stage A
analytic curve at several boosts ("the curve is free" - the model must
beat it).

Usage:
  python tools/evaluate.py --ckpt runs/optiona/best.pt \
      --index data/pairs/index.jsonl --out runs/optiona/results.json
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from autohdr.color import luminance  # noqa: E402
from autohdr.dataset import CLASS_NAMES, PairDataset  # noqa: E402
from autohdr.metrics import (luminance_histogram_distance,  # noqa: E402
                             pq_delta_milli, pu21_delta)
from autohdr.models import (GainNet, LUTPredictor,  # noqa: E402
                            ParamRegressor, analytic_expand, clamp_at_peak)

ANALYTIC_BOOSTS = (0.25, 0.5, 0.75, 1.0)


def build_model(option: str, args_ckpt: dict):
    if option == "A":
        return GainNet(base=args_ckpt.get("base", 32))
    if option == "B":
        return LUTPredictor(lut_size=args_ckpt.get("lut_size", 9),
                            base=args_ckpt.get("base", 32))
    return ParamRegressor(base=args_ckpt.get("base", 32))


def model_expanded(option, model, sdr, peak):
    with torch.no_grad():
        if option == "A":
            gain = model(sdr, peak)
            return clamp_at_peak(sdr * gain, peak), gain
        if option == "B":
            expanded, _ = model(sdr)
            expanded = clamp_at_peak(expanded, peak)
            gain = luminance(expanded) / luminance(sdr).clamp_min(1e-6)
            return expanded, gain
        boost = model(sdr)
        return analytic_expand(sdr, boost, peak)


def accumulate(acc, name, e, h, peak, gain):
    acc[name]["pq_milli"] += pq_delta_milli(e, h, peak)
    acc[name]["pu21"] += pu21_delta(e, h, peak)
    acc[name]["hist_dist"] += luminance_histogram_distance(e, h, peak)
    acc[name]["mean_gain"] += float(gain.mean())
    acc[name]["n"] += 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--index", required=True)
    ap.add_argument("--out", default=None, help="write JSON results here")
    ap.add_argument("--max-samples", type=int, default=500)
    ap.add_argument("--split", default="test",
                    help="index split to evaluate (test|val|train)")
    ap.add_argument("--crop", type=int, default=256)
    args = ap.parse_args()

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    ckpt = torch.load(args.ckpt, map_location=device)
    option = ckpt["option"]
    model = build_model(option, ckpt.get("args", {}))
    model.load_state_dict(ckpt["model"])
    model.to(device).eval()
    print(f"option {option} checkpoint epoch {ckpt.get('epoch')} "
          f"(best {ckpt.get('best_metric', float('nan')):.2f} mPQ)")

    ds = PairDataset(args.index, split=args.split, crop=args.crop,
                     max_entries=args.max_samples)
    print(f"{args.split} entries: {len(ds)} {dict(ds.class_counts)}")
    if len(ds) == 0:
        print(f"no {args.split} entries")
        return 1

    model_acc = defaultdict(lambda: defaultdict(float))
    noop_acc = defaultdict(lambda: defaultdict(float))
    analytic_acc = {b: defaultdict(lambda: defaultdict(float))
                    for b in ANALYTIC_BOOSTS}

    for i in range(len(ds)):
        item = ds[i]
        name = CLASS_NAMES[item["class_idx"]]
        sdr = item["sdr"].unsqueeze(0).to(device)
        hdr = item["hdr"].unsqueeze(0).to(device)
        peak = item["peak_rel"].unsqueeze(0).to(device)

        expanded, gain = model_expanded(option, model, sdr, peak)
        accumulate(model_acc, name, expanded, hdr, peak, gain)

        ones = torch.ones_like(gain)
        accumulate(noop_acc, name, sdr, hdr, peak, ones)

        for b in ANALYTIC_BOOSTS:
            boost = torch.full((1,), b, device=device)
            e_a, g_a = analytic_expand(sdr, boost, peak)
            accumulate(analytic_acc[b], name, e_a, hdr, peak, g_a)

        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{len(ds)}", flush=True)

    def finish(acc):
        out = {}
        total_n = sum(v["n"] for v in acc.values()) or 1
        agg = defaultdict(float)
        for name, stats in acc.items():
            n = max(1, stats["n"])
            out[name] = {k: round(v / n, 4) for k, v in stats.items()
                         if k != "n"}
            out[name]["n"] = stats["n"]
            for k in ("pq_milli", "pu21", "hist_dist", "mean_gain"):
                agg[k] += stats[k]
        out["overall"] = {k: round(v / total_n, 4) for k, v in agg.items()}
        return out

    results = {
        "checkpoint": str(Path(args.ckpt).resolve()),
        "option": option,
        "model": finish(model_acc),
        "baseline_noop": finish(noop_acc),
        "baseline_analytic": {str(b): finish(analytic_acc[b])
                              for b in ANALYTIC_BOOSTS},
    }

    print(f"\n{'source':<22} {'pq_milli':>9} {'pu21':>8} {'hist':>7} "
          f"{'gain':>6}")
    for label, block in [("MODEL", results["model"]),
                         ("no-op", results["baseline_noop"])] + [
            (f"analytic b={b}", results["baseline_analytic"][str(b)])
            for b in ANALYTIC_BOOSTS]:
        for name in list(CLASS_NAMES) + ["overall"]:
            row = block.get(name)
            if not row:
                continue
            print(f"{label + '/' + name:<22} {row['pq_milli']:>9.2f} "
                  f"{row['pu21']:>8.3f} {row['hist_dist']:>7.3f} "
                  f"{row['mean_gain']:>6.3f}")
        print()

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(results, fh, indent=1)
        print(f"results: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

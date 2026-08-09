#!/usr/bin/env python3
"""Download Poly Haven HDRIs through their public API with a provenance
manifest (docs/auto-hdr-ship-corpus-training-plan.md S3).

API facts verified 2026-08-08:
* GET https://api.polyhaven.com/assets?t=hdris  -> whole catalog, one call,
  map keyed by asset id (name, categories, evs_cap, authors, ...).
* GET https://api.polyhaven.com/files/<id>      -> per-resolution file tree;
  files carry url (dl.polyhaven.org), md5, and byte size.
* Assets are CC0. Read the API terms page (polyhaven.com/api) before bulk
  pulls; be polite (sequential requests, ~1 req/s, resume instead of refetch).

Examples:
    python tools/download_polyhaven.py --out data/raw/polyhaven \
        --manifest data/polyhaven_manifest.jsonl --res 4k
    python tools/download_polyhaven.py ... --categories skies sunrise-sunset \
        --min-evs 20 --limit 250          # the sun-critical 8k subset logic
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
import urllib.request
from datetime import date
from pathlib import Path

API = "https://api.polyhaven.com"
UA = {"User-Agent": "aqueous-auto-hdr-corpus/0.1 (research)"}


def get_json(url: str, timeout: int = 90):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def stream_download(url: str, dest: Path, expected_md5: str | None):
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    md5 = hashlib.md5()
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=300) as resp, open(part, "wb") as fh:
        shutil.copyfileobj(resp, fh)
    # md5 over the downloaded file
    with open(part, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            md5.update(chunk)
    digest = md5.hexdigest()
    if expected_md5 and digest != expected_md5:
        part.unlink(missing_ok=True)
        raise IOError(f"md5 mismatch for {url}: {digest} != {expected_md5}")
    part.rename(dest)
    return digest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True, help="directory for downloads")
    ap.add_argument("--manifest", required=True, help="JSONL manifest path")
    ap.add_argument("--res", default="4k",
                    choices=["1k", "2k", "4k", "8k", "16k", "24k"])
    ap.add_argument("--categories", nargs="*", default=None,
                    help="keep assets having ANY of these categories")
    ap.add_argument("--min-evs", type=float, default=0.0,
                    help="require evs_cap >= this (dynamic range filter)")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--delay", type=float, default=1.0,
                    help="seconds between API calls")
    ap.add_argument("--no-md5", action="store_true")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"fetching catalog: {API}/assets?t=hdris")
    catalog = get_json(f"{API}/assets?t=hdris")
    ids = sorted(catalog.keys())
    selected = []
    for asset_id in ids:
        meta = catalog[asset_id]
        cats = meta.get("categories") or []
        if isinstance(cats, dict):
            cats = list(cats.keys())
        if args.categories and not set(args.categories) & set(cats):
            continue
        if float(meta.get("evs_cap") or 0.0) < args.min_evs:
            continue
        selected.append(asset_id)
    if args.limit:
        selected = selected[:args.limit]
    print(f"catalog: {len(ids)} assets, selected {len(selected)}")

    records = []
    for i, asset_id in enumerate(selected, 1):
        meta = catalog[asset_id]
        dest_base = out_dir / f"{asset_id}_{args.res}"
        existing = [p for p in (
            dest_base.with_suffix(".exr"), dest_base.with_suffix(".hdr"))
            if p.exists()]

        file_url = file_md5 = fmt = None
        size = None
        if existing and args.no_md5:
            dest = existing[0]
        else:
            time.sleep(args.delay)
            try:
                files = get_json(f"{API}/files/{asset_id}")
            except Exception as exc:  # noqa: BLE001
                print(f"[{i}/{len(selected)}] {asset_id}: files API failed: {exc}")
                continue
            hdri = files.get("hdri") or {}
            tier = hdri.get(args.res) or {}
            entry = tier.get("exr") or tier.get("hdr")
            if not entry:
                print(f"[{i}/{len(selected)}] {asset_id}: no {args.res} file")
                continue
            fmt = "exr" if "exr" in tier else "hdr"
            file_url = entry["url"]
            file_md5 = entry.get("md5")
            size = entry.get("size")
            dest = dest_base.with_suffix("." + fmt)

        ok = False
        if dest.exists():
            ok = True  # previously completed download
        else:
            try:
                stream_download(file_url, dest,
                                None if args.no_md5 else file_md5)
                ok = True
            except Exception as exc:  # noqa: BLE001
                print(f"[{i}/{len(selected)}] {asset_id}: download failed: {exc}")
        if not ok:
            continue

        cats = meta.get("categories") or []
        if isinstance(cats, dict):
            cats = list(cats.keys())
        records.append({
            "source": "polyhaven",
            "asset_id": asset_id,
            "license": "CC0",
            "url": file_url or str(dest),
            "resolution": args.res,
            "file": str(dest),
            "bytes": size or dest.stat().st_size,
            "md5_api": file_md5,
            "categories": cats,
            "evs_cap": meta.get("evs_cap"),
            "attribution_required": False,
            "download_date": date.today().isoformat(),
        })
        print(f"[{i}/{len(selected)}] {asset_id} ({args.res}) ok")

    manifest = Path(args.manifest)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    with open(manifest, "w", encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec) + "\n")
    print(f"manifest: {manifest} ({len(records)} records)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

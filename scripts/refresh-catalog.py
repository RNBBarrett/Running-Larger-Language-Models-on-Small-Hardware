#!/usr/bin/env python3
"""Refresh popularity stats in catalog.json from the HuggingFace API.

Updates each model's huggingfaceLikes / huggingfaceDownloads / quantRepoLikes /
quantRepoDownloads fields in place, plus the global popularityAsOf timestamp.

Usage:
    python scripts/refresh-catalog.py                # default catalog.json next to script
    python scripts/refresh-catalog.py --catalog path/to/catalog.json
    python scripts/refresh-catalog.py --quiet
    python scripts/refresh-catalog.py --token <hf_token>   # raises rate limit

The HF API is anonymous-accessible. With no token we get ~120 req/hr/IP, plenty
for ~50 models. With a token (free, https://huggingface.co/settings/tokens) we
get 1000s/hr.

Note: HF returns all-time `downloads` as the headline number. The 30d figure
shown on the website is `downloadsAllTime` minus a rolling baseline that the
public API does not surface, so this script stores all-time. For relative
ranking that is still meaningful.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API_BASE = "https://huggingface.co/api/models"


def fetch_repo_stats(repo_id: str, token: str | None) -> dict | None:
    """Returns {likes, downloads, lastModified} or None if not found."""
    if not repo_id:
        return None
    url = f"{API_BASE}/{repo_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "qwen-stack/refresh-catalog"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
        return {
            "likes": data.get("likes"),
            "downloads": data.get("downloads"),
            "lastModified": data.get("lastModified"),
        }
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        if e.code == 429:
            raise RuntimeError("HF API rate-limited. Wait a bit or supply --token.") from e
        return None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    here = Path(__file__).resolve().parent.parent
    ap.add_argument("--catalog", type=Path, default=here / "catalog.json")
    ap.add_argument("--token", default=os.environ.get("HF_TOKEN"))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not args.catalog.exists():
        print(f"catalog not found: {args.catalog}", file=sys.stderr)
        return 1

    with args.catalog.open(encoding="utf-8") as f:
        cat = json.load(f)

    models = cat.get("models", [])
    if not args.quiet:
        print(f"refreshing {len(models)} models from {API_BASE}")
        if not args.token:
            print("  (no HF token — limited to ~120 req/hr/IP; pass --token if you hit a wall)")

    updated = 0
    failed = 0
    for i, m in enumerate(models, 1):
        orig_repo = m.get("originalRepo")
        quant_repo = m.get("repo")
        label = m.get("id", "?")

        # Be polite — small delay between fetches keeps us well under any limit
        if i > 1:
            time.sleep(0.4)

        orig = fetch_repo_stats(orig_repo, args.token) if orig_repo else None
        if orig:
            m["huggingfaceLikes"] = orig["likes"]
            m["huggingfaceDownloads"] = orig["downloads"]
        else:
            m["huggingfaceLikes"] = None
            m["huggingfaceDownloads"] = None

        quant = fetch_repo_stats(quant_repo, args.token) if quant_repo else None
        if quant:
            m["quantRepoLikes"] = quant["likes"]
            m["quantRepoDownloads"] = quant["downloads"]
        else:
            m["quantRepoLikes"] = None
            m["quantRepoDownloads"] = None

        if orig or quant:
            updated += 1
            if not args.quiet:
                ol = orig["likes"] if orig else "?"
                od = orig["downloads"] if orig else "?"
                ql = quant["likes"] if quant else "?"
                qd = quant["downloads"] if quant else "?"
                print(f"  [{i:>2}/{len(models)}] {label:<28} orig:{ol}likes/{od}dl  quant:{ql}likes/{qd}dl")
        else:
            failed += 1
            if not args.quiet:
                print(f"  [{i:>2}/{len(models)}] {label:<28} -- both repos unreachable")

    cat["popularityAsOf"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")

    with args.catalog.open("w", encoding="utf-8") as f:
        json.dump(cat, f, indent=2, ensure_ascii=False)
        f.write("\n")

    if not args.quiet:
        print(f"\n{updated} updated, {failed} unreachable. Stamp: {cat['popularityAsOf']}")
    return 0 if updated else 2


if __name__ == "__main__":
    sys.exit(main())

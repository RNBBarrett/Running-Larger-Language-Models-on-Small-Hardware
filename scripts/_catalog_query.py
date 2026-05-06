#!/usr/bin/env python3
"""Internal helper: emit catalog entries as pipe-delimited lines for shell consumption.

Output format (one line per entry, fields pipe-delimited):
    id|name|family|repo|file|pattern|sizeGiB|minRamGiB|activeB|category|tier|releaseDate|good|bad|mmluPro|liveCodeBench|gpqaDiamond|cyberMetric|huggingfaceLikes|huggingfaceDownloads

Bash callers use IFS='|' read -r ... <<< "$line" to consume. Missing values become
empty strings (so positional parsing stays stable). Pipes inside text fields are
stripped to underscores.

Usage:
    python3 scripts/_catalog_query.py
    python3 scripts/_catalog_query.py --category coding
    python3 scripts/_catalog_query.py --category cyber-offense --sort cyberMetric
    python3 scripts/_catalog_query.py --sort releaseDate     # newest first
    python3 scripts/_catalog_query.py --sort huggingfaceLikes
    python3 scripts/_catalog_query.py --counts               # categoryCounts mode

Exit codes: 0 ok, 1 bad args, 2 catalog missing/unparseable.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

CATEGORY_PRIMARY_BENCH = {
    "coding": "liveCodeBench",
    "general": "mmluPro",
    "reasoning": "gpqaDiamond",
    "cyber-offense": "cyberMetric",
    "cyber-defense": "cyberMetric",
}

FIELDS = [
    "id", "name", "family", "repo", "file", "pattern",
    "sizeGiB", "minRamGiB", "activeB", "category", "tier", "releaseDate",
    "good", "bad",
    "mmluPro", "liveCodeBench", "gpqaDiamond", "cyberMetric",
    "huggingfaceLikes", "huggingfaceDownloads",
]


def sort_key_value(entry: dict, key: str) -> tuple[int, float | str]:
    """Returns a (numeric|string, value) tuple — first element separates numeric vs string sort to avoid TypeErrors when mixed."""
    if key in {"liveCodeBench", "mmluPro", "gpqaDiamond", "cyberMetric"}:
        v = (entry.get("benchmarks") or {}).get(key)
        return (0, float(v)) if isinstance(v, (int, float)) else (0, -1.0)
    if key in {"huggingfaceLikes", "huggingfaceDownloads"}:
        v = entry.get(key)
        return (0, float(v)) if isinstance(v, (int, float)) else (0, -1.0)
    if key == "releaseDate":
        v = entry.get("releaseDate")
        return (1, v if isinstance(v, str) else "0000")
    v = entry.get(key)
    return (0, float(v)) if isinstance(v, (int, float)) else (0, -1.0)


def normalize(s) -> str:
    if s is None:
        return ""
    return str(s).replace("|", "_").replace("\r", " ").replace("\n", " ")


def emit_line(entry: dict) -> str:
    bench = entry.get("benchmarks") or {}
    cells = [
        normalize(entry.get("id")),
        normalize(entry.get("name")),
        normalize(entry.get("family")),
        normalize(entry.get("repo")),
        normalize(entry.get("file")),
        normalize(entry.get("pattern")),
        normalize(entry.get("sizeGiB")),
        normalize(entry.get("minRamGiB")),
        normalize(entry.get("activeB")),
        normalize(entry.get("category")),
        normalize(entry.get("tier")),
        normalize(entry.get("releaseDate")),
        normalize(entry.get("good")),
        normalize(entry.get("bad")),
        normalize(bench.get("mmluPro")),
        normalize(bench.get("liveCodeBench")),
        normalize(bench.get("gpqaDiamond")),
        normalize(bench.get("cyberMetric")),
        normalize(entry.get("huggingfaceLikes")),
        normalize(entry.get("huggingfaceDownloads")),
    ]
    return "|".join(cells)


def main() -> int:
    here = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", type=Path, default=here / "catalog.json")
    ap.add_argument("--category", help="filter to one category (or 'all')")
    ap.add_argument("--sort", help="sort key: liveCodeBench|mmluPro|gpqaDiamond|cyberMetric|releaseDate|huggingfaceLikes|huggingfaceDownloads")
    ap.add_argument("--counts", action="store_true", help="emit 'category|count' lines instead of entries")
    args = ap.parse_args()

    if not args.catalog.exists():
        print(f"catalog missing: {args.catalog}", file=sys.stderr)
        return 2
    try:
        with args.catalog.open(encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"catalog parse error: {e}", file=sys.stderr)
        return 2

    models = data.get("models", [])

    if args.counts:
        counts: dict[str, int] = {}
        for m in models:
            c = m.get("category") or "uncategorized"
            counts[c] = counts.get(c, 0) + 1
        for c in sorted(counts):
            print(f"{c}|{counts[c]}")
        print(f"all|{len(models)}")
        return 0

    if args.category and args.category != "all":
        models = [m for m in models if m.get("category") == args.category]

    if args.sort:
        # releaseDate sorts ascending alphabetically; we want newest, so reverse
        models = sorted(models, key=lambda m: sort_key_value(m, args.sort), reverse=True)

    for m in models:
        print(emit_line(m))
    return 0


if __name__ == "__main__":
    sys.exit(main())

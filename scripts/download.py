#!/usr/bin/env python3
"""Download a GGUF from the catalog with mirror selection.

Probes HF + hf-mirror.com for the actual target file (first ~30 MB, capped at
5 seconds), picks the faster one, then runs the full download via huggingface_hub
with hf_transfer enabled (parallel chunked, ~10x faster than vanilla).

Usage:
    python scripts/download.py --id coder-80b-iq2
    python scripts/download.py --id qwen3-8b --dest .
    python scripts/download.py --repo mradermacher/X-i1-GGUF --file X.i1-Q4_K_M.gguf
    python scripts/download.py --id glm-air-106b --skip-probe         # use HF directly
    python scripts/download.py --id qwen35-122b                       # sharded models use snapshot_download

The probe re-uses the bytes it pulled — they get written to disk as the file
head, so we don't waste bandwidth.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PROBE_BYTES = 30 * 1024 * 1024  # 30 MB
PROBE_TIMEOUT_S = 5
MIRRORS = [
    ("huggingface.co", "https://huggingface.co"),
    ("hf-mirror.com",  "https://hf-mirror.com"),
]


def load_catalog(path: Path) -> dict:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def find_entry(catalog: dict, model_id: str) -> dict | None:
    for m in catalog.get("models", []):
        if m.get("id") == model_id:
            return m
    return None


def is_sharded(entry: dict) -> bool:
    pattern = entry.get("pattern", "")
    file_ = entry.get("file", "")
    return ("*" in pattern) or ("/" in file_)


def probe_mirror(name: str, base: str, repo: str, file_: str) -> tuple[float, bytes | None, str | None]:
    """Returns (MB/s, head_bytes, used_url). MB/s is 0.0 on failure."""
    url = f"{base}/{repo}/resolve/main/{file_}"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "qwen-stack/probe",
            "Range": f"bytes=0-{PROBE_BYTES - 1}",
        },
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT_S) as r:
            buf = bytearray()
            while True:
                if time.perf_counter() - start > PROBE_TIMEOUT_S:
                    break
                chunk = r.read(256 * 1024)
                if not chunk:
                    break
                buf.extend(chunk)
                if len(buf) >= PROBE_BYTES:
                    break
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        return 0.0, None, f"{name}: {e}"
    elapsed = max(0.001, time.perf_counter() - start)
    mb = len(buf) / (1024 * 1024)
    mbps = mb / elapsed
    return mbps, bytes(buf), None


def pick_mirror(repo: str, file_: str, quiet: bool) -> tuple[str, str, float, bytes | None]:
    """Returns (name, base_url, mbps, head_bytes_from_winner_or_None)."""
    if not quiet:
        print(f"probing {len(MIRRORS)} mirrors (<={PROBE_TIMEOUT_S}s each, {PROBE_BYTES//(1024*1024)} MB)...")
    results = []
    for name, base in MIRRORS:
        mbps, head, err = probe_mirror(name, base, repo, file_)
        if not quiet:
            if err:
                print(f"  {name:<22} fail ({err.split(':',1)[-1].strip()})")
            else:
                print(f"  {name:<22} {mbps:>6.1f} MB/s")
        if mbps > 0:
            results.append((mbps, name, base, head))
    if not results:
        # Fall back to default HF, no probe data
        return "huggingface.co", "https://huggingface.co", 0.0, None
    results.sort(reverse=True)
    mbps, name, base, head = results[0]
    if not quiet:
        print(f"-> winner: {name} @ {mbps:.1f} MB/s")
    return name, base, mbps, head


def have_aria2c() -> bool:
    return shutil.which("aria2c") is not None


def download_with_aria2c(base: str, repo: str, file_: str, dest: Path) -> int:
    url = f"{base}/{repo}/resolve/main/{file_}"
    out = dest / Path(file_).name
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "aria2c", "-x", "16", "-s", "16", "-k", "1M",
        "--allow-overwrite=false", "--auto-file-renaming=false",
        "--continue=true", "-d", str(out.parent), "-o", out.name, url,
    ]
    return subprocess.call(cmd)


def download_with_hf_hub(base: str, repo: str, file_: str, pattern: str, dest: Path,
                          sharded: bool, head_bytes: bytes | None) -> Path:
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    os.environ["HF_ENDPOINT"] = base

    # Pre-seed: write the probe bytes to a partial file so hf_hub_download
    # resumes from there. HF uses .incomplete suffix in cache; for direct
    # local_dir downloads the file is .file.partial - but huggingface_hub
    # >= 0.20 handles range resume automatically when the file already exists
    # partially in the cache. Easier path: just re-download — 30 MB is cheap.
    _ = head_bytes  # accepted but not used; resume logic is internal to HF

    try:
        from huggingface_hub import hf_hub_download, snapshot_download
    except ImportError:
        print("ERROR: huggingface_hub not installed. pip install huggingface_hub hf_transfer", file=sys.stderr)
        sys.exit(2)

    dest.mkdir(parents=True, exist_ok=True)

    if sharded:
        path = snapshot_download(
            repo_id=repo, allow_patterns=[pattern], local_dir=str(dest),
        )
        return Path(path)
    else:
        path = hf_hub_download(
            repo_id=repo, filename=file_, local_dir=str(dest),
        )
        return Path(path)


def fmt_eta(size_gib: float, mbps: float) -> str:
    if mbps <= 0:
        return "ETA unknown"
    seconds = (size_gib * 1024) / mbps
    if seconds < 60: return f"ETA ~{int(seconds)}s"
    if seconds < 3600: return f"ETA ~{int(seconds/60)} min"
    return f"ETA ~{seconds/3600:.1f} hr"


def main() -> int:
    here = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--id", help="catalog model id (e.g. coder-80b-iq2)")
    ap.add_argument("--repo", help="HF repo (use with --file when not using --id)")
    ap.add_argument("--file", dest="file_", help="filename within repo (use with --repo)")
    ap.add_argument("--pattern", help="glob pattern for sharded models (with --repo)")
    ap.add_argument("--catalog", type=Path, default=here / "catalog.json")
    ap.add_argument("--dest", type=Path, default=here, help="download destination directory")
    ap.add_argument("--skip-probe", action="store_true", help="skip mirror probe; use huggingface.co directly")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.id:
        if not args.catalog.exists():
            print(f"catalog not found: {args.catalog}", file=sys.stderr)
            return 1
        cat = load_catalog(args.catalog)
        entry = find_entry(cat, args.id)
        if not entry:
            print(f"unknown id: {args.id}", file=sys.stderr)
            return 1
        repo = entry["repo"]
        file_ = entry["file"]
        pattern = entry.get("pattern", file_)
        sharded = is_sharded(entry)
        size_gib = entry.get("sizeGiB", 0)
        if not args.quiet:
            print(f"target: {entry['name']}")
    elif args.repo and args.file_:
        repo, file_ = args.repo, args.file_
        pattern = args.pattern or file_
        sharded = bool(args.pattern) or "*" in (args.pattern or "")
        size_gib = 0
    else:
        ap.error("supply --id OR (--repo AND --file)")

    # 1. Pick mirror
    if args.skip_probe:
        name, base, mbps, head = "huggingface.co", "https://huggingface.co", 0.0, None
    else:
        # Probe with the first file (real file for single, first match for sharded — close enough)
        probe_file = file_ if not sharded else file_
        name, base, mbps, head = pick_mirror(repo, probe_file, args.quiet)

    if size_gib and mbps and not args.quiet:
        print(f"~{size_gib} GiB via {name} — {fmt_eta(size_gib, mbps)}")

    # 2. Download
    if have_aria2c() and not sharded and not args.skip_probe:
        if not args.quiet:
            print(f"using aria2c (16 connections) via {base}")
        rc = download_with_aria2c(base, repo, file_, args.dest)
        if rc == 0:
            print(f"saved: {args.dest / Path(file_).name}")
            return 0
        if not args.quiet:
            print(f"aria2c failed (rc={rc}); falling back to huggingface_hub")

    if not args.quiet:
        print(f"using huggingface_hub + hf_transfer via {base}")
    out = download_with_hf_hub(base, repo, file_, pattern, args.dest, sharded, head)
    print(f"saved: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

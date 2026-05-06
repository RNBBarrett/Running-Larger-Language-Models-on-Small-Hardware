# Local abliterated LLM stack

A self-contained, **fully local**, **abliterated** (uncensored) LLM stack built around `llama.cpp` + Open WebUI + MCP tools. One script auto-detects your hardware, downloads a hardware-appropriate model from a curated catalog, and launches everything.

Works on **Windows**, **Linux**, and **macOS**.

## What you get

Out of the box, on the **baseline reference machine** (specs below):

- **Qwen3-Coder-Next 80B-A3B abliterated** running at **~13 tok/s warm-cache** in chat
- A **chat UI** (Open WebUI) at http://127.0.0.1:3000 with persistent history, multi-conversation, and tool toggles
- **Six free MCP-based tools** wired in for the model to call: web search (DuckDuckGo), URL fetch, Wikipedia, arXiv, time/date, persistent memory
- **OpenAI-compatible API** at http://127.0.0.1:8088/v1 — drop-in for any local-LLM client
- **Zero API costs**, zero data leaves the machine, no refusals

### Baseline reference machine

| Component | Spec |
|---|---|
| CPU | AMD Ryzen 9 3900X (12 cores / 24 threads) |
| GPU | AMD Radeon RX 5700 XT (8 GB VRAM, RDNA 1 / gfx1010) |
| RAM | 16 GB DDR4-3200 (running at 2133 MT/s by default — DOCP off) |
| Storage | NVMe Gen4 (~7 GB/s sequential reads) |
| OS | Windows 11 |

This is a deliberately constrained machine — RDNA 1 has no ROCm support on Windows, and 16 GB RAM is below the model file size. The stack still runs an **80B-parameter MoE model** at usable speed via NVMe expert streaming. Better hardware → better numbers; the script auto-tunes either way.

### Measured throughput on the baseline

| Workload | Result |
|---|---|
| Single-prompt warm-cache | **~13 tok/s** |
| Single-prompt cold-cache | ~5–6 tok/s (first prompt, OS warming page cache) |
| First-token latency (warm) | ~3 sec |
| VRAM used during inference | ~6.5–7.4 GB (out of 8) |
| Context window in use | 8K tokens (262K native, capped by 8 GB VRAM) |
| Tool-call round-trip | ~10–15 sec end-to-end (search + fetch + answer) |

For comparison, this same machine without the optimizations runs the same model at ~1 tok/s or fails to load it entirely.

## Quick start

**Windows** (PowerShell, from this directory):
```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

**Linux / macOS** (bash):
```bash
chmod +x ./start.sh   # one-time
./start.sh
```

First run shows the model picker (catalog scored against your detected RAM), downloads your chosen model from HuggingFace, and launches the full stack. Subsequent runs skip the picker and just bring services back up.

Once running:
- **Chat**: http://127.0.0.1:3000
- **API**: http://127.0.0.1:8088/v1

## Scripts in this repo

| File | Platform | What it does |
|---|---|---|
| **`start.ps1`** | Windows | Detects hardware via WMI + llama-server probe; resolves model from catalog or `-Model`; auto-tunes llama.cpp flags; regenerates MCPO config with current paths; launches llama-server + Open WebUI + MCPO each in its own window. |
| **`start.sh`** | Linux + macOS | Same logic in bash. Detects via `nvidia-smi` / `rocm-smi` / `system_profiler`. On Apple Silicon, treats unified memory as VRAM and enables `--mlock`. Runs services as `nohup` background jobs with logs in `~/tools/logs/`. |
| **`README.md`** | — | This file. |
| **`.gitignore`** | — | Excludes downloaded `.gguf` files (the scripts pull them on demand, no need to commit ~20 GB of weights). |

Both scripts share the same flag conventions:

| Windows | Linux/macOS | Effect |
|---|---|---|
| `-Model "<id\|file>"` | `--model "<id\|file>"` | Use a specific catalog entry (by id) or GGUF filename |
| `-Pick` | `--pick` | Force the interactive catalog picker |
| `-DownloadOnly` | `--download-only` | Fetch the model and exit |
| `-OnlyLlama` | `--only-llama` | Start only llama-server (skip Open WebUI + MCPO) |
| `-Force` | `--force` | Stop running instances and relaunch with fresh flags |

## Use with a coding agent (recommended)

Open WebUI is great for chat, research, and one-shot questions. But for **real coding work** — multi-step edits across files, running tests, iterating on bug fixes — you want a coding agent driving the local model. The local model exposes an OpenAI-compatible API at `http://127.0.0.1:8088/v1`, so most agents work with one config line.

Recommended pairings, in order of how well they handle a slow local model:

| Agent | Why it's a good fit | Setup |
|---|---|---|
| **Aider** | Best in class for local models. Multiple edit formats, repo-map for compact context, auto-commits to git so failed runs don't trash work. Lean prompt overhead. | `pip install aider-chat` then export `OPENAI_API_BASE=http://127.0.0.1:8088/v1` and run `aider --model openai/qwen3-coder-next` |
| **opencode** (`sst/opencode`) | Modern terminal/desktop UI, native MCP support, model picker. Heavier prompt overhead than Aider — slower on each turn at this throughput. | Install via npm/installer, point its `local-llama` provider at `http://127.0.0.1:8088/v1` |
| **Cline** / **Roo Code** (VSCode) | Visual diff approval, in-IDE workflow. Built around Claude-class models so retries can be excessive. | VSCode Marketplace → Cline → settings → custom OpenAI provider |
| **Continue** (VSCode/JetBrains) | Sidebar chat + autocomplete. Lightweight. | Add `apiBase: http://127.0.0.1:8088/v1` to its config |

The local model used here (`Qwen3-Coder-Next 80B-A3B abliterated`) was specifically post-trained for **agentic tool-use trajectories** — it knows how to read a file, propose an edit, run a test, and iterate. That fine-tune is the difference between "this agent crashes after 3 steps" and "this agent finishes the task."

**General principle**: use Open WebUI for chat / research / one-shot answers; reach for a coding agent the moment you want the model to actually edit files in a project.

## Optimizations applied

Each of these moved the needle on the baseline hardware. The auto-tune in `start.ps1` / `start.sh` enables them based on detected specs.

### Backend choice

- **Vulkan over ROCm.** RDNA 1 (`gfx1010`) has no ROCm support on Windows at all. Vulkan via prebuilt `llama.cpp` binaries works on any GPU with Vulkan 1.2+ drivers and gets ~80–90% of CUDA's perf for inference.

### Memory & streaming

- **`--override-tensor "exps=CPU"`** — granular MoE expert offload. Keeps shared experts, attention, and dense FFN on GPU; routes only the routed expert tensors to CPU/disk. More efficient than `--n-cpu-moe N` (which is layer-bucket based).
- **mmap streaming (default-on)** — model file is memory-mapped, OS pages experts in on demand. Combined with `-ot exps=CPU` this is what lets a 19.6 GB model run on 16 GB RAM.
- **No `--mlock` on this baseline** — model > RAM means pinning fails. Auto-tune correctly disables it.
- **KV cache quantization (`q8_0`)** — halves KV cache VRAM usage, lets us fit 8K context on 8 GB VRAM. Quality impact: imperceptible.

### Compute

- **`-b 2048 -ub 2048`** — micro-batch size. Default `512` made prefill slow (matters with agentic tools that send 4–9k token prompts every turn). RDNA 1 caps the host-pinned compute buffer ~2 GB, so `-ub 4096` OOMs but `-ub 2048` works and roughly doubles prefill speed.
- **`--flash-attn on`** — meaningful speedup on Vulkan in current llama.cpp builds.

### Right model for the hardware

- **Qwen3-Next architecture** (hybrid SSM + MoE Gated Delta Net). Only 12 of 48 layers do traditional attention, so KV cache is tiny per token — that's why we get full 262K native context support on 8 GB VRAM (1.6 GB KV at q8_0 across the whole window).
- **A3B (3 B active parameters)** — only 3 B params actually fire per token, so working-set RAM stays small even though the model is 80 B total. This is what makes mmap streaming viable.
- **IQ2_XXS quantization** — 80 B params at ~2.5 bits/param ≈ 20 GB. Just over RAM size, leverages OS page cache for the hot ~10 GB and pages the rest from NVMe.

### Tooling layer

- **MCPO (MCP-to-OpenAPI bridge)** — wraps stdio MCP servers as REST endpoints Open WebUI can register. Lets us add fetch/search/wiki/arxiv/time/memory without per-tool plumbing.
- **Runtime-generated MCPO config** — paths regenerated from `$env:USERPROFILE` / `$HOME` on every launch, so no machine-specific data sits in the repo.
- **API key auto-provisioning** — `start.ps1` sets `ENABLE_API_KEYS=True` and the script can talk to Open WebUI's admin API if needed.

### What we tried that *didn't* work (and why)

| Attempt | Outcome |
|---|---|
| ROCm on Windows for RDNA 1 | Not supported. AMD only ships ROCm on Windows for RDNA 3 and partial RDNA 2. |
| `ik_llama.cpp` (1.9× MoE speedup) | No Vulkan backend. The README explicitly says "do not file issues for ROCm, Vulkan, Metal." Hardware-blocked. |
| `KHR_coopmat` (Vulkan matmul accel) | RDNA 1 doesn't expose it. Available on RDNA 3+. |
| Speculative decoding | Empirically benchmarked April 2026 on RTX 3090: net-negative on A3B models. Each drafted token pulls a fresh expert slice, verification cost dominates. |
| OpenAI codex CLI | codex 0.128 sends MCP-typed tools that llama.cpp's `/v1/responses` rejects. Even with a tool-filter proxy, codex's stream parser breaks on llama.cpp's response shape. Use opencode or Aider instead. |
| Qwen3.5-122B-A10B | Loads but unusable (~1–3 tok/s) on 16 GB RAM — A10B's working set blows RAM cache. Becomes viable with 64 GB RAM. |

## Choosing a different model

The script ships with a curated catalog of abliterated MoE models, scored against your detected RAM:

- **`[ok]`** — fits cleanly in your RAM cache, no disk paging
- **`[~]`** — tight fit, works via mmap streaming but slower cold-prompts
- **`[!]`** — needs more RAM than you have; will be very slow

Browse + pick interactively:

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File start.ps1 -Pick
```

```bash
# Linux/macOS
./start.sh --pick
```

Or jump straight to a known catalog ID / filename:

```powershell
.\start.ps1 -Model "thinking-iq2"             # by catalog id
.\start.ps1 -Model "Huihui-...IQ2_XXS.gguf"   # by exact filename
```

Catalog covers ~9 models from Coder/Instruct/Thinking variants of Qwen3-Next-80B (16 GiB RAM friendly) up through GLM-4.5-Air and Qwen3.5-122B (64+ GiB RAM tier). Auto-downloads from HuggingFace when you pick something not on disk.

## What's running where

| Service | URL | Purpose |
|---|---|---|
| **Open WebUI** | http://127.0.0.1:3000 | Chat UI — primary interface |
| **llama-server** | http://127.0.0.1:8088/v1 | OpenAI-compatible API |
| **MCPO** | http://127.0.0.1:8091 | MCPs as REST tools (fetch, ddg, wiki, arxiv, time, memory) |

## Stop everything

**Windows**:
```powershell
Get-Process llama-server,open-webui,mcpo -ErrorAction SilentlyContinue | Stop-Process -Force
```

**Linux / macOS**:
```bash
pkill -f 'llama-server|open-webui|mcpo'
```

## When to use which interface

| Use case | Interface |
|---|---|
| Single question, quick answer | **Open WebUI** (fastest, minimal overhead) |
| Web research, look-up + summarize | **Open WebUI** with tools enabled (🔧 icon in chat) |
| Edit files in a project, multi-step agent loop | **Aider** or **opencode** |
| Cybersecurity Q&A / methodology | **Open WebUI** |
| Writing exploit code / payloads | **Open WebUI** or coding agent |

## Tools in Open WebUI

In any new chat, click the 🔧 / tool icon near the input box and toggle on:
- **fetch** — read any URL
- **DuckDuckGo** — web search (rate-limited, free)
- **Wikipedia** — encyclopedia
- **arXiv** — academic papers
- **Time** — date utilities
- **Memory** — persistent across sessions

The Coder model needs explicit prompting to use them — say "search the web for X" not just "what's X today". The Coder fine-tune doesn't autonomously reach for research tools.

## What the model is good at

`Qwen3-Coder-Next 80B-A3B abliterated` (current default):

- ✅ Code generation, refactoring, debugging
- ✅ Cybersecurity scripting (uncensored, no refusals)
- ✅ Tool/agent loops (specifically tuned for this)
- ✅ Long context (262K native, ~128K practical at 8 GB VRAM)
- ⚠️ Pure research/synthesis — Coder bias makes it less proactive about web tools. Use the Thinking or Instruct variant from the catalog if research is your main use case.

## Hardware upgrade path

The stack auto-tunes as your machine evolves:

| Upgrade | Approx cost | What it unlocks |
|---|---|---|
| **DOCP / XMP enabled in BIOS** | $0 | RAM at rated 3200 MT/s instead of 2133 → ~25–35% throughput uplift |
| **64 GB RAM** | ~$100 used | `--mlock` becomes feasible; Q4 quants run cleanly; gpt-oss-120b and Qwen3.5-122B viable; cold-prompt cliff disappears |
| **GPU swap to Intel Arc Pro B70 32 GB** | ~$800 net | 4× VRAM, native XMX matrix engines, 2.7× memory bandwidth; current model fits entirely on GPU at ~50–70 tok/s |

Run `start.ps1 -Force` (or `--force`) after any hardware change — auto-tune detects and adjusts.

## Platform-specific notes

### Linux setup expectations

`start.sh` assumes:
- llama-server at `~/tools/llama.cpp/llama-server` (or `~/llama.cpp/build/bin/llama-server`, or homebrew, or on PATH)
- venv at `~/tools/open-webui-venv/` with `pip install open-webui mcpo mcp-server-fetch duckduckgo-mcp-server wikipedia-mcp arxiv-mcp-server mcp-server-time`
- The GGUF in the same directory as `start.sh` (auto-downloaded if missing)

VRAM detection tries `nvidia-smi`, then `rocm-smi`, then llama-server's device probe. Works on:
- NVIDIA (CUDA build of llama.cpp)
- AMD (ROCm build, or Vulkan)
- Intel Arc (Vulkan or SYCL build)

### macOS setup expectations

`start.sh` assumes:
- llama-server at `/opt/homebrew/bin/llama-server` (`brew install llama.cpp`) or built locally
- The Metal backend is auto-used on Apple Silicon (no flag needed)
- VRAM = full system RAM on Apple Silicon (unified memory)
- `--mlock` is auto-enabled on Apple Silicon

For Apple Silicon (M1/M2/M3/M4), the same Qwen3-Coder-Next IQ2_XXS runs at ~25–40 tok/s on 16 GB Macs, ~50+ tok/s on 32 GB Macs.

## Override / customize

Both scripts honor these env vars (set before running):

| Variable | What it overrides |
|---|---|
| `TOOLS_DIR` | Where the venv / llama.cpp / mcpo dirs live (default: `~/tools` or `$env:USERPROFILE\tools`) |
| `LLAMA_BIN` | Full path to llama-server binary |
| `VENV_PYTHON` | Full path to Python in the venv (used for HF downloads) |
| `WEBUI_BIN` | Full path to `open-webui` executable |
| `MCPO_BIN`, `MCPO_CONFIG` | MCPO binary and config path |
| `DATA_DIR` | Where Open WebUI keeps its DB / cache (default: `$TOOLS_DIR/open-webui-data`) |
| `LOCAL_TZ` | IANA timezone name for `mcp-server-time` (default: detected, falls back to UTC) |
| `MODEL`, `MODEL_REPO` | Skip the picker and use a specific GGUF |

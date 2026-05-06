# Running Larger Language Models on Small Hardware

[![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078d4)](https://learn.microsoft.com/powershell/)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-fcc624?logo=linux&logoColor=black)](#linux--macos-bash)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-000?logo=apple)](#macos-setup-expectations)
[![llama.cpp](https://img.shields.io/badge/inference-llama.cpp-blue)](https://github.com/ggml-org/llama.cpp)
[![Open WebUI](https://img.shields.io/badge/UI-Open%20WebUI-success)](https://github.com/open-webui/open-webui)
[![MCP](https://img.shields.io/badge/tools-MCP-purple)](https://modelcontextprotocol.io/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](#license)

> **Run an 80B-parameter LLM on a machine with 8 GB VRAM and 16 GB RAM** — fully local, abliterated (uncensored), with web search and a chat UI. One script auto-detects your hardware, picks an appropriate model from a curated catalog, applies every relevant `llama.cpp` efficiency, and benchmarks the result on your machine.
>
> **Inspiration**: [Running a 35B AI Model on 6GB VRAM, FAST (llama.cpp Guide)](https://youtu.be/8F_5pdcD3HY) — a YouTube walkthrough showing how `llama.cpp`'s expert-offload trick lets a 35B MoE run on a tiny GPU. **This repo replicates that approach on different hardware (AMD RDNA 1 instead of NVIDIA, 8 GB VRAM instead of 6) and pushes it further: a full 80B-parameter MoE running locally with autonomous tool use.**

## The mission

The [source video](https://youtu.be/8F_5pdcD3HY) demonstrates a clever technique: with `llama.cpp`'s `--n-cpu-moe` (and the more granular `--override-tensor` flag), a Mixture-of-Experts model can keep its small dense layers on the GPU while streaming the huge expert weights from system RAM/disk. Because only a few experts fire per token, the GPU stays the bottleneck for compute and the disk only handles a fraction of the weights — even though the model file is bigger than VRAM.

The video runs **35B params on 6 GB VRAM**. We set out to:

1. **Replicate it** on different hardware (AMD RDNA 1, which has no ROCm support on Windows)
2. **Push further**: an **80B-parameter** MoE on 8 GB VRAM, not 35B on 6
3. **Make it work for anyone**: instead of hardcoding flags, write one script that detects the user's hardware, presents a tier-appropriate model catalog, applies the right efficiencies automatically, and measures actual tok/s on their machine
4. **Add agentic tooling**: web search, fetch, Wikipedia, persistent memory — all free, all local, all callable by the model

Result: this repo. The same script that runs an 80B MoE on a 16 GB / 8 GB VRAM box will run a 4B model on a 16 GB Mac mini, GLM-4.5-Air on a 64 GB workstation, or a Qwen3.5-122B on an 80 GB / 32 GB-VRAM rig — same code path, different auto-tuned flags, different catalog entries marked `[ok]` vs `[~]` vs `[!]`.

## How the efficiencies stack up

Each technique in this list does one specific thing. Combined, they're what lets the same model run usefully on hardware that "shouldn't" handle it. The script applies whichever ones make sense for your detected specs.

### 1. Vulkan backend (vendor-agnostic GPU acceleration)

**What it does**: routes `llama.cpp`'s GPU compute through the Vulkan API instead of CUDA / ROCm / Metal.
**Why it matters**: works on any GPU with Vulkan 1.2+ drivers — NVIDIA, AMD (including older RDNA 1 cards with no ROCm support on Windows), Intel Arc. Roughly 80–90% of CUDA's perf for inference. The reference baseline machine (RDNA 1) has no other GPU-acceleration option on Windows.

### 2. MoE expert offload via `--override-tensor "exps=CPU"`

**What it does**: a regex-based flag that tells `llama.cpp` exactly which tensors live where. We send only the routed-expert tensors to CPU/disk; shared experts, attention layers, and dense FFN stay on GPU.
**Why it matters**: the magic at the heart of the source video. A 80B MoE has ~75 GB of weights at Q4 — but only ~3 GB fire per token (the "active params"). Pushing experts off-GPU means the GPU only holds the ~5 GB of weights that fire on every token, leaving the other 70 GB in cheap CPU/disk territory. More granular than `--n-cpu-moe N` (which is layer-bucket based).

### 3. NVMe expert streaming via `mmap`

**What it does**: the model file is memory-mapped instead of being loaded into RAM. The OS pages individual experts in on demand from disk, caches what's hot, and evicts what's cold.
**Why it matters**: this is what lets a 21 GB model run on 16 GB RAM. With Gen4 NVMe (~7 GB/s sequential), pulling in cold experts costs ~1–2 ms per page-fault. After warmup, the working set settles into RAM cache. Combined with `-ot exps=CPU` above: dense layers on GPU, hot experts in RAM cache, cold experts on disk, all transparently coordinated by the OS.

### 4. Hybrid SSM + MoE architecture (Qwen3-Next)

**What it does**: the Qwen3-Next family uses **Gated Delta Net** — only 12 of 48 layers do traditional attention; the rest use linear/recurrent state updates.
**Why it matters**: KV cache scales linearly with attention-layer count × token count. Traditional dense-attention models eat your 8 GB VRAM with KV cache before you reach 32K context. Qwen3-Next's hybrid design means **8K context costs ~100 MB of KV cache, 128K costs ~1.6 GB, full 262K costs ~3 GB** — you can run native long-context on a small GPU. This is the architecture-level efficiency that separates "kinda works" from "actually usable."

### 5. A3B active params (Qwen3-Next 80B-A3B specifically)

**What it does**: of 80B total parameters, only 3B activate per token (32 of 512 experts × ~150M params each).
**Why it matters**: working-set RAM = active_params × bytes_per_param. At Q4 (~0.5 bytes/param), A3B's per-token working set is just ~1.5 GB. Even on 16 GB RAM with the OS using ~6 GB for itself + llama-server, a 1.5 GB working set comfortably fits in the page cache. **An A22B model on the same hardware would thrash and run at 1 tok/s.** Picking the right active-param count for your hardware is the difference between "runs" and "runs well."

### 6. imatrix-calibrated quantization (IQ2_XXS, mradermacher i1)

**What it does**: instead of uniform quantization, allocate more bits to weights that matter more, calibrated against an importance matrix derived from real text.
**Why it matters**: lets us run an 80B model at ~2.5 bits/param (~21 GB on disk) without catastrophic quality collapse. Plain Q2_K loses noticeably more quality at the same size. The community-standard imatrix quants (mradermacher's `i1-` prefix) are the SOTA at this size tier.

### 7. KV-cache quantization (`--cache-type-k q8_0 --cache-type-v q8_0`)

**What it does**: stores K/V cache at 8-bit precision instead of FP16.
**Why it matters**: halves KV-cache VRAM usage with imperceptible quality impact. Lets us fit 8K context on 8 GB VRAM that otherwise would max out at 4K.

### 8. Tuned batch sizing (`-b 2048 -ub 2048` on RDNA 1, more elsewhere)

**What it does**: controls how many tokens prefill processes per step. Bigger batches = faster prefill but bigger compute buffers.
**Why it matters**: prefill speed dominates time-to-first-token, especially with agentic tools that send 4–9k token system prompts every turn. RDNA 1 caps Vulkan host-pinned allocations around 2 GB, so `-ub 4096` OOMs but `-ub 2048` works and roughly doubles prefill speed. Bigger GPUs auto-tune higher.

### 9. `--flash-attn on`

**What it does**: enables Flash Attention's fused attention kernels.
**Why it matters**: meaningful end-to-end speedup on Vulkan in current `llama.cpp` builds with negligible quality impact.

### 10. `--mlock` when RAM has headroom

**What it does**: pins model pages so the OS can't evict them.
**Why it matters**: only enabled when total RAM > model size + 8 GiB headroom. On constrained RAM (where the model exceeds RAM), pinning would fail; on headroom-rich RAM, pinning eliminates the cold-cache cliff entirely.

### 11. Auto-tuning based on detected specs

**What it does**: the script queries VRAM (via `llama-server --list-devices`), RAM (`Win32_ComputerSystem` / `sysctl` / `free`), CPU, disk, and picks every flag from a tuning matrix based on those values.
**Why it matters**: no two machines are alike. A user with 32 GB RAM gets `--mlock` for free. A user with 24 GB VRAM gets `-c 32768 --cache-type-k f16 -ub 4096`. A user on Apple Silicon gets unified-memory treatment. The same source script delivers good results on a 16 GB laptop or a 64 GB workstation.

### 12. MCPO bridge for tool use

**What it does**: wraps stdio-based MCP servers (web fetch, search, Wikipedia, arXiv, etc.) as REST endpoints Open WebUI can register as Tools.
**Why it matters**: gives the model **autonomous web access** without paying for an API. Six tools wired up by default: fetch (any URL), DuckDuckGo (web search), Wikipedia, arXiv (papers), time/date, persistent memory. All free, all local, no API keys.

### 13. Runtime-regenerated MCPO config

**What it does**: the MCPO config is rewritten by the launch script every time, with absolute paths derived from `$env:USERPROFILE` / `$HOME`.
**Why it matters**: makes the repo fully portable. No machine-specific paths get committed. New users clone and run — paths self-resolve to whatever their system uses.

## What's in the catalog

Eleven abliterated models spanning four hardware tiers. The picker scores each against your detected RAM and shows which will fit comfortably (`[ok]`), which will stream from disk slowly (`[~]`), and which won't run usefully (`[!]`).

| Tier | Min RAM | Models |
|---|---|---|
| **Tiny** | 8 GiB | Qwen3-4B-Instruct abliterated |
| **Small** | 10–16 GiB | Qwen3.5-9B abliterated · Qwen3-Coder-30B-A3B abliterated · Qwen3.6-35B-A3B abliterated |
| **Medium (NVMe streaming)** | 16+ GiB | Qwen3-Coder-Next 80B-A3B (IQ2) · Qwen3-Next 80B-A3B Instruct (IQ2) · Qwen3-Next 80B-A3B Thinking (IQ2) |
| **Large** | 24–56 GiB | Qwen3-Coder-Next 80B-A3B (IQ3 / Q4_K_M) |
| **Frontier** | 64–80 GiB | GLM-4.5-Air abliterated (106B-A12B) · Qwen3.5-122B-A10B abliterated (sharded) |

Pick by use case — coder variants for agentic tool-use, instruct for general chat, thinking for reasoning, GLM-Air for research. The picker shows you the names and tags so you don't need to memorize this table.

## Reference run — proving the loop on a constrained machine

To show the auto-detect → recommend → run → measure loop produces *real numbers* on real hardware, here's what happened end-to-end on a deliberately constrained machine. **These are NOT the headline goal — this is one data point demonstrating the approach works.**

| Component | Spec |
|---|---|
| CPU | AMD Ryzen 9 3900X (12 cores / 24 threads) |
| GPU | AMD Radeon RX 5700 XT (8 GB VRAM, **RDNA 1 / gfx1010** — no ROCm on Windows) |
| RAM | 16 GB DDR4-3200 |
| Storage | NVMe Gen4 |
| OS | Windows 11 |

Run flow:
1. Script detected the specs
2. Picker showed the catalog: 8 GiB-tier and 10-16 GiB-tier models marked `[ok]`, the 80B-A3B-Coder IQ2 marked `[~]` (tight), 32+ GiB models marked `[!]`
3. Operator chose the 80B-A3B-Coder IQ2 (deliberately picking the tightest viable option to test NVMe streaming)
4. Script downloaded ~20 GB from HuggingFace, regenerated MCPO config, launched all three services
5. `-Benchmark` measured:

| Metric | Measured |
|---|---|
| Warm-cache throughput | ~13 tok/s |
| Cold-cache throughput | ~5–6 tok/s |
| First-token latency (warm) | ~3 sec |
| VRAM used during inference | ~6.5–7.4 GB / 8 |
| Context window | 8K active (262K native, capped by VRAM) |

**Your numbers will differ.** A 32 GiB-RAM machine on the same model would land closer to ~18–22 tok/s with `--mlock` enabled. A 64 GiB box with a beefier GPU running GLM-4.5-Air would measure ~6 tok/s on a much smarter 106B model. The point isn't the specific tok/s — it's that **the script shows you what your machine actually does, on whichever model you picked**.

## Quick start

The first run installs everything you need (llama.cpp prebuilt, Python venv with Open WebUI + 6 MCP servers). Pre-flight requirements:

- **Python 3.10+** on PATH (Windows: `winget install Python.Python.3.11` · macOS: built-in or `brew install python` · Linux: `apt install python3 python3-venv`)
- **Node.js** *(optional, for the memory MCP only)* — Windows: `winget install OpenJS.NodeJS` · macOS: `brew install node` · Linux: `apt install nodejs npm`
- **~25 GB free disk** for your chosen model + the bootstrap (Open WebUI + MCP server deps are ~1.5 GB)

Then:

**Windows** (Command Prompt or double-click in Explorer):
```cmd
.\start.cmd
```

The `.cmd` wrapper invokes PowerShell with `-ExecutionPolicy Bypass` so you don't need to change your system policy. If you prefer running PowerShell directly:
```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

**Linux / macOS** (bash):
```bash
chmod +x ./start.sh   # one-time
./start.sh
```

**On first run**, the script will:
1. Detect missing pieces and install them:
   - `llama.cpp` — downloads the appropriate prebuilt from [ggml-org/llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases) (Windows Vulkan x64 / Linux CUDA-or-Vulkan / macOS arm64 or x64)
   - **Python venv** — creates `~/tools/open-webui-venv/` and pip-installs Open WebUI, MCPO, and the 6 MCP servers (~1–2 GB, ~5–10 min)
2. Detect your hardware (VRAM, RAM, CPU, disk)
3. Show the model picker scored against your detected RAM
4. Download whichever model you choose from HuggingFace
5. Auto-tune the `llama.cpp` flags and launch the stack

**On subsequent runs** (when models are already on disk), the script shows a **manage menu** instead of silently picking one:

```
Models already on disk:
  [1] Qwen3-Coder-Next 80B-A3B abliterated  IQ2_XXS  (19.6 GiB)
        Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf  modified 2026-05-06 07:45
  [2] Qwen3.5-122B-A10B abliterated  Q4_K (sharded)  (74.0 GiB)
        Q4_K-GGUF/Q4_K-GGUF-00001-of-00008.gguf       modified 2026-05-06 19:22

  [1-2]    run with that model
  d <num>  delete that model (frees disk)
  n        download a different one from catalog
  a        delete ALL and pick fresh from catalog
  q        abort
```

The bootstrap steps (llama.cpp / venv install) still skip when already present.

**The script never picks a model for you.** First run shows the catalog scored against your detected RAM and asks which one you want. Whichever you pick gets downloaded and launched. Subsequent runs detect the on-disk model and reuse it (use `-Pick` / `--pick` any time to switch).

Once running:
- **Chat**: http://127.0.0.1:3000
- **API**: http://127.0.0.1:8088/v1

Add `-Benchmark` (or `--benchmark`) on launch and the script will fire a cold + warm prompt after services come up and **report actual tok/s on your hardware**.

## Scripts in this repo

| File | Platform | What it does |
|---|---|---|
| **`start.cmd`** | Windows | Tiny wrapper that invokes `start.ps1` with `-ExecutionPolicy Bypass` so users don't have to change their PowerShell policy. Passes flags through unchanged. |
| **`start.ps1`** | Windows | Detects hardware via WMI + llama-server probe; resolves model from catalog or `-Model`; auto-tunes llama.cpp flags; regenerates MCPO config with current paths; launches llama-server + Open WebUI + MCPO each in its own window. |
| **`start.sh`** | Linux + macOS | Same logic in bash. Detects via `nvidia-smi` / `rocm-smi` / `system_profiler`. On Apple Silicon, treats unified memory as VRAM and enables `--mlock`. Runs services as `nohup` background jobs with logs in `~/tools/logs/`. |
| **`README.md`** | — | This file. |
| **`.gitignore`** | — | Excludes downloaded `.gguf` files (the scripts pull them on demand, no need to commit ~20 GB of weights). |

Both scripts share the same flag conventions:

| Windows | Linux/macOS | Effect |
|---|---|---|
| `-Model "<id\|file>"` | `--model "<id\|file>"` | Use a specific catalog entry (by id) or GGUF filename |
| `-Pick` | `--pick` | Force the interactive catalog picker |
| `-Benchmark` | `--benchmark` | After services come up, fire a cold + warm prompt and report tok/s |
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

If you pick one of the **Coder** entries from the catalog (e.g. `qwen30-coder-q4` or `coder-80b-iq2`), you get a model specifically post-trained for **agentic tool-use trajectories** — it knows how to read a file, propose an edit, run a test, and iterate. That fine-tune is the difference between "this agent crashes after 3 steps" and "this agent finishes the task." The non-coder variants (Instruct, Thinking, GLM-Air) work too but are tuned for different things — pick by use case.

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
.\start.ps1 -Model "thinking-80b-iq2"         # by catalog id
.\start.ps1 -Model "Huihui-...Q4_K_M.gguf"    # by exact filename
```

Auto-downloads from HuggingFace when you pick something not on disk.

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

Coder-tuned models in the catalog (any of the `coder-*` entries) need explicit prompting to use these tools — say "search the web for X" not just "what's X today". Their fine-tune optimizes for code-editing tool loops, not research tool loops. The **Thinking** and **GLM-Air** entries are much better at autonomously reaching for web search.

## Picking the right catalog entry for your use case

| You want to do… | Pick a catalog entry tagged… |
|---|---|
| Edit code, run tests, agentic loops | `coder-*` (Coder-tuned for tool-use trajectories) |
| Single-shot code generation | `coder-*` or any general model |
| General chat, Q&A, daily driver | `instruct-*` or `qwen35-9b` |
| Research, multi-source synthesis | `thinking-*` or `glm-air-106b` |
| Hard reasoning / math / CTF puzzles | `thinking-*` |
| Cybersecurity scripting (uncensored) | any `coder-*` (abliterated removes refusals) |
| Long-context document review | `coder-80b-*` or `instruct-80b-iq2` (262K native, hybrid SSM = cheap KV cache) |
| Lowest-resource fast chat | `qwen3-4b` or `qwen35-9b` |

## Hardware upgrade path

The stack auto-tunes as your machine evolves:

| Upgrade | Approx cost | What it unlocks |
|---|---|---|
| **DOCP / XMP enabled in BIOS** | $0 | RAM at rated 3200 MT/s instead of 2133 → ~25–35% throughput uplift |
| **64 GB RAM** | ~$100 used | `--mlock` becomes feasible; Q4 quants run cleanly; gpt-oss-120b and Qwen3.5-122B viable; cold-prompt cliff disappears |
| **GPU swap to Intel Arc Pro B70 32 GB** | ~$800 net | 4× VRAM, native XMX matrix engines, 2.7× memory bandwidth; an 80B-A3B model fits entirely on GPU at ~50–70 tok/s |

Run `start.ps1 -Force` (or `--force`) after any hardware change — auto-tune detects and adjusts.

## Platform-specific notes

### Linux

The script auto-installs to `~/tools/`:
- llama.cpp prebuilt — picks the **CUDA build** if `nvidia-smi` is on PATH, otherwise **Vulkan** (works on AMD, Intel Arc, or as CPU fallback)
- Python venv with Open WebUI + 6 MCP servers
- MCPO config

Existing installs are detected first: if `llama-server` is at `~/tools/llama.cpp/`, `~/llama.cpp/build/bin/`, `/opt/homebrew/bin/`, `/usr/local/bin/`, or anywhere on PATH, the script uses it.

Distro packages you may need beforehand:
```bash
# Debian/Ubuntu
sudo apt install python3 python3-venv unzip curl
```

### macOS

The script auto-installs to `~/tools/`:
- llama.cpp prebuilt — `macos-arm64` for Apple Silicon (Metal-accelerated), `macos-x64` for Intel Macs
- Python venv with Open WebUI + 6 MCP servers

If you've already done `brew install llama.cpp`, the script detects it at `/opt/homebrew/bin/llama-server` and skips the install.

On Apple Silicon, the script treats unified memory as VRAM and enables `--mlock` automatically. The same Qwen3-Coder-Next IQ2_XXS runs at ~25–40 tok/s on 16 GB Macs, ~50+ tok/s on 32 GB Macs.

### Skipping the auto-install

Set environment variables before running to point at existing installs (avoids any download/install):
```bash
export LLAMA_BIN=/path/to/your/llama-server
export VENV_PYTHON=/path/to/your/python
./start.sh
```

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

## Inspiration & credit

The expert-offload technique at the heart of this stack comes from [**Running a 35B AI Model on 6GB VRAM, FAST (llama.cpp Guide)**](https://youtu.be/8F_5pdcD3HY) — a YouTube walkthrough of `llama.cpp`'s MoE expert-offload trick. Massive credit to the video author; this repo is a reusable, hardware-aware, cross-platform expansion of the same idea.

Other open-source projects this stack stands on:
- [`llama.cpp`](https://github.com/ggml-org/llama.cpp) — the inference engine
- [Open WebUI](https://github.com/open-webui/open-webui) — chat interface
- [MCPO](https://github.com/open-webui/mcpo) — MCP-to-OpenAPI bridge
- [HuggingFace Hub](https://huggingface.co/) — model hosting (especially [mradermacher](https://huggingface.co/mradermacher), [huihui-ai](https://huggingface.co/huihui-ai), [Unsloth](https://huggingface.co/unsloth) for GGUF + abliteration work)
- [Anthropic's MCP](https://modelcontextprotocol.io/) — the tool protocol

## License

MIT — do whatever you want with this. If you ship something neat built on top, a link back is appreciated but not required.

## Topics

If you fork or reuse this, tag your repo with these on GitHub (Settings → About → Topics) so others can find it:

```
llama-cpp  local-llm  abliterated-llm  uncensored-llm  mixture-of-experts  moe
qwen3  qwen3-next  qwen3-coder  gguf  vulkan  amd-gpu  intel-arc  apple-silicon
low-vram  8gb-vram  expert-offload  mmap-streaming  nvme-llm  long-context
mcp  model-context-protocol  open-webui  mcpo  ai-agent  coding-agent
self-hosted-ai  privacy-first  offline-llm  windows  linux  macos
```

### Search keywords

For anyone landing here from search: this project covers running **Qwen3-Next 80B-A3B**, **Qwen3-Coder-Next**, **Qwen3.5-122B-A10B**, **GLM-4.5-Air**, and other large abliterated MoE models locally on **constrained hardware** (8 GB VRAM, 16 GB RAM, AMD RDNA 1, Intel Arc, Apple Silicon). It uses `llama.cpp` Vulkan, expert offload, NVMe streaming, KV cache quantization, and MCP-based tools to fit a private, uncensored, agentic LLM stack on hardware that "shouldn't" be able to run it.

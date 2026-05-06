# Running larger language models on small hardware

A cross-platform script that **figures out what your machine can actually run, presents a curated catalog of abliterated MoE models filtered against your specs, launches the best fit with auto-tuned flags, and measures real-world throughput**. Built on `llama.cpp` + Open WebUI + MCP tools.

Works on **Windows**, **Linux**, and **macOS** — same logic on each.

## The core idea

Most "run an LLM locally" guides hardcode flags for a specific machine and a specific model. They break the moment your hardware isn't theirs. This stack inverts the flow:

```
1. Detect       — query VRAM, RAM, CPU, disk
2. Recommend    — score a curated catalog of abliterated MoE GGUFs
                  against the detected RAM (`[ok]` / `[~]` / `[!]`)
3. Choose       — interactive picker, or pass -Model
4. Auto-tune    — context, KV cache type, batch sizes, expert offload,
                  --mlock — all derived from detected specs
5. Launch       — llama-server + Open WebUI + MCPO (6 free tools)
6. Measure      — `-Benchmark` flag prints actual cold + warm tok/s
                  on YOUR machine
```

The script encodes years' worth of community knowledge about which `llama.cpp` flags work where, what tradeoffs apply at each VRAM/RAM tier, and which model architectures stream efficiently from NVMe. You don't have to know any of that — run it and the right thing happens.

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

**Windows** (PowerShell, from this directory):
```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

**Linux / macOS** (bash):
```bash
chmod +x ./start.sh   # one-time
./start.sh
```

**The script never picks a model for you.** First run shows the catalog scored against your detected RAM and asks which one you want. Whichever you pick gets downloaded and launched. Subsequent runs detect the on-disk model and reuse it (use `-Pick` / `--pick` any time to switch).

Once running:
- **Chat**: http://127.0.0.1:3000
- **API**: http://127.0.0.1:8088/v1

Add `-Benchmark` (or `--benchmark`) on launch and the script will fire a cold + warm prompt after services come up and **report actual tok/s on your hardware**.

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

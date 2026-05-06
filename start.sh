#!/usr/bin/env bash
# start.sh — one-stop launcher for the local Qwen3 stack on Linux + macOS.
# Same auto-tune behavior as start.ps1 on Windows.
#
# Run:    ./start.sh
# Flags:
#   --model <filename>   override default model
#   --download-only      only download, don't launch
#   --only-llama         launch only llama-server, skip UI/MCPO
#   --force              stop running instances and relaunch

set -euo pipefail

# ---------- Defaults ----------
MODEL="${MODEL:-}"
MODEL_REPO="${MODEL_REPO:-}"
MODEL_PATTERN=""
DOWNLOAD_ONLY=0
ONLY_LLAMA=0
FORCE=0
PICK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)         MODEL="$2"; shift 2 ;;
        --model-repo)    MODEL_REPO="$2"; shift 2 ;;
        --pick)          PICK=1; shift ;;
        --download-only) DOWNLOAD_ONLY=1; shift ;;
        --only-llama)    ONLY_LLAMA=1; shift ;;
        --force)         FORCE=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -15 | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# ---------- Curated abliterated model catalog ----------
# Each line: id|name|repo|file|pattern|sizeGiB|minRamGiB|tag|isDefault
CATALOG=(
"coder-iq2|Qwen3-Coder-Next 80B-A3B abliterated  IQ2_XXS (~21 GB)|mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF|Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf|Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf|21|16|code, agents (default)|1"
"coder-iq3|Qwen3-Coder-Next 80B-A3B abliterated  IQ3_XXS (~31 GB)|mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF|Huihui-Qwen3-Coder-Next-abliterated.i1-IQ3_XXS.gguf|Huihui-Qwen3-Coder-Next-abliterated.i1-IQ3_XXS.gguf|31|24|code, better quality|0"
"coder-q4|Qwen3-Coder-Next 80B-A3B abliterated  Q4_K_M (~48 GB)|mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF|Huihui-Qwen3-Coder-Next-abliterated.i1-Q4_K_M.gguf|Huihui-Qwen3-Coder-Next-abliterated.i1-Q4_K_M.gguf|48|56|code, high quality|0"
"instruct-iq2|Qwen3-Next 80B-A3B Instruct Decensored IQ2_XXS (~21 GB)|mradermacher/Qwen3-Next-80B-A3B-Instruct-Decensored-i1-GGUF|Qwen3-Next-80B-A3B-Instruct-Decensored.i1-IQ2_XXS.gguf|Qwen3-Next-80B-A3B-Instruct-Decensored.i1-IQ2_XXS.gguf|21|16|general chat, fast|0"
"thinking-iq2|Qwen3-Next 80B-A3B Thinking-Uncensored IQ2_XXS (~21 GB)|mradermacher/Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored-i1-GGUF|Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored.i1-IQ2_XXS.gguf|Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored.i1-IQ2_XXS.gguf|21|16|research, reasoning|0"
"qwen36-q4|Qwen3.6-35B-A3B  UD-Q4_K_XL (~22 GB) (NOT abliterated)|unsloth/Qwen3.6-35B-A3B-GGUF|Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf|Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf|22|16|newer training, smaller|0"
"qwen30-coder-q4|Qwen3-Coder-30B-A3B abliterated Q4_K_M (~19 GB)|mradermacher/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated-i1-GGUF|Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated.i1-Q4_K_M.gguf|Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated.i1-Q4_K_M.gguf|19|16|smaller code, faster|0"
"glm-air|Huihui GLM-4.5-Air abliterated UD-Q4_K_XL (~63 GB)|huihui-ai/Huihui-GLM-4.5-Air-abliterated-GGUF|GLM-4.5-Air-abliterated-UD-Q4_K_XL.gguf|*UD-Q4_K_XL*.gguf|63|72|best for research, slow (A12B)|0"
"qwen35-122b|Qwen3.5-122B-A10B abliterated Q4_K (sharded ~74 GB)|huihui-ai/Huihui-Qwen3.5-122B-A10B-abliterated-GGUF|Q4_K-GGUF/Q4_K-GGUF-00001-of-00008.gguf|Q4_K-GGUF/*.gguf|74|80|biggest abliterated Qwen|0"
)

# Returns: 0=ok 1=tight 2=no
score_model() {
    local minRam=$1 ram=$2
    if (( $(awk "BEGIN{print ($ram < $minRam - 4)}") )); then return 2; fi
    if (( $(awk "BEGIN{print ($ram < $minRam + 4)}") )); then return 1; fi
    return 0
}

show_catalog() {
    local ramGiBVal=$1
    echo
    echo "Available abliterated MoE models (filtered by your RAM = $ramGiBVal GiB):"
    echo "  [ok] fits in RAM cache  [~] tight, works but slow  [!] needs more RAM"
    echo
    local i=0
    for entry in "${CATALOG[@]}"; do
        i=$((i+1))
        IFS='|' read -r id name repo file pattern size minram tag isdef <<< "$entry"
        score_model "$minram" "$ramGiBVal" && marker="[ok]" || {
            local rc=$?
            if (( rc == 1 )); then marker="[~] "; else marker="[!] "; fi
        }
        printf "  [%2d] %s %s\n" "$i" "$marker" "$name"
        printf "        %s (needs %s+ GiB RAM)\n" "$tag" "$minram"
    done
    echo
}

# Sets globals: SEL_FILE, SEL_REPO, SEL_PATTERN, SEL_NAME, SEL_MIN_RAM
select_from_catalog() {
    show_catalog "$RAM_GIB"
    while true; do
        read -r -p "Pick a number 1-${#CATALOG[@]} (or 'q' to quit): " sel
        if [[ "$sel" =~ ^[Qq]$ ]]; then return 1; fi
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#CATALOG[@]} )); then
            IFS='|' read -r id name repo file pattern size minram tag isdef <<< "${CATALOG[$((sel-1))]}"
            SEL_FILE="$file"; SEL_REPO="$repo"; SEL_PATTERN="$pattern"
            SEL_NAME="$name"; SEL_MIN_RAM="$minram"
            return 0
        fi
        echo "Invalid. Pick 1-${#CATALOG[@]} or q."
    done
}

# Get default entry
default_entry() {
    for entry in "${CATALOG[@]}"; do
        IFS='|' read -r id name repo file pattern size minram tag isdef <<< "$entry"
        if [[ "$isdef" == "1" ]]; then
            echo "$entry"; return
        fi
    done
}

# ---------- Platform ----------
case "$(uname -s)" in
    Darwin)  PLATFORM="macos" ;;
    Linux)   PLATFORM="linux" ;;
    *) echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

# ---------- Paths ----------
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="${TOOLS_DIR:-$HOME/tools}"
DATA_DIR="${DATA_DIR:-$TOOLS/open-webui-data}"
MCPO_CFG="${MCPO_CFG:-$TOOLS/mcpo/config.json}"
MODEL_PATH="$HERE/$MODEL"

# Find llama-server binary in common spots
LLAMA=""
for candidate in \
    "$TOOLS/llama.cpp/llama-server" \
    "$TOOLS/llama.cpp/build/bin/llama-server" \
    "$HOME/llama.cpp/build/bin/llama-server" \
    "/opt/homebrew/bin/llama-server" \
    "/usr/local/bin/llama-server" \
    "$(command -v llama-server 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then LLAMA="$candidate"; break; fi
done
[[ -z "$LLAMA" ]] && { echo "llama-server not found. Install or set TOOLS_DIR." >&2; exit 1; }

# Find Python venv (for HF downloads + Open WebUI + MCPO)
VENV_PY=""
for candidate in \
    "$TOOLS/open-webui-venv/bin/python" \
    "$HOME/open-webui-venv/bin/python" \
    "$(command -v python3 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then VENV_PY="$candidate"; break; fi
done

WEBUI="${WEBUI:-$TOOLS/open-webui-venv/bin/open-webui}"
MCPO="${MCPO:-$TOOLS/open-webui-venv/bin/mcpo}"

# ---------- 1. Detect hardware ----------
echo
echo "=== Hardware ==="

GPU_NAME="(unknown)"; VRAM_MIB=0
RAM_MIB=0; CPU_NAME="(unknown)"; CPU_CORES=0; DISK_FREE_MIB=0

if [[ "$PLATFORM" == "macos" ]]; then
    GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model:/ {print $2; exit}')
    [[ -z "$GPU_NAME" ]] && GPU_NAME="(unknown)"
    RAM_MIB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    if [[ "$(uname -m)" == "arm64" ]]; then
        # Apple Silicon: GPU uses unified memory, can address most of RAM
        VRAM_MIB=$RAM_MIB
    else
        VRAM_MIB=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/VRAM/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
        [[ -z "$VRAM_MIB" ]] && VRAM_MIB=0
    fi
    CPU_NAME=$(sysctl -n machdep.cpu.brand_string)
    CPU_CORES=$(sysctl -n hw.ncpu)
    DISK_FREE_MIB=$(df -m / | awk 'NR==2 {print $4}')
else  # linux
    # Try GPU vendor probes in order
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
        VRAM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs)
    elif command -v rocm-smi >/dev/null 2>&1; then
        GPU_NAME=$(rocm-smi --showproductname 2>/dev/null | awk -F: '/Card Series/ {print $2; exit}' | xargs)
        VRAM_MIB=$(rocm-smi --showmeminfo vram 2>/dev/null | awk '/Total/ {print int($NF/1024/1024); exit}')
    fi
    if [[ -z "${VRAM_MIB:-}" || "$VRAM_MIB" -eq 0 ]]; then
        # Fallback: ask llama-server which Vulkan/HIP/CUDA device it sees
        DEV=$("$LLAMA" --list-devices 2>&1 || true)
        if [[ "$DEV" =~ (Vulkan|CUDA|HIP|SYCL)[0-9]+:\ *([^(]+)\(([0-9]+)\ MiB ]]; then
            GPU_NAME="${BASH_REMATCH[2]}"
            VRAM_MIB="${BASH_REMATCH[3]}"
        fi
    fi
    RAM_MIB=$(free -m | awk '/^Mem:/ {print $2}')
    CPU_NAME=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    CPU_CORES=$(nproc)
    DISK_FREE_MIB=$(df -m / | awk 'NR==2 {print $4}')
fi

VRAM_GIB=$(awk "BEGIN {printf \"%.1f\", $VRAM_MIB/1024}")
RAM_GIB=$(awk "BEGIN {printf \"%.1f\", $RAM_MIB/1024}")
DISK_FREE_GIB=$(awk "BEGIN {printf \"%.1f\", $DISK_FREE_MIB/1024}")
RAM_GIB_INT=$(awk "BEGIN {printf \"%d\", $RAM_MIB/1024}")

printf "GPU      : %s (%s GiB VRAM)\n"  "$GPU_NAME" "$VRAM_GIB"
printf "CPU      : %s (%s cores)\n"     "$CPU_NAME" "$CPU_CORES"
printf "RAM      : %s GiB\n"            "$RAM_GIB"
printf "Disk /   : %s GiB free\n"       "$DISK_FREE_GIB"

# ---------- 2. Resolve model: explicit --model > local default > picker ----------
echo
echo "=== Model ==="

# Default catalog entry
IFS='|' read -r DEF_ID DEF_NAME DEF_REPO DEF_FILE DEF_PATTERN DEF_SIZE DEF_MINRAM DEF_TAG DEF_ISDEF <<< "$(default_entry)"

# Resolve selection
if [[ -n "$MODEL" ]]; then
    # User passed --model: search catalog for matching file or id
    found=0
    for entry in "${CATALOG[@]}"; do
        IFS='|' read -r id name repo file pattern size minram tag isdef <<< "$entry"
        if [[ "$file" == "$MODEL" || "$id" == "$MODEL" ]]; then
            SEL_FILE="$file"; SEL_REPO="$repo"; SEL_PATTERN="$pattern"
            SEL_NAME="$name"; SEL_MIN_RAM="$minram"
            found=1; break
        fi
    done
    if (( ! found )); then
        # Custom file not in catalog
        SEL_FILE="$MODEL"; SEL_REPO="$MODEL_REPO"; SEL_PATTERN="$MODEL"
        SEL_NAME="Custom: $MODEL"; SEL_MIN_RAM=0
    fi
elif (( PICK )) || [[ ! -f "$HERE/$DEF_FILE" ]]; then
    echo "No local model found (or --pick was set). Showing catalog..."
    if ! select_from_catalog; then echo "Aborted."; exit 0; fi
else
    SEL_FILE="$DEF_FILE"; SEL_REPO="$DEF_REPO"; SEL_PATTERN="$DEF_PATTERN"
    SEL_NAME="$DEF_NAME"; SEL_MIN_RAM="$DEF_MINRAM"
fi

MODEL="$SEL_FILE"
MODEL_REPO="$SEL_REPO"
MODEL_PATTERN="$SEL_PATTERN"
MODEL_PATH="$HERE/$MODEL"

echo "Selected: $SEL_NAME"

if [[ -f "$MODEL_PATH" ]]; then
    SIZE=$(awk "BEGIN {printf \"%.2f\", $(stat -f%z "$MODEL_PATH" 2>/dev/null || stat -c%s "$MODEL_PATH")/1024/1024/1024}")
    printf "OK on disk: %s GiB\n" "$SIZE"
else
    echo "Not on disk. Downloading from $MODEL_REPO ..."
    [[ -z "$MODEL_REPO" ]] && { echo "no repo for custom model; pass --model-repo"; exit 1; }
    [[ -z "$VENV_PY" ]] && { echo "no python found"; exit 1; }

    if (( SEL_MIN_RAM > 0 )) && (( RAM_GIB_INT < SEL_MIN_RAM )); then
        echo "  WARNING: this model recommends ${SEL_MIN_RAM}+ GiB RAM, you have ${RAM_GIB_INT}."
        echo "  Will run with mmap streaming but cold prompts will be very slow."
    fi

    HF_HUB_ENABLE_HF_TRANSFER=1 "$VENV_PY" -c "
from huggingface_hub import snapshot_download
p = snapshot_download(repo_id='$MODEL_REPO', allow_patterns=['$MODEL_PATTERN'], local_dir='$HERE')
print('->', p)
"
    [[ ! -f "$MODEL_PATH" ]] && { echo "download failed (file $MODEL not present after snapshot)"; exit 1; }
fi

(( DOWNLOAD_ONLY )) && { echo "Done (--download-only)"; exit 0; }

MODEL_SIZE_MIB=$(( $(stat -f%z "$MODEL_PATH" 2>/dev/null || stat -c%s "$MODEL_PATH") / 1024 / 1024 ))
MODEL_GIB=$(awk "BEGIN {printf \"%.1f\", $MODEL_SIZE_MIB/1024}")

# ---------- 3. Auto-tune flags ----------
echo
echo "=== Tuning ==="

# Skip expert offload if VRAM fits the whole model + 2 GiB headroom
if (( VRAM_MIB > MODEL_SIZE_MIB + 2048 )); then
    USE_OT_CPU=0
else
    USE_OT_CPU=1
fi

# Context + KV cache type by VRAM
if   (( VRAM_MIB >= 24*1024 )); then CTX=65536; KV="f16"
elif (( VRAM_MIB >= 12*1024 )); then CTX=32768; KV="q8_0"
elif (( VRAM_MIB >=  8*1024 )); then CTX=8192;  KV="q8_0"
else                                  CTX=4096;  KV="q8_0"
fi

# Batch sizes — RDNA1 on Vulkan can't handle ub > 2048; bigger cards can
if (( VRAM_MIB >= 12*1024 )); then UB=4096; else UB=2048; fi

# mlock — pin model only when RAM has 8 GiB headroom
if (( RAM_MIB > MODEL_SIZE_MIB + 8192 )); then USE_MLOCK=1; else USE_MLOCK=0; fi

# Apple Silicon: model is in unified memory anyway, mlock is meaningful
if [[ "$PLATFORM" == "macos" && "$(uname -m)" == "arm64" ]]; then USE_MLOCK=1; fi

printf "Context size  : %s\n"       "$CTX"
printf "KV cache type : %s\n"       "$KV"
printf "Batch sizes   : -b %s -ub %s\n" "$UB" "$UB"
printf "Expert offload: %s\n"       "$([[ $USE_OT_CPU -eq 1 ]] && echo 'yes (-ot exps=CPU)' || echo 'no (model fits in VRAM)')"
printf "--mlock       : %s\n"       "$([[ $USE_MLOCK -eq 1 ]] && echo 'yes' || echo 'no')"

# ---------- 4. Optional: stop existing ----------
if (( FORCE )); then
    echo
    echo "=== Stopping existing ==="
    pkill -f llama-server     2>/dev/null || true
    pkill -f open-webui       2>/dev/null || true
    pkill -f 'mcpo' 2>/dev/null || true
    sleep 2
fi

# ---------- 5. Launch llama-server ----------
echo
echo "=== Launching ==="

mkdir -p "$TOOLS/logs"

is_listening() { lsof -i :"$1" -sTCP:LISTEN -t 2>/dev/null | head -1; }

if [[ -n "$(is_listening 8088)" ]]; then
    echo "llama-server already on :8088 (use --force to relaunch)"
else
    LLAMA_ARGS=(
        -m "$MODEL_PATH"
        -ngl 99
        --flash-attn on
        -c "$CTX"
        --cache-type-k "$KV" --cache-type-v "$KV"
        -b "$UB" -ub "$UB"
        --jinja
        --host 127.0.0.1 --port 8088
    )
    (( USE_OT_CPU )) && LLAMA_ARGS+=(--override-tensor "exps=CPU")
    (( USE_MLOCK ))  && LLAMA_ARGS+=(--mlock)

    nohup "$LLAMA" "${LLAMA_ARGS[@]}" >"$TOOLS/logs/llama-server.log" 2>&1 &
    echo "llama-server -> http://127.0.0.1:8088  (log: $TOOLS/logs/llama-server.log)"
fi

(( ONLY_LLAMA )) && { echo; echo "Done (--only-llama)."; exit 0; }

# ---------- 6. Open WebUI ----------
if [[ -n "$(is_listening 3000)" ]]; then
    echo "Open WebUI already on :3000"
elif [[ -x "$WEBUI" ]]; then
    PYTHONIOENCODING=utf-8 PYTHONUTF8=1 \
    WEBUI_AUTH=False ENABLE_API_KEYS=True \
    OPENAI_API_BASE_URL=http://127.0.0.1:8088/v1 \
    OPENAI_API_KEY=sk-llama-cpp \
    ENABLE_OLLAMA_API=False \
    DATA_DIR="$DATA_DIR" \
    nohup "$WEBUI" serve --port 3000 --host 127.0.0.1 \
        >"$TOOLS/logs/open-webui.log" 2>&1 &
    echo "Open WebUI    -> http://127.0.0.1:3000  (log: $TOOLS/logs/open-webui.log)"
else
    echo "Open WebUI not installed at $WEBUI - skipping"
fi

# ---------- 7. MCPO ----------
# Regenerate MCPO config with current absolute paths (no stale or wrong-user paths).
if [[ -n "$(is_listening 8091)" ]]; then
    echo "MCPO already on :8091"
elif [[ -x "$MCPO" ]]; then
    MCPO_DIR="$(dirname "$MCPO_CFG")"
    mkdir -p "$MCPO_DIR" "$MCPO_DIR/arxiv-papers"
    VENV_BIN="$TOOLS/open-webui-venv/bin"
    NPX_PATH="${NPX_PATH:-$(command -v npx 2>/dev/null || echo /usr/bin/npx)}"
    LOCAL_TZ="${LOCAL_TZ:-$(date +%Z 2>/dev/null || echo UTC)}"

    cat > "$MCPO_CFG" <<EOF
{
  "mcpServers": {
    "fetch":      { "command": "$VENV_BIN/mcp-server-fetch",     "args": [] },
    "duckduckgo": { "command": "$VENV_BIN/duckduckgo-mcp-server","args": [] },
    "wikipedia":  { "command": "$VENV_BIN/wikipedia-mcp",        "args": [] },
    "arxiv":      { "command": "$VENV_BIN/arxiv-mcp-server",     "args": ["--storage-path", "$MCPO_DIR/arxiv-papers"] },
    "time":       { "command": "$VENV_BIN/mcp-server-time",      "args": ["--local-timezone", "$LOCAL_TZ"] },
    "memory":     { "command": "$NPX_PATH", "args": ["-y","@modelcontextprotocol/server-memory"], "env": { "MEMORY_FILE_PATH": "$MCPO_DIR/memory.json" } }
  }
}
EOF

    nohup "$MCPO" --config "$MCPO_CFG" --port 8091 --host 127.0.0.1 \
        >"$TOOLS/logs/mcpo.log" 2>&1 &
    echo "MCPO          -> http://127.0.0.1:8091  (log: $TOOLS/logs/mcpo.log)"
else
    echo "MCPO not installed - skipping"
fi

# ---------- 8. Done ----------
echo
echo "=== Ready ==="
echo "Chat:  http://127.0.0.1:3000"
echo "API:   http://127.0.0.1:8088/v1"
echo "Tools: http://127.0.0.1:8091"
echo
echo "Stop all: pkill -f 'llama-server|open-webui|mcpo'"

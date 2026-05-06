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
BENCHMARK=0
SORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)         MODEL="$2"; shift 2 ;;
        --model-repo)    MODEL_REPO="$2"; shift 2 ;;
        --pick)          PICK=1; shift ;;
        --sort)          SORT="$2"; shift 2 ;;
        --download-only) DOWNLOAD_ONLY=1; shift ;;
        --only-llama)    ONLY_LLAMA=1; shift ;;
        --force)         FORCE=1; shift ;;
        --benchmark)     BENCHMARK=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -16 | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# ---------- Catalog: loaded from catalog.json via scripts/_catalog_query.py ----------
HERE_PRE="$(cd "$(dirname "$0")" && pwd)"
CATALOG_JSON="$HERE_PRE/catalog.json"
QUERY_HELPER="$HERE_PRE/scripts/_catalog_query.py"
PY_BIN=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY_BIN="$c"; break; fi
done

# Returns: 0=ok 1=tight 2=no
score_model() {
    local minRam=$1 ram=$2
    if (( $(awk "BEGIN{print ($ram < $minRam - 4)}") )); then return 2; fi
    if (( $(awk "BEGIN{print ($ram < $minRam + 4)}") )); then return 1; fi
    return 0
}

# Echoes a marker [ok]/[~]/[!] for a given minRam vs current RAM.
mark_for_ram() {
    local minRam=$1 ram=$2
    if (( $(awk "BEGIN{print ($ram < $minRam - 4)}") )); then echo "[!] "; return; fi
    if (( $(awk "BEGIN{print ($ram < $minRam + 4)}") )); then echo "[~] "; return; fi
    echo "[ok]"
}

# Estimate tok/s — same logic as start.ps1's Get-TokSecEstimate.
# args: sizeGiB activeB ramGiB vramGiB
estimate_tok_sec() {
    awk -v sz="$1" -v ab="$2" -v ram="$3" -v vram="$4" 'BEGIN {
        active_gb = ab * 0.5
        avail_ram = ram - 4; if (avail_ram < 2) avail_ram = 2
        if (sz <= vram - 0.5) {
            if (active_gb <= 1) print 60; else
            if (active_gb <= 2) print 40; else
            if (active_gb <= 4) print 22; else
            if (active_gb <= 8) print 14; else print 8
            exit
        }
        if (sz <= avail_ram) {
            if (active_gb <= 1)  print 25; else
            if (active_gb <= 3)  print 15; else
            if (active_gb <= 6)  print 8;  else
            if (active_gb <= 10) print 4;  else print 2
            exit
        }
        cache = avail_ram / sz; if (cache > 0.95) cache = 0.95
        if (active_gb <= 1.5) { v = 7 + 8*cache; if (v < 2) v = 2; printf "%d\n", v; exit }
        if (active_gb <= 3)   { v = 3 + 4*cache; if (v < 1) v = 1; printf "%d\n", v; exit }
        if (active_gb <= 6)   { v = 1 + 2*cache; if (v < 1) v = 1; printf "%d\n", v; exit }
        print 1
    }'
}

# Map category to its primary benchmark sort key.
primary_bench_for_category() {
    case "$1" in
        coding)        echo "liveCodeBench" ;;
        reasoning)     echo "gpqaDiamond" ;;
        cyber-offense) echo "cyberMetric" ;;
        cyber-defense) echo "cyberMetric" ;;
        *)             echo "mmluPro" ;;
    esac
}

# Resolve --sort value into a (category, helperSortKey) pair.
# echoes "<category>|<sortKey>|<sortLabel>"
resolve_sort_for_helper() {
    local sortVal="$1" category="$2"
    case "$sortVal" in
        newest)        echo "$category|releaseDate|newest first" ;;
        popular)       echo "$category|huggingfaceLikes|HuggingFace likes (run scripts/refresh-catalog.py first)" ;;
        downloaded)    echo "$category|huggingfaceDownloads|HuggingFace downloads (run scripts/refresh-catalog.py first)" ;;
        coding)        echo "coding|liveCodeBench|LiveCodeBench (higher = better)" ;;
        general)       echo "general|mmluPro|MMLU-Pro (higher = better)" ;;
        reasoning)     echo "reasoning|gpqaDiamond|GPQA Diamond (higher = better)" ;;
        cyber-offense) echo "cyber-offense|cyberMetric|CyberMetric (higher = better)" ;;
        cyber-defense) echo "cyber-defense|cyberMetric|CyberMetric (higher = better)" ;;
        ""|*)
            local pb; pb=$(primary_bench_for_category "$category")
            echo "$category|$pb|$pb (higher = better)" ;;
    esac
}

# Show category counts pulled from catalog. Sets CAT_COUNTS map (associative).
declare -A CAT_COUNTS
load_category_counts() {
    CAT_COUNTS=()
    while IFS='|' read -r cat count; do
        [[ -n "$cat" ]] && CAT_COUNTS["$cat"]="$count"
    done < <("$PY_BIN" "$QUERY_HELPER" --catalog "$CATALOG_JSON" --counts)
}

# Show entries — input via stdin (lines from helper).
# Args: ramGiB vramGiB sortLabel
show_entries() {
    local ramGiB=$1 vramGiB=$2 sortLabel="$3"
    echo
    echo "Models (sorted by: $sortLabel, RAM=${ramGiB} GiB, VRAM=${vramGiB} GiB):"
    echo "  [ok] fits cleanly  [~] tight (NVMe streaming)  [!] needs more RAM"
    echo "  benchmarks are full-precision base; quants take a small hit"
    echo
    local i=0
    while IFS='|' read -r id name family repo file pattern sizeGiB minRam activeB cat tier rdate good bad mmlu lcb gpqa cyb hflikes hfdl; do
        [[ -z "$id" ]] && continue
        i=$((i+1))
        local marker; marker=$(mark_for_ram "$minRam" "$ramGiB")
        local tps; tps=$(estimate_tok_sec "$sizeGiB" "$activeB" "$ramGiB" "$vramGiB")
        printf "  [%2d] %s ~%3s t/s  [%-13s] %s\n" "$i" "$marker" "$tps" "$cat" "$name"
        local bench=""
        bench+="LCB:${lcb:--} MMLU:${mmlu:--} GPQA:${gpqa:--}"
        [[ -n "$cyb" ]] && bench+=" cyber:$cyb"
        [[ -n "$rdate" ]] && bench+="  rel:$rdate"
        printf "         %s\n" "$bench"
        [[ -n "$good" ]] && printf "         + %s\n" "$good"
        [[ -n "$bad"  ]] && printf "         - %s\n" "$bad"
    done
    echo
}

# Interactive picker. Sets SEL_FILE/SEL_REPO/SEL_PATTERN/SEL_NAME/SEL_MIN_RAM/SEL_ID.
# Args: ramGiB vramGiB [preselectedSort]
select_from_catalog() {
    local ramGiB="$1" vramGiB="$2" preselSort="${3:-}"

    # Step 1: pick category
    load_category_counts
    local cats=("coding" "general" "reasoning" "cyber-offense" "cyber-defense")
    echo
    echo "Use case (filters the list):"
    local i=0
    for c in "${cats[@]}"; do
        i=$((i+1))
        printf "  [%d] %-15s (%s models)\n" "$i" "$c" "${CAT_COUNTS[$c]:-0}"
    done
    i=$((i+1))
    printf "  [%d] %-15s (%s models)\n" "$i" "all" "${CAT_COUNTS[all]:-0}"
    echo "  [q] quit"
    local category=""
    while true; do
        read -r -p "Pick: " sel
        if [[ "$sel" =~ ^[Qq]$ ]]; then return 1; fi
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
            if (( sel >= 1 && sel <= ${#cats[@]} )); then category="${cats[$((sel-1))]}"; break; fi
            if (( sel == ${#cats[@]} + 1 )); then category="all"; break; fi
        fi
        echo "Invalid. Number or q."
    done

    # Step 2: pick sort (skip if preselSort given)
    local sortVal="$preselSort"
    if [[ -z "$sortVal" ]]; then
        local pb; pb=$(primary_bench_for_category "$category")
        echo
        echo "Sort by:"
        echo "  [1] performance ($pb, default)"
        echo "  [2] newest first"
        echo "  [3] most popular   (HF likes - run scripts/refresh-catalog.py first)"
        echo "  [4] most downloaded (HF downloads - run scripts/refresh-catalog.py first)"
        echo "  [5] back"
        while true; do
            read -r -p "Pick (1-5): " s
            case "$s" in
                ""|1) sortVal="$category"; break ;;
                2) sortVal="newest"; break ;;
                3) sortVal="popular"; break ;;
                4) sortVal="downloaded"; break ;;
                5|b|B) return 2 ;;  # signal: back to category
                *) echo "Invalid. 1-5." ;;
            esac
        done
    fi

    # Step 3: filter+sort+show
    local resolved; resolved=$(resolve_sort_for_helper "$sortVal" "$category")
    local helperCat="${resolved%%|*}"
    local rest="${resolved#*|}"
    local helperSort="${rest%%|*}"
    local sortLabel="${rest#*|}"

    local helperArgs=("--catalog" "$CATALOG_JSON" "--sort" "$helperSort")
    [[ "$helperCat" != "all" ]] && helperArgs+=("--category" "$helperCat")

    local entries=()
    while IFS= read -r line; do entries+=("$line"); done < <("$PY_BIN" "$QUERY_HELPER" "${helperArgs[@]}")

    if (( ${#entries[@]} == 0 )); then
        echo "No models match. Bad sort?"
        return 1
    fi

    printf '%s\n' "${entries[@]}" | show_entries "$ramGiB" "$vramGiB" "$sortLabel"

    while true; do
        read -r -p "Pick a number 1-${#entries[@]} ('b' back, 'q' quit): " sel
        if [[ "$sel" =~ ^[Qq]$ ]]; then return 1; fi
        if [[ "$sel" =~ ^[Bb]$ ]]; then
            select_from_catalog "$ramGiB" "$vramGiB" "$preselSort"
            return $?
        fi
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#entries[@]} )); then
            IFS='|' read -r id name family repo file pattern sizeGiB minRam activeB cat tier rdate good bad mmlu lcb gpqa cyb hflikes hfdl <<< "${entries[$((sel-1))]}"
            SEL_FILE="$file"; SEL_REPO="$repo"; SEL_PATTERN="$pattern"
            SEL_NAME="$name"; SEL_MIN_RAM="$minRam"; SEL_ID="$id"
            return 0
        fi
        echo "Invalid."
    done
}

# Populate LOCAL_MODELS with on-disk catalog entries.
# Each line: file|gib|name|repo|pattern|minram|id
list_local_models() {
    LOCAL_MODELS=()
    while IFS='|' read -r id name family repo file pattern sizeGiB minRam activeB cat tier rdate good bad mmlu lcb gpqa cyb hflikes hfdl; do
        [[ -z "$id" || -z "$file" ]] && continue
        local fullpath="$HERE/$file"
        # Sharded models live in a subdirectory; check if any matching files exist.
        if [[ "$file" == */* ]]; then
            local parent; parent=$(dirname "$fullpath")
            [[ -d "$parent" ]] || continue
            shopt -s nullglob
            local matches=("$parent"/*.gguf*)
            shopt -u nullglob
            (( ${#matches[@]} == 0 )) && continue
        else
            [[ -f "$fullpath" ]] || continue
        fi
        local bytes
        bytes=$(stat -f%z "$fullpath" 2>/dev/null || stat -c%s "$fullpath" 2>/dev/null || echo 0)
        local gib
        gib=$(awk "BEGIN{printf \"%.1f\", $bytes/1024/1024/1024}")
        LOCAL_MODELS+=("$file|$gib|$name|$repo|$pattern|$minRam|$id")
    done < <("$PY_BIN" "$QUERY_HELPER" --catalog "$CATALOG_JSON")
}

stop_llama_server() {
    if pgrep -f llama-server >/dev/null 2>&1; then
        echo "  stopping llama-server..."
        pkill -f llama-server 2>/dev/null || true
        sleep 2
    fi
}

# Stop Open WebUI. Used when model changes so the browser's frontend cache
# (Svelte stores) gets invalidated on websocket reconnect; otherwise the model
# dropdown shows stale entries even though the backend has fresh data.
stop_open_webui() {
    local pid
    pid=$(lsof -i :3000 -sTCP:LISTEN -t 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
        echo "  stopping Open WebUI (PID $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        # Force-kill if still alive
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

# Returns the model id currently loaded by llama-server, or empty if not running.
get_loaded_model_id() {
    curl -fsS "http://127.0.0.1:8088/v1/models" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '')" 2>/dev/null
}

# Delete a local model by file path. For sharded models (file under subdir of
# $HERE), removes the whole subdir. For single GGUFs, removes just the file.
# Stops llama-server first since on Windows/some FSes it holds the mmap.
remove_local_model() {
    stop_llama_server
    local file="$1"
    local fullpath="$HERE/$file"
    local parent
    parent=$(dirname "$fullpath")
    if [[ "$parent" != "$HERE" ]]; then
        echo "  Removing folder: $parent"
        rm -rf "$parent"
    else
        echo "  Removing file: $fullpath"
        rm -f "$fullpath"
    fi
}

# Interactive manage menu when models are already on disk.
# Sets SEL_* on success, returns 1 if user aborted.
# Args: ramGiB vramGiB [preselectedSort]
manage_local_models() {
    local ramGiB="$1" vramGiB="$2" preselSort="${3:-}"
    list_local_models
    while (( ${#LOCAL_MODELS[@]} > 0 )); do
        echo
        echo "Models already on disk:"
        local i=0
        for entry in "${LOCAL_MODELS[@]}"; do
            i=$((i+1))
            IFS='|' read -r file gib name repo pattern minram id <<< "$entry"
            printf "  [%d] %s  (%s GiB)\n" "$i" "$name" "$gib"
            printf "        %s\n" "$file"
        done
        echo
        echo "  [1-${#LOCAL_MODELS[@]}]   run with that model"
        echo "  d <num>   delete that model"
        echo "  n         download a different one (catalog)"
        echo "  a         delete ALL and pick fresh from catalog"
        echo "  q         abort"
        read -r -p "Choose: " sel

        if [[ "$sel" =~ ^[Qq]$ ]]; then return 1; fi

        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#LOCAL_MODELS[@]} )); then
            IFS='|' read -r file gib name repo pattern minram id <<< "${LOCAL_MODELS[$((sel-1))]}"
            SEL_FILE="$file"; SEL_REPO="$repo"; SEL_PATTERN="$pattern"
            SEL_NAME="$name"; SEL_MIN_RAM="$minram"; SEL_ID="$id"
            return 0
        fi

        if [[ "$sel" =~ ^[Dd][[:space:]]*([0-9]+)$ ]]; then
            local n=${BASH_REMATCH[1]}
            if (( n >= 1 && n <= ${#LOCAL_MODELS[@]} )); then
                IFS='|' read -r file gib name repo pattern minram id <<< "${LOCAL_MODELS[$((n-1))]}"
                echo "Deleting $name ($gib GiB)..."
                remove_local_model "$file"
                list_local_models
                continue
            fi
            echo "Out of range."
            continue
        fi

        if [[ "$sel" =~ ^[Nn]$ ]]; then
            select_from_catalog "$ramGiB" "$vramGiB" "$preselSort"
            return $?
        fi

        if [[ "$sel" =~ ^[Aa]$ ]]; then
            echo "Deleting all on-disk catalog models..."
            for entry in "${LOCAL_MODELS[@]}"; do
                IFS='|' read -r file gib name repo pattern minram id <<< "$entry"
                remove_local_model "$file"
            done
            select_from_catalog "$ramGiB" "$vramGiB" "$preselSort"
            return $?
        fi

        echo "Invalid. Pick 1-${#LOCAL_MODELS[@]}, 'd N', 'n', 'a', or 'q'."
    done
    # All deleted by interactive deletes
    select_from_catalog "$ramGiB" "$vramGiB" "$preselSort"
    return $?
}

# Legacy quick-find: returns 0 if any catalog model is on disk, sets SEL_*
find_local_model() {
    list_local_models
    if (( ${#LOCAL_MODELS[@]} > 0 )); then
        IFS='|' read -r file gib name repo pattern minram id <<< "${LOCAL_MODELS[0]}"
        SEL_FILE="$file"; SEL_REPO="$repo"; SEL_PATTERN="$pattern"
        SEL_NAME="$name"; SEL_MIN_RAM="$minram"; SEL_ID="$id"
        return 0
    fi
    return 1
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

# ---------- Bootstrap helpers (install missing pieces on first run) ----------

find_python() {
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1; then
            v=$("$c" --version 2>&1 | sed 's/^Python //')
            major=$(echo "$v" | cut -d. -f1)
            minor=$(echo "$v" | cut -d. -f2)
            if [[ "$major" == "3" && "$minor" -ge 10 ]]; then
                command -v "$c"
                return 0
            fi
        fi
    done
    return 1
}

install_llama_cpp() {
    local dest="$TOOLS/llama.cpp"
    mkdir -p "$dest"

    # Pick prebuilt asset for this platform
    local asset_pattern
    if [[ "$PLATFORM" == "macos" ]]; then
        if [[ "$(uname -m)" == "arm64" ]]; then
            asset_pattern='bin-macos-arm64\.zip$'
        else
            asset_pattern='bin-macos-x64\.zip$'
        fi
    else  # linux
        # Prefer CUDA build if NVIDIA detected, else Vulkan (works on AMD/Intel/CPU-fallback)
        if command -v nvidia-smi >/dev/null 2>&1; then
            asset_pattern='bin-ubuntu-cuda-cu12.*-x64\.zip$'
        else
            asset_pattern='bin-ubuntu-vulkan-x64\.zip$'
        fi
    fi

    echo "Installing llama.cpp prebuilt to $dest ..."
    local api='https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
    local url
    url=$(curl -fsSL -A 'qwen-stack-bootstrap' "$api" | grep -E '"browser_download_url".*'"$asset_pattern" | head -1 | sed -E 's/.*"(https[^"]+)".*/\1/')
    [[ -z "$url" ]] && { echo "  could not find a prebuilt matching $asset_pattern in latest llama.cpp release" >&2; return 1; }

    local zipfile="/tmp/llama-cpp-bootstrap.zip"
    echo "  Downloading: $(basename "$url")"
    curl -fL -o "$zipfile" "$url" || { echo "  download failed" >&2; return 1; }

    echo "  Extracting..."
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$zipfile" -d "$dest"
    else
        echo "  unzip not installed; install with: apt install unzip   (or brew install unzip)" >&2
        return 1
    fi
    rm -f "$zipfile"

    # llama.cpp prebuilds usually nest under build/bin/ — flatten if needed
    if [[ ! -x "$dest/llama-server" && -x "$dest/build/bin/llama-server" ]]; then
        ln -sf "$dest/build/bin/llama-server" "$dest/llama-server" 2>/dev/null || true
    fi

    chmod +x "$dest/llama-server" 2>/dev/null || true
    echo "  llama.cpp installed."
}

install_venv() {
    local venv_dir="$TOOLS/open-webui-venv"
    echo "Creating Python venv + installing packages at $venv_dir ..."
    echo "  (Pulls Open WebUI + MCP servers, ~1-2 GB. First run takes 5-10 min.)"

    local py
    py=$(find_python) || {
        echo "  Python 3.10+ not found." >&2
        echo "  Linux:  apt install python3 python3-venv  (or your distro equivalent)" >&2
        echo "  macOS:  brew install python@3.12         (or download from python.org)" >&2
        return 1
    }

    "$py" -m venv "$venv_dir" || { echo "  venv creation failed"; return 1; }
    local vpy="$venv_dir/bin/python"
    "$vpy" -m pip install --quiet --upgrade pip >/dev/null
    echo "  Installing open-webui, mcpo, MCP servers, hf-transfer..."
    "$vpy" -m pip install --quiet \
        open-webui mcpo \
        mcp-server-fetch duckduckgo-mcp-server wikipedia-mcp arxiv-mcp-server mcp-server-time \
        huggingface_hub hf_transfer \
        || { echo "  pip install failed"; return 1; }
    echo "  venv ready."
}

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

# Bootstrap llama.cpp if not found
if [[ -z "$LLAMA" ]]; then
    install_llama_cpp || exit 1
    LLAMA="$TOOLS/llama.cpp/llama-server"
    [[ ! -x "$LLAMA" ]] && LLAMA="$TOOLS/llama.cpp/build/bin/llama-server"
    [[ ! -x "$LLAMA" ]] && { echo "llama-server still not found after install" >&2; exit 1; }
fi

# Find Python venv (for HF downloads + Open WebUI + MCPO)
VENV_PY=""
for candidate in \
    "$TOOLS/open-webui-venv/bin/python" \
    "$HOME/open-webui-venv/bin/python"; do
    if [[ -x "$candidate" ]]; then VENV_PY="$candidate"; break; fi
done

# Bootstrap venv + Open WebUI + MCP servers if not found
if [[ -z "$VENV_PY" ]]; then
    install_venv || exit 1
    VENV_PY="$TOOLS/open-webui-venv/bin/python"
fi

WEBUI="${WEBUI:-$TOOLS/open-webui-venv/bin/open-webui}"
MCPO="${MCPO:-$TOOLS/open-webui-venv/bin/mcpo}"

echo
echo "=== Bootstrap ==="
echo "llama.cpp     : $LLAMA"
echo "Python venv   : $VENV_PY"
if command -v npx >/dev/null 2>&1; then
    echo "Node.js       : found (memory MCP available)"
else
    echo "Node.js       : not found - memory MCP will be skipped"
    echo "                Linux:  apt install nodejs npm   (or use NodeSource)"
    echo "                macOS:  brew install node"
fi

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
        DEVICE_RE='(Vulkan|CUDA|HIP|SYCL)[0-9]+: *([^(]+)\(([0-9]+) MiB'
        if [[ "$DEV" =~ $DEVICE_RE ]]; then
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

# ---------- 2. Resolve model: --model > local-on-disk > picker (no defaults) ----------
echo
echo "=== Model ==="

if [[ -n "$MODEL" ]]; then
    # 2a. --model passed explicitly: look up by id/file in catalog.json, fall back to custom
    found=0
    while IFS='|' read -r id name family repo file pattern sizeGiB minRam activeB cat tier rdate good bad mmlu lcb gpqa cyb hflikes hfdl; do
        if [[ "$file" == "$MODEL" || "$id" == "$MODEL" ]]; then
            SEL_FILE="$file"; SEL_REPO="$repo"; SEL_PATTERN="$pattern"
            SEL_NAME="$name"; SEL_MIN_RAM="$minRam"; SEL_ID="$id"
            found=1; break
        fi
    done < <("$PY_BIN" "$QUERY_HELPER" --catalog "$CATALOG_JSON")
    if (( ! found )); then
        SEL_FILE="$MODEL"; SEL_REPO="$MODEL_REPO"; SEL_PATTERN="$MODEL"
        SEL_NAME="Custom: $MODEL"; SEL_MIN_RAM=0; SEL_ID="custom"
    fi
elif (( PICK )); then
    # 2b. --pick forces picker
    if ! select_from_catalog "$RAM_GIB" "$VRAM_GIB" "$SORT"; then echo "Aborted."; exit 0; fi
else
    # 2c. Models on disk → manage menu (run/delete/download new). Otherwise show catalog.
    list_local_models
    if (( ${#LOCAL_MODELS[@]} > 0 )); then
        if ! manage_local_models "$RAM_GIB" "$VRAM_GIB" "$SORT"; then echo "Aborted."; exit 0; fi
    else
        echo "No local model found."
        echo "Below is the model catalog filtered against your detected RAM."
        if ! select_from_catalog "$RAM_GIB" "$VRAM_GIB" "$SORT"; then echo "Aborted."; exit 0; fi
    fi
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
    echo "Not on disk. Probing mirrors and downloading from $MODEL_REPO ..."
    [[ -z "$MODEL_REPO" ]] && { echo "no repo for custom model; pass --model-repo"; exit 1; }
    [[ -z "$VENV_PY" ]] && { echo "no python found"; exit 1; }

    if (( SEL_MIN_RAM > 0 )) && (( RAM_GIB_INT < SEL_MIN_RAM )); then
        echo "  WARNING: this model recommends ${SEL_MIN_RAM}+ GiB RAM, you have ${RAM_GIB_INT}."
        echo "  Will run with mmap streaming but cold prompts will be very slow."
    fi

    DOWNLOAD_PY="$HERE/scripts/download.py"
    if [[ -f "$DOWNLOAD_PY" && "$SEL_ID" != "custom" ]]; then
        # Use download.py for mirror probing + hf_transfer
        "$VENV_PY" "$DOWNLOAD_PY" --id "$SEL_ID" --catalog "$CATALOG_JSON" --dest "$HERE"
    else
        # Custom model or scripts/ missing: direct snapshot_download
        HF_HUB_ENABLE_HF_TRANSFER=1 "$VENV_PY" -c "
from huggingface_hub import snapshot_download
p = snapshot_download(repo_id='$MODEL_REPO', allow_patterns=['$MODEL_PATTERN'], local_dir='$HERE')
print('->', p)
"
    fi
    [[ ! -f "$MODEL_PATH" ]] && { echo "download failed (file $MODEL not present after download)"; exit 1; }
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
    # Detect model change and restart if needed, otherwise reuse the running instance.
    LOADED_ID=$(get_loaded_model_id)
    SELECTED_LEAF=$(basename "$MODEL_PATH")
    if [[ -n "$LOADED_ID" && "$LOADED_ID" != "$SELECTED_LEAF" && "$LOADED_ID" != "$MODEL_PATH" ]]; then
        echo "Model change detected: '$LOADED_ID' -> '$SELECTED_LEAF'"
        stop_llama_server
        # Bounce Open WebUI too so the browser's Svelte cache invalidates
        # on websocket reconnect (model dropdown updates without manual refresh).
        stop_open_webui
    else
        echo "llama-server already on :8088 with the selected model (use --force to relaunch with fresh flags)"
    fi
fi
if [[ -z "$(is_listening 8088)" ]]; then
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

# ---------- 8. Optional benchmark ----------
if (( BENCHMARK )); then
    echo
    echo "=== Benchmark ==="
    echo "Waiting for llama-server to be ready..."
    for _ in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:8088/health" 2>/dev/null | grep -q '"ok"'; then
            break
        fi
        sleep 3
    done

    bench_one() {
        local prompt="$1" maxtok="$2"
        local body=$(printf '{"model":"any","messages":[{"role":"user","content":%s}],"max_tokens":%s,"temperature":0,"stream":false}' \
            "\"$prompt\"" "$maxtok")
        local t0=$(date +%s.%N)
        local resp=$(curl -sS -X POST "http://127.0.0.1:8088/v1/chat/completions" \
            -H "Content-Type: application/json" -d "$body")
        local t1=$(date +%s.%N)
        local tokens=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null)
        [[ -z "$tokens" ]] && tokens=0
        local sec=$(awk "BEGIN{printf \"%.1f\", $t1-$t0}")
        local toks=$(awk "BEGIN{printf \"%.2f\", $tokens/($t1-$t0)}" 2>/dev/null)
        echo "  -> $tokens tokens in ${sec}s = ${toks} tok/s"
    }

    echo "Cold prompt..."
    bench_one "Reply with just: ok" 5
    echo "Warm prompt..."
    bench_one "Count from 1 to 30 in a single comma-separated line." 120
    echo
    echo "Result on this machine ($RAM_GIB GiB RAM, $VRAM_GIB GiB VRAM)"
fi

# ---------- 9. Done ----------
echo
echo "================================================================"
echo "  CHAT IS HERE:  http://127.0.0.1:3000"
echo "================================================================"
echo "  Open the URL above in your browser to start chatting."
echo "  (Open WebUI may take ~30 sec to bind on first launch.)"
echo
echo "Other endpoints:"
echo "  API:    http://127.0.0.1:8088/v1   (OpenAI-compatible - for Aider, opencode, etc.)"
echo "  Tools:  http://127.0.0.1:8091      (MCP-as-OpenAPI - fetch/search/wiki/arxiv/time/memory)"
echo
echo "Useful commands:"
echo "  Switch model:    ./start.sh --pick"
echo "  Pick by use:     ./start.sh --pick --sort coding   (or general/reasoning/cyber-offense/cyber-defense/newest/popular/downloaded)"
echo "  Measure perf:    ./start.sh --benchmark"
echo "  Refresh stats:   python3 scripts/refresh-catalog.py   (HF likes/downloads, then re-run with --sort popular)"
echo "  Stop all:        pkill -f 'llama-server|open-webui|mcpo'"

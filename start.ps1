# start.ps1 — one-stop launcher for the local Qwen3 stack.
#
# What it does:
#   1. Detects hardware (VRAM via llama-server --list-devices, RAM, CPU, disk)
#   2. Verifies the model file exists; downloads from a curated catalog if not
#   3. Picks llama-server flags based on detected specs (auto-tunes context,
#      KV-cache type, batch sizes, mlock, expert offload)
#   4. Launches llama-server, Open WebUI, and MCPO (each in its own window)
#
# Run:    & ".\start.ps1"   (from this directory)
# Flags:  -Model "<filename>"   use specific GGUF (skip picker)
#         -Pick                 force the abliterated-model picker
#         -DownloadOnly         only download, don't launch
#         -OnlyLlama            launch only llama-server, skip UI/MCPO
#         -Force                stop running instances and relaunch

param(
    [string]$Model = "",
    [string]$ModelRepo = "",
    [switch]$Pick,
    [switch]$DownloadOnly,
    [switch]$OnlyLlama,
    [switch]$Force,
    [switch]$Benchmark
)

# ---------- Curated abliterated model catalog ----------
# MinRamGiB is the comfortable minimum (model + 8 GiB OS headroom).
# Pattern is the HF allow_patterns glob for snapshot_download.
# File is the path to pass to llama-server -m (relative to dir).
$Catalog = @(
    # ====== TIER 1: Tiny (8 GiB RAM, 2-3 GB on disk) ======
    [pscustomobject]@{ Id='qwen3-4b-instruct';   Name='Qwen3-4B-Instruct-2507 abliterated  Q4_K_M (~3 GB)';                Repo='mradermacher/Huihui-Qwen3-4B-Instruct-2507-abliterated-i1-GGUF';            File='Huihui-Qwen3-4B-Instruct-2507-abliterated.i1-Q4_K_M.gguf';            Pattern='Huihui-Qwen3-4B-Instruct-2507-abliterated.i1-Q4_K_M.gguf';            SizeGiB=3;   MinRamGiB=8;  Tag='tiny + fast, daily chat on weak hw' }
    [pscustomobject]@{ Id='qwen3-4b-thinking';   Name='Qwen3-4B-Thinking-2507 abliterated  Q4_K_M (~3 GB)';                Repo='mradermacher/Huihui-Qwen3-4B-Thinking-2507-abliterated-i1-GGUF';            File='Huihui-Qwen3-4B-Thinking-2507-abliterated.i1-Q4_K_M.gguf';            Pattern='Huihui-Qwen3-4B-Thinking-2507-abliterated.i1-Q4_K_M.gguf';            SizeGiB=3;   MinRamGiB=8;  Tag='tiny + reasoning chain-of-thought' }
    [pscustomobject]@{ Id='llama32-3b';          Name='Llama-3.2-3B-Instruct abliterated  Q4_K_M (~2 GB)';                 Repo='mradermacher/Llama-3.2-3B-Instruct-abliterated-i1-GGUF';                    File='Llama-3.2-3B-Instruct-abliterated.i1-Q4_K_M.gguf';                    Pattern='Llama-3.2-3B-Instruct-abliterated.i1-Q4_K_M.gguf';                    SizeGiB=2;   MinRamGiB=6;  Tag='smallest viable, instruction following' }

    # ====== TIER 2: Small dense (10-12 GiB RAM, 5-9 GB on disk) ======
    [pscustomobject]@{ Id='qwen3-8b';            Name='Qwen3-8B abliterated  Q4_K_M (~5 GB)';                              Repo='mradermacher/Huihui-Qwen3-8B-abliterated-v2-i1-GGUF';                       File='Huihui-Qwen3-8B-abliterated-v2.i1-Q4_K_M.gguf';                       Pattern='Huihui-Qwen3-8B-abliterated-v2.i1-Q4_K_M.gguf';                       SizeGiB=5;   MinRamGiB=10; Tag='dense 8B, balanced' }
    [pscustomobject]@{ Id='qwen35-9b';           Name='Qwen3.5-9B abliterated  Q4_K_M (~6 GB)';                            Repo='mradermacher/Huihui-Qwen3.5-9B-abliterated-i1-GGUF';                        File='Huihui-Qwen3.5-9B-abliterated.i1-Q4_K_M.gguf';                        Pattern='Huihui-Qwen3.5-9B-abliterated.i1-Q4_K_M.gguf';                        SizeGiB=6;   MinRamGiB=10; Tag='newer dense 9B, all-around' }
    [pscustomobject]@{ Id='llama31-8b';          Name='Llama-3.1-8B-Instruct abliterated  Q4_K_M (~5 GB)';                 Repo='mradermacher/Llama-3.1-8B-Instruct-abliterated-i1-GGUF';                    File='Llama-3.1-8B-Instruct-abliterated.i1-Q4_K_M.gguf';                    Pattern='Llama-3.1-8B-Instruct-abliterated.i1-Q4_K_M.gguf';                    SizeGiB=5;   MinRamGiB=10; Tag='Meta lineage, broad knowledge' }
    [pscustomobject]@{ Id='qwen3-14b';           Name='Qwen3-14B abliterated  Q4_K_M (~9 GB)';                             Repo='mradermacher/Huihui-Qwen3-14B-abliterated-v2-i1-GGUF';                      File='Huihui-Qwen3-14B-abliterated-v2.i1-Q4_K_M.gguf';                      Pattern='Huihui-Qwen3-14B-abliterated-v2.i1-Q4_K_M.gguf';                      SizeGiB=9;   MinRamGiB=14; Tag='dense 14B, more capable than 8B' }

    # ====== TIER 3: Medium dense (16-24 GiB RAM, 17-20 GB on disk) ======
    [pscustomobject]@{ Id='qwen25-coder-32b';    Name='Qwen2.5-Coder-32B-Instruct abliterated  Q4_K_M (~19 GB)';           Repo='mradermacher/Huihui-Qwen2.5-Coder-32B-Instruct-abliterated-i1-GGUF';        File='Huihui-Qwen2.5-Coder-32B-Instruct-abliterated.i1-Q4_K_M.gguf';        Pattern='Huihui-Qwen2.5-Coder-32B-Instruct-abliterated.i1-Q4_K_M.gguf';        SizeGiB=19;  MinRamGiB=20; Tag='dense coder, every weight active' }
    [pscustomobject]@{ Id='qwen35-27b';          Name='Qwen3.5-27B abliterated  Q4_K_M (~17 GB)';                          Repo='mradermacher/Huihui-Qwen3.5-27B-abliterated-i1-GGUF';                       File='Huihui-Qwen3.5-27B-abliterated.i1-Q4_K_M.gguf';                       Pattern='Huihui-Qwen3.5-27B-abliterated.i1-Q4_K_M.gguf';                       SizeGiB=17;  MinRamGiB=20; Tag='dense 27B, general purpose' }

    # ====== TIER 4: Small MoE A3B (12-16 GiB RAM, 19-22 GB on disk) - 3B active = fast even when streaming ======
    [pscustomobject]@{ Id='qwen30-coder-q4';     Name='Qwen3-Coder-30B-A3B abliterated  Q4_K_M (~19 GB)';                  Repo='mradermacher/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated-i1-GGUF';      File='Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated.i1-Q4_K_M.gguf';      Pattern='Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated.i1-Q4_K_M.gguf';      SizeGiB=19;  MinRamGiB=12; Tag='code MoE, 3B active = fast' }
    [pscustomobject]@{ Id='qwen3-30b-instruct';  Name='Qwen3-30B-A3B-Instruct-2507 abliterated  Q4_K_M (~19 GB)';          Repo='mradermacher/Huihui-Qwen3-30B-A3B-Instruct-2507-abliterated-i1-GGUF';       File='Huihui-Qwen3-30B-A3B-Instruct-2507-abliterated.i1-Q4_K_M.gguf';       Pattern='Huihui-Qwen3-30B-A3B-Instruct-2507-abliterated.i1-Q4_K_M.gguf';       SizeGiB=19;  MinRamGiB=12; Tag='general chat MoE, 3B active' }
    [pscustomobject]@{ Id='qwen3-30b-thinking';  Name='Qwen3-30B-A3B-Thinking-2507 abliterated  Q4_K_M (~19 GB)';          Repo='mradermacher/Huihui-Qwen3-30B-A3B-Thinking-2507-abliterated-i1-GGUF';       File='Huihui-Qwen3-30B-A3B-Thinking-2507-abliterated.i1-Q4_K_M.gguf';       Pattern='Huihui-Qwen3-30B-A3B-Thinking-2507-abliterated.i1-Q4_K_M.gguf';       SizeGiB=19;  MinRamGiB=12; Tag='reasoning MoE with chain-of-thought' }
    [pscustomobject]@{ Id='qwen36-35b';          Name='Qwen3.6-35B-A3B abliterated  Q4_K_M (~22 GB)';                      Repo='mradermacher/Huihui-Qwen3.6-35B-A3B-abliterated-GGUF';                      File='Huihui-Qwen3.6-35B-A3B-abliterated.Q4_K_M.gguf';                      Pattern='Huihui-Qwen3.6-35B-A3B-abliterated.Q4_K_M.gguf';                      SizeGiB=22;  MinRamGiB=16; Tag='newer training, MoE 3B active' }

    # ====== TIER 5: 80B-A3B (NVMe-streaming territory, 16+ GiB RAM, 20-50 GB on disk) ======
    [pscustomobject]@{ Id='coder-80b-iq2';       Name='Qwen3-Coder-Next 80B-A3B abliterated  IQ2_XXS (~21 GB)';            Repo='mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF';                  File='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf';                 Pattern='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf';                 SizeGiB=21;  MinRamGiB=16; Tag='80B brain code+agents via NVMe streaming' }
    [pscustomobject]@{ Id='instruct-80b-iq2';    Name='Qwen3-Next 80B-A3B Instruct Decensored  IQ2_XXS (~21 GB)';          Repo='mradermacher/Qwen3-Next-80B-A3B-Instruct-Decensored-i1-GGUF';               File='Qwen3-Next-80B-A3B-Instruct-Decensored.i1-IQ2_XXS.gguf';              Pattern='Qwen3-Next-80B-A3B-Instruct-Decensored.i1-IQ2_XXS.gguf';              SizeGiB=21;  MinRamGiB=16; Tag='80B general chat via NVMe streaming' }
    [pscustomobject]@{ Id='thinking-80b-iq2';    Name='Qwen3-Next 80B-A3B Thinking-Uncensored  IQ2_XXS (~21 GB)';          Repo='mradermacher/Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored-i1-GGUF';          File='Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored.i1-IQ2_XXS.gguf';         Pattern='Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored.i1-IQ2_XXS.gguf';         SizeGiB=21;  MinRamGiB=16; Tag='80B research/reasoning, autonomous tools' }
    [pscustomobject]@{ Id='coder-80b-iq3';       Name='Qwen3-Coder-Next 80B-A3B abliterated  IQ3_XXS (~31 GB)';            Repo='mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF';                  File='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ3_XXS.gguf';                 Pattern='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ3_XXS.gguf';                 SizeGiB=31;  MinRamGiB=24; Tag='80B coder higher quality (24+ GiB)' }
    [pscustomobject]@{ Id='coder-80b-q4';        Name='Qwen3-Coder-Next 80B-A3B abliterated  Q4_K_M (~48 GB)';             Repo='mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF';                  File='Huihui-Qwen3-Coder-Next-abliterated.i1-Q4_K_M.gguf';                  Pattern='Huihui-Qwen3-Coder-Next-abliterated.i1-Q4_K_M.gguf';                  SizeGiB=48;  MinRamGiB=56; Tag='80B coder full Q4 (56+ GiB)' }

    # ====== TIER 6: 100B+ frontier (64-80 GiB RAM, 60-80 GB on disk) ======
    [pscustomobject]@{ Id='glm-air-106b';        Name='Huihui GLM-4.5-Air abliterated  UD-Q4_K_XL (~63 GB)';               Repo='huihui-ai/Huihui-GLM-4.5-Air-abliterated-GGUF';                             File='GLM-4.5-Air-abliterated-UD-Q4_K_XL.gguf';                             Pattern='*UD-Q4_K_XL*.gguf';                                                   SizeGiB=63;  MinRamGiB=72; Tag='106B-A12B, agentic research benchmark leader' }
    [pscustomobject]@{ Id='qwen35-122b';         Name='Qwen3.5-122B-A10B abliterated  Q4_K (sharded ~74 GB)';              Repo='huihui-ai/Huihui-Qwen3.5-122B-A10B-abliterated-GGUF';                       File='Q4_K-GGUF\Q4_K-GGUF-00001-of-00008.gguf';                             Pattern='Q4_K-GGUF/*.gguf';                                                    SizeGiB=74;  MinRamGiB=80; Tag='biggest abliterated Qwen, 122B/A10B' }
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------- Paths ----------
# All tool paths are derived from $env:USERPROFILE so the script is portable.
# Override any of these by setting the matching env var before launching.
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir   = if ($env:TOOLS_DIR)   { $env:TOOLS_DIR }   else { Join-Path $env:USERPROFILE "tools" }
$llama      = if ($env:LLAMA_BIN)   { $env:LLAMA_BIN }   else { Join-Path $toolsDir "llama.cpp\llama-server.exe" }
$venvPy     = if ($env:VENV_PYTHON) { $env:VENV_PYTHON } else { Join-Path $toolsDir "open-webui-venv\Scripts\python.exe" }
$webui      = if ($env:WEBUI_BIN)   { $env:WEBUI_BIN }   else { Join-Path $toolsDir "open-webui-venv\Scripts\open-webui.exe" }
$mcpo       = if ($env:MCPO_BIN)    { $env:MCPO_BIN }    else { Join-Path $toolsDir "open-webui-venv\Scripts\mcpo.exe" }
$mcpoConfig = if ($env:MCPO_CONFIG) { $env:MCPO_CONFIG } else { Join-Path $toolsDir "mcpo\config.json" }
$dataDir    = if ($env:DATA_DIR)    { $env:DATA_DIR }    else { Join-Path $toolsDir "open-webui-data" }

function Section($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ---------- Bootstrap helpers (install llama.cpp + venv on first run) ----------

function Find-Python {
    foreach ($candidate in @('python3','python','py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            $v = (& $cmd.Source --version 2>&1) -replace '^Python ',''
            if ($v -match '^(\d+)\.(\d+)') {
                $major = [int]$matches[1]; $minor = [int]$matches[2]
                if ($major -ge 3 -and $minor -ge 10) { return $cmd.Source }
            }
        }
    }
    return $null
}

function Install-LlamaCpp {
    param([string]$DestDir)
    Write-Host "Installing llama.cpp Vulkan build to $DestDir ..." -ForegroundColor Cyan

    # Detect architecture so we can pick the right asset (Vulkan x64 covers AMD/NVIDIA/Intel on x64)
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    if ($arch -ne 'x64') { throw "Only x64 Windows is supported (yours: $arch)" }

    try {
        $release = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' `
            -Headers @{ 'User-Agent' = 'qwen-stack-bootstrap' } -TimeoutSec 30
    } catch {
        throw "Failed to query latest llama.cpp release: $_"
    }

    $asset = $release.assets | Where-Object { $_.name -match 'bin-win-vulkan-x64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "No Windows Vulkan x64 build found in latest llama.cpp release" }

    $zip = Join-Path $env:TEMP $asset.name
    $sizeMB = [math]::Round($asset.size / 1MB, 0)
    Write-Host ("  Downloading {0} ({1} MB)..." -f $asset.name, $sizeMB)
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing

    if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    Write-Host "  Extracting..."
    Expand-Archive -Path $zip -DestinationPath $DestDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Host "  llama.cpp installed." -ForegroundColor Green
}

function Install-Venv {
    param([string]$VenvDir)
    Write-Host "Creating Python venv + installing packages at $VenvDir ..." -ForegroundColor Cyan
    Write-Host "  (This pulls Open WebUI + MCP servers, ~1-2 GB. First run takes 5-10 minutes.)" -ForegroundColor Yellow

    $py = Find-Python
    if (-not $py) {
        throw "Python 3.10+ not found. Install from https://python.org or run: winget install Python.Python.3.11"
    }

    & $py -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed (exit $LASTEXITCODE)" }

    $venvPython = Join-Path $VenvDir 'Scripts\python.exe'
    & $venvPython -m pip install --quiet --upgrade pip 2>&1 | Out-Null
    Write-Host "  Installing open-webui, mcpo, MCP servers, hf-transfer..."
    & $venvPython -m pip install --quiet `
        open-webui mcpo `
        mcp-server-fetch duckduckgo-mcp-server wikipedia-mcp arxiv-mcp-server mcp-server-time `
        huggingface_hub hf_transfer 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)" }
    Write-Host "  venv ready." -ForegroundColor Green
}

function Test-NodeAvailable {
    return (Get-Command npx -ErrorAction SilentlyContinue) -ne $null
}

function Get-ModelScore($m, $ramGiBVal) {
    # tight = within 4 GiB of the floor (works via mmap streaming, slow cold)
    # ok    = clearly above the floor (full RAM cache fit)
    # no    = more than 4 GiB below the floor (won't run usefully)
    if ($ramGiBVal -lt $m.MinRamGiB - 4) { return @{ Tag='no';    Marker='[!] '; Color='Red'    } }
    if ($ramGiBVal -lt $m.MinRamGiB + 4) { return @{ Tag='tight'; Marker='[~] '; Color='Yellow' } }
    return                                       @{ Tag='ok';    Marker='[ok]'; Color='Green'  }
}

function Show-Catalog($ramGiBVal) {
    Write-Host ""
    Write-Host "Available abliterated MoE models (filtered by your RAM = $ramGiBVal GiB):" -ForegroundColor Cyan
    Write-Host "  [ok] fits in RAM cache, no disk paging  [~] tight, will work but slow  [!] needs more RAM" -ForegroundColor DarkGray
    Write-Host ""
    $i = 0
    foreach ($m in $Catalog) {
        $i++
        $s = Get-ModelScore $m $ramGiBVal
        $line1 = ("  [{0,2}] {1} {2}" -f $i, $s.Marker, $m.Name)
        Write-Host $line1 -ForegroundColor $s.Color
        Write-Host ("        {0} (needs {1}+ GiB RAM)" -f $m.Tag, $m.MinRamGiB) -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Select-Model($ramGiBVal) {
    Show-Catalog $ramGiBVal
    while ($true) {
        $sel = Read-Host "Pick a number 1-$($Catalog.Count) (or 'q' to quit)"
        if ($sel -eq 'q' -or $sel -eq 'Q') { return $null }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Catalog.Count) {
            return $Catalog[$n - 1]
        }
        Write-Host "Invalid. Pick a number 1-$($Catalog.Count) or q." -ForegroundColor Yellow
    }
}

# Find catalog models that are already downloaded on disk.
function Get-LocalModels($baseDir) {
    $found = @()
    foreach ($m in $Catalog) {
        $p = Join-Path $baseDir $m.File
        if (Test-Path $p) {
            $found += [pscustomobject]@{
                Entry = $m
                Path  = $p
                GiB   = [math]::Round((Get-Item $p).Length / 1GB, 1)
                Mtime = (Get-Item $p).LastWriteTime
            }
        }
    }
    return ,$found  # comma forces array even with one element
}

# Stop llama-server if it has the given file mmap'd (or always, when about to
# replace the model). On Windows, mmap'd files cannot be deleted.
function Stop-LlamaServer {
    $procs = Get-Process llama-server -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            Write-Host ("  stopping llama-server (PID {0})..." -f $p.Id) -ForegroundColor DarkGray
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    }
}

# Stop Open WebUI. Used when model changes so the browser's frontend cache
# (Svelte stores) gets invalidated on websocket reconnect; otherwise the model
# dropdown shows stale entries even though the backend has fresh data.
function Stop-OpenWebUI {
    $port = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
    if ($port) {
        Write-Host ("  stopping Open WebUI (PID {0})..." -f $port.OwningProcess) -ForegroundColor DarkGray
        Stop-Process -Id $port.OwningProcess -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# Returns the model id currently loaded by llama-server, or $null if not running.
function Get-LoadedModelId {
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:8088/v1/models" -TimeoutSec 3 -ErrorAction Stop
        if ($r.data -and $r.data.Count -gt 0) { return $r.data[0].id }
    } catch { }
    return $null
}

# Remove an on-disk model. For sharded models (file inside subdir), nukes the
# whole subdir. For single GGUFs in $here, removes just the file.
# Stops llama-server first since it holds an mmap on the file.
function Remove-LocalModel($localEntry, $baseDir) {
    Stop-LlamaServer
    $p = $localEntry.Path
    $parent = Split-Path -Parent $p
    if ($parent -ne $baseDir) {
        Write-Host ("  Removing folder: {0}" -f $parent)
        Remove-Item $parent -Recurse -Force
    } else {
        Write-Host ("  Removing file: {0}" -f $p)
        Remove-Item $p -Force
    }
}

# Interactive prompt when models exist on disk: run, delete, or get a new one.
# Returns: a catalog entry to use, or $null if user aborted.
function Manage-LocalModels($localModels, $baseDir, $ramGiBVal) {
    while ($localModels.Count -gt 0) {
        Write-Host ""
        Write-Host "Models already on disk:" -ForegroundColor Cyan
        $i = 0
        foreach ($lm in $localModels) {
            $i++
            Write-Host ("  [{0}] {1}  ({2} GiB)" -f $i, $lm.Entry.Name, $lm.GiB) -ForegroundColor Green
            Write-Host ("        {0}  modified {1}" -f $lm.Entry.File, $lm.Mtime.ToString('yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  [1-$($localModels.Count)]   run with that model"
        Write-Host "  d <num>   delete that model"
        Write-Host "  n         download a different one (catalog)"
        Write-Host "  a         delete ALL and pick fresh from catalog"
        Write-Host "  q         abort"

        $sel = Read-Host "Choose"
        if ($sel -match '^([Qq])$') { return $null }

        # Pick a number to run with
        if ($sel -match '^([0-9]+)$') {
            $n = [int]$matches[1]
            if ($n -ge 1 -and $n -le $localModels.Count) { return $localModels[$n-1].Entry }
            Write-Host "Out of range." -ForegroundColor Yellow
            continue
        }

        # Delete a specific one
        if ($sel -match '^[Dd]\s*([0-9]+)$') {
            $n = [int]$matches[1]
            if ($n -ge 1 -and $n -le $localModels.Count) {
                $target = $localModels[$n-1]
                Write-Host ("Deleting {0} ({1} GiB)..." -f $target.Entry.Name, $target.GiB) -ForegroundColor Yellow
                Remove-LocalModel $target $baseDir
                $localModels = Get-LocalModels $baseDir
                continue
            }
            Write-Host "Out of range." -ForegroundColor Yellow
            continue
        }

        if ($sel -eq 'n' -or $sel -eq 'N') {
            return Select-Model $ramGiBVal
        }

        if ($sel -eq 'a' -or $sel -eq 'A') {
            Write-Host "Deleting all on-disk catalog models..." -ForegroundColor Yellow
            foreach ($lm in $localModels) { Remove-LocalModel $lm $baseDir }
            return Select-Model $ramGiBVal
        }

        Write-Host "Invalid. Pick 1-$($localModels.Count), 'd N', 'n', 'a', or 'q'." -ForegroundColor Yellow
    }
    # All models deleted by the loop above
    return Select-Model $ramGiBVal
}

# ---------- 0. Bootstrap (install missing dependencies) ----------
Section "Bootstrap"

if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

if (Test-Path $llama) {
    Write-Host "llama.cpp     : found ($llama)"
} else {
    Install-LlamaCpp (Split-Path -Parent $llama)
}

if (Test-Path $venvPy) {
    Write-Host "Python venv   : found ($venvPy)"
} else {
    Install-Venv (Split-Path -Parent (Split-Path -Parent $venvPy))
}

if (Test-NodeAvailable) {
    Write-Host "Node.js       : found (memory MCP available)"
} else {
    Write-Host "Node.js       : not found - memory MCP will be skipped" -ForegroundColor Yellow
    Write-Host "                Install via: winget install OpenJS.NodeJS  (then re-run)" -ForegroundColor DarkGray
}

# ---------- 1. Detect hardware ----------
Section "Hardware"

# VRAM — ask llama-server. Pipe stdout+stderr through a temp file because
# PS 5.1's 2>&1 wraps stderr lines in ErrorRecord noise that breaks regex.
$vramMiB = 0
$gpuName = "(unknown)"
$tmp = [IO.Path]::GetTempFileName()
try {
    Start-Process -FilePath $llama -ArgumentList "--list-devices" -NoNewWindow -Wait `
        -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err"
    $devOut = (Get-Content $tmp -Raw -ErrorAction SilentlyContinue) + (Get-Content "$tmp.err" -Raw -ErrorAction SilentlyContinue)
    # Match e.g. "Vulkan0: AMD Radeon RX 5700 XT (8176 MiB, 7382 MiB free)"
    if ($devOut -match "(?:Vulkan|CUDA|HIP|SYCL)\d+:\s*(.+?)\s*\((\d+)\s*MiB") {
        $gpuName = $matches[1].Trim()
        $vramMiB = [int]$matches[2]
    }
} finally {
    Remove-Item $tmp,"$tmp.err" -Force -ErrorAction SilentlyContinue
}

# Fallback to WMI if llama-server probe failed (Windows reports cap of 4 GB so
# adjust known-low-reported cards manually)
if ($vramMiB -eq 0) {
    $g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'AMD|NVIDIA|Intel Arc|Radeon|GeForce' } | Select-Object -First 1
    if ($g) {
        $gpuName = $g.Name
        $vramMiB = [int]($g.AdapterRAM / 1MB)
        # Windows caps AdapterRAM at ~4 GiB on >4 GiB cards. Bump known cards.
        if ($vramMiB -le 4096 -and $g.Name -match "RX 5700 XT|RX 6800|RX 6900|RX 7700|RX 7800|RX 7900|A770") {
            $vramMiB = 8192
        }
    }
}
$vramGiB = [math]::Round($vramMiB / 1024, 1)

# System RAM
$ramGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$ramSpeed = (Get-CimInstance Win32_PhysicalMemory | Select-Object -First 1).ConfiguredClockSpeed

# CPU cores
$cpu = Get-CimInstance Win32_Processor
$cpuCores = ($cpu | Measure-Object NumberOfCores -Sum).Sum
$cpuName = $cpu[0].Name.Trim()

# Disk free
$freeGiB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)

Write-Host ("GPU      : {0} ({1} GiB VRAM)" -f $gpuName, $vramGiB)
Write-Host ("CPU      : {0} ({1} cores)" -f $cpuName, $cpuCores)
Write-Host ("RAM      : {0} GiB at {1} MT/s" -f $ramGiB, $ramSpeed)
Write-Host ("Disk C:  : {0} GiB free" -f $freeGiB)

if ($ramSpeed -lt 2400) {
    Write-Host "  TIP: enable DOCP in BIOS to run RAM at its rated speed" -ForegroundColor Yellow
}

# ---------- 2. Resolve model: explicit -Model > local-on-disk > picker ----------
Section "Model"

$selected = $null

# 2a. -Model passed explicitly: catalog match by id or filename, or custom path
if ($Model) {
    $selected = $Catalog | Where-Object { $_.File -eq $Model -or $_.Id -eq $Model } | Select-Object -First 1
    if (-not $selected) {
        $selected = [pscustomobject]@{
            Id='custom'; Name="Custom: $Model"
            Repo=$(if ($ModelRepo) { $ModelRepo } else { '' })
            File=$Model; Pattern=$Model
            SizeGiB=0; MinRamGiB=0; Tag='user-specified'
        }
    }
}

# 2b. -Pick forces the picker
if (-not $selected -and $Pick) {
    $selected = Select-Model $ramGiB
    if (-not $selected) { Write-Host "Aborted."; return }
}

# 2c. No -Model and no -Pick: scan disk for catalog models
if (-not $selected) {
    $localModels = Get-LocalModels $here
    if ($localModels.Count -gt 0) {
        # Models exist on disk — let user manage them (run / delete / download new)
        $selected = Manage-LocalModels $localModels $here $ramGiB
        if (-not $selected) { Write-Host "Aborted."; return }
    }
}

# 2d. Nothing on disk → catalog picker (never silently auto-pick anything)
if (-not $selected) {
    Write-Host "No local model found." -ForegroundColor Yellow
    Write-Host "Below is a catalog of abliterated MoE models filtered against your detected RAM."
    $selected = Select-Model $ramGiB
    if (-not $selected) { Write-Host "Aborted."; return }
}

$Model      = $selected.File
$modelPath  = Join-Path $here $Model
$ModelRepo  = $selected.Repo
$ModelPattern = $selected.Pattern

Write-Host ("Selected: {0}" -f $selected.Name)

if (Test-Path $modelPath) {
    $mb = [math]::Round((Get-Item $modelPath).Length / 1GB, 2)
    Write-Host ("OK on disk: {0} GiB" -f $mb)
} else {
    Write-Host ("Not on disk. Downloading from {0} ..." -f $ModelRepo) -ForegroundColor Yellow
    if (-not $ModelRepo) { throw "no repo for custom model; pass -ModelRepo" }
    if (-not (Test-Path $venvPy)) { throw "venv python not found at $venvPy" }

    # Warn if RAM is too low for chosen model
    if ($selected.MinRamGiB -gt 0 -and $ramGiB -lt $selected.MinRamGiB) {
        Write-Host ("  WARNING: this model recommends {0}+ GiB RAM, you have {1}." -f $selected.MinRamGiB, $ramGiB) -ForegroundColor Yellow
        Write-Host "  Will run with mmap streaming but cold prompts will be very slow." -ForegroundColor Yellow
    }

    $env:HF_HUB_ENABLE_HF_TRANSFER = "1"
    # snapshot_download handles both single files and globs (sharded models)
    & $venvPy -c "from huggingface_hub import snapshot_download; p = snapshot_download(repo_id='$ModelRepo', allow_patterns=['$ModelPattern'], local_dir=r'$here'); print('->', p)"
    if (-not (Test-Path $modelPath)) { throw "download failed (file $Model not present after snapshot)" }
    $mb = [math]::Round((Get-Item $modelPath).Length / 1GB, 2)
    Write-Host ("Downloaded {0} GiB" -f $mb)
}

if ($DownloadOnly) { Write-Host "Done (DownloadOnly)."; return }

$modelGiB = [math]::Round((Get-Item $modelPath).Length / 1GB, 1)

# ---------- 3. Auto-tune flags ----------
Section "Tuning"

# Decide if we need expert offload to CPU.
# Rule: if VRAM has room for the whole model + 2 GiB headroom, skip -ot.
# Otherwise use -ot "exps=CPU" so dense layers/attention go on GPU and
# routed experts mmap from disk via system RAM cache.
$useOtCpu = $vramGiB -lt ($modelGiB + 2)

# Context size + KV cache type based on free VRAM.
# After model + compute buffer, KV cache eats ~1 KB per token at q8_0
# for hybrid SSM (Qwen3-Next), or ~10 KB for dense attention models.
# We pick conservatively for hybrid since we mainly run those.
$ctx = 8192
$kvType = "q8_0"
if ($vramGiB -ge 24) {
    $ctx = 65536; $kvType = "f16"
} elseif ($vramGiB -ge 12) {
    $ctx = 32768; $kvType = "q8_0"
} elseif ($vramGiB -ge 8) {
    $ctx = 8192;  $kvType = "q8_0"
} else {
    $ctx = 4096;  $kvType = "q8_0"
}

# Batch + micro-batch.
# -ub drives prefill speed but balloons host-pinned compute buffer.
# RDNA1 caps host-pinned allocation around 2 GiB, so -ub 2048 is the
# sweet spot. Bigger VRAM cards can go higher.
$ub = 2048
if ($vramGiB -ge 12) { $ub = 4096 }
$b = $ub

# mlock — pin the model in RAM so OS can't evict.
# Only safe when RAM comfortably exceeds model size (8 GiB headroom for OS).
$useMlock = $ramGiB -ge ($modelGiB + 8)

Write-Host ("Context size  : {0}" -f $ctx)
Write-Host ("KV cache type : {0}" -f $kvType)
Write-Host ("Batch sizes   : -b {0} -ub {0}" -f $b)
Write-Host ("Expert offload: {0}" -f $(if ($useOtCpu) { "yes (-ot exps=CPU)" } else { "no (model fits in VRAM)" }))
Write-Host ("--mlock       : {0}" -f $(if ($useMlock) { "yes (RAM has headroom)" } else { "no (RAM too tight)" }))

# ---------- 4. Stop existing services if -Force ----------
if ($Force) {
    Section "Stopping existing"
    Get-Process llama-server,open-webui,mcpo -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "stopping $($_.ProcessName) PID $($_.Id)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep 2
}

# ---------- 5. Launch llama-server ----------
Section "Launching"

# If llama-server is already running, check whether it's serving the same model.
# If different, restart it so the new model gets loaded — otherwise the user
# would download a new GGUF only to keep chatting with the old one.
$llamaUp = Get-NetTCPConnection -LocalPort 8088 -State Listen -ErrorAction SilentlyContinue
if ($llamaUp) {
    $loadedId = Get-LoadedModelId
    $selectedLeaf = Split-Path -Leaf $modelPath
    if ($loadedId -and $loadedId -ne $selectedLeaf -and $loadedId -ne $modelPath) {
        Write-Host ("Model change detected: '{0}' -> '{1}'" -f $loadedId, $selectedLeaf) -ForegroundColor Yellow
        Stop-LlamaServer
        # Also bounce Open WebUI so its frontend Svelte cache picks up the new
        # model in the dropdown without requiring a manual browser refresh.
        Stop-OpenWebUI
        $llamaUp = $null  # fall through to launch
    } else {
        Write-Host "llama-server already running on :8088 (PID $($llamaUp.OwningProcess)) with the selected model. Use -Force to relaunch with fresh flags."
    }
}
if (-not $llamaUp) {
    $llamaArgs = @(
        "-m", "`"$modelPath`"",
        "-ngl", "99",
        "--flash-attn", "on",
        "-c", $ctx,
        "--cache-type-k", $kvType,
        "--cache-type-v", $kvType,
        "-b", $b, "-ub", $ub,
        "--jinja",
        "--host", "127.0.0.1", "--port", "8088"
    )
    if ($useOtCpu) { $llamaArgs += @("--override-tensor", "exps=CPU") }
    if ($useMlock) { $llamaArgs += "--mlock" }

    Start-Process -FilePath $llama -ArgumentList $llamaArgs -WindowStyle Normal
    Write-Host "llama-server -> http://127.0.0.1:8088"
}

if ($OnlyLlama) {
    Write-Host ""
    Write-Host "Done (OnlyLlama). API at http://127.0.0.1:8088/v1"
    return
}

# ---------- 6. Launch Open WebUI ----------
$webuiUp = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
if ($webuiUp) {
    Write-Host "Open WebUI already running on :3000 (PID $($webuiUp.OwningProcess))."
} elseif (Test-Path $webui) {
    $webuiCmd = @"
`$env:PYTHONIOENCODING='utf-8'; `$env:PYTHONUTF8='1';
`$env:WEBUI_AUTH='False';
`$env:ENABLE_API_KEYS='True';
`$env:OPENAI_API_BASE_URL='http://127.0.0.1:8088/v1';
`$env:OPENAI_API_KEY='sk-llama-cpp';
`$env:ENABLE_OLLAMA_API='False';
`$env:DATA_DIR='$dataDir';
& '$webui' serve --port 3000 --host 127.0.0.1
"@
    Start-Process powershell -ArgumentList "-NoExit","-Command",$webuiCmd -WindowStyle Normal
    Write-Host "Open WebUI    -> http://127.0.0.1:3000  (~30s to bind)"
} else {
    Write-Host "Open WebUI not installed at $webui - skipping" -ForegroundColor Yellow
}

# ---------- 7. Launch MCPO ----------
# Regenerate MCPO config with current absolute paths so the on-disk config
# never has stale paths from a previous user / tools-dir.
$mcpoUp = Get-NetTCPConnection -LocalPort 8091 -State Listen -ErrorAction SilentlyContinue
if ($mcpoUp) {
    Write-Host "MCPO already running on :8091 (PID $($mcpoUp.OwningProcess))."
} elseif (Test-Path $mcpo) {
    $venvBin = Join-Path $toolsDir "open-webui-venv\Scripts"
    $mcpoDir = Split-Path -Parent $mcpoConfig
    if (-not (Test-Path $mcpoDir)) { New-Item -ItemType Directory -Path $mcpoDir -Force | Out-Null }

    $arxivStorage = Join-Path $mcpoDir "arxiv-papers"
    $memoryFile   = Join-Path $mcpoDir "memory.json"
    $npxPath      = if ($env:NPX_PATH) { $env:NPX_PATH } else { "C:\Program Files\nodejs\npx.cmd" }
    # mcp-server-time needs IANA tz (e.g. America/New_York). Windows returns
    # "Eastern Standard Time" which doesn't work — try .NET TimeZoneInfo for the
    # IANA mapping (.NET 6+) and fall back to UTC.
    if ($env:LOCAL_TZ) {
        $tz = $env:LOCAL_TZ
    } else {
        $tz = "UTC"
        try {
            $local = [TimeZoneInfo]::Local
            if ($local.PSObject.Properties['HasIanaId'] -and $local.HasIanaId) {
                $tz = $local.Id
            }
        } catch { }
    }

    $cfg = [ordered]@{
        mcpServers = [ordered]@{
            fetch      = @{ command = (Join-Path $venvBin 'mcp-server-fetch.exe');     args = @() }
            duckduckgo = @{ command = (Join-Path $venvBin 'duckduckgo-mcp-server.exe'); args = @() }
            wikipedia  = @{ command = (Join-Path $venvBin 'wikipedia-mcp.exe');         args = @() }
            arxiv      = @{ command = (Join-Path $venvBin 'arxiv-mcp-server.exe');      args = @('--storage-path', $arxivStorage) }
            time       = @{ command = (Join-Path $venvBin 'mcp-server-time.exe');       args = @('--local-timezone', $tz) }
            memory     = @{ command = $npxPath; args = @('-y','@modelcontextprotocol/server-memory'); env = @{ MEMORY_FILE_PATH = $memoryFile } }
        }
    }
    # Write UTF-8 WITHOUT BOM. PowerShell's Set-Content -Encoding utf8 prepends a
    # BOM (EF BB BF) which MCPO's JSON parser rejects with "Expecting value: line 1 column 1".
    $json = $cfg | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($mcpoConfig, $json, [System.Text.UTF8Encoding]::new($false))
    if (-not (Test-Path $arxivStorage)) { New-Item -ItemType Directory -Path $arxivStorage -Force | Out-Null }

    Start-Process -FilePath $mcpo -ArgumentList "--config",$mcpoConfig,"--port","8091","--host","127.0.0.1" -WindowStyle Normal
    Write-Host "MCPO          -> http://127.0.0.1:8091  (free MCPs: fetch, ddg, wiki, arxiv, time, memory)"
} else {
    Write-Host "MCPO not installed - skipping" -ForegroundColor Yellow
}

# ---------- 8. Optional benchmark ----------
if ($Benchmark) {
    Section "Benchmark"
    Write-Host "Waiting for llama-server to be ready..."
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        try {
            $h = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 3 -ErrorAction Stop
            if ($h.status -eq 'ok') { break }
        } catch { Start-Sleep 3 }
    }

    function Send-Bench($prompt, $maxTok) {
        $body = @{
            model = "any"
            messages = @(@{ role='user'; content=$prompt })
            max_tokens = $maxTok
            temperature = 0
            stream = $false
        } | ConvertTo-Json -Depth 5
        $t0 = Get-Date
        $r = Invoke-RestMethod "http://127.0.0.1:8088/v1/chat/completions" `
            -Method Post -ContentType "application/json" -Body $body -TimeoutSec 600
        $sec = ((Get-Date) - $t0).TotalSeconds
        return [pscustomobject]@{
            Tokens = [int]$r.usage.completion_tokens
            Wall   = [math]::Round($sec, 1)
            TokS   = if ($sec -gt 0) { [math]::Round($r.usage.completion_tokens / $sec, 2) } else { 0 }
        }
    }

    Write-Host "Cold prompt (warming OS page cache + first inference)..."
    $cold = Send-Bench "Reply with just: ok" 5
    Write-Host ("  -> {0} tokens in {1}s = {2} tok/s" -f $cold.Tokens, $cold.Wall, $cold.TokS)

    Write-Host "Warm prompt (count 1 to 30)..."
    $warm = Send-Bench "Count from 1 to 30 in a single comma-separated line." 120
    Write-Host ("  -> {0} tokens in {1}s = {2} tok/s" -f $warm.Tokens, $warm.Wall, $warm.TokS)

    Write-Host ""
    Write-Host ("Result on this machine ({0} GiB RAM, {1} GiB VRAM):" -f $ramGiB, $vramGiB) -ForegroundColor Green
    Write-Host ("  Cold: {0} tok/s   Warm: {1} tok/s" -f $cold.TokS, $warm.TokS) -ForegroundColor Green
}

# ---------- 9. Done ----------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  CHAT IS HERE:  http://127.0.0.1:3000" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Open the URL above in your browser to start chatting." -ForegroundColor Cyan
Write-Host "  (Open WebUI may take ~30 sec to bind on first launch.)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Other endpoints:"
Write-Host "  API:    http://127.0.0.1:8088/v1   (OpenAI-compatible - for Aider, opencode, etc.)"
Write-Host "  Tools:  http://127.0.0.1:8091      (MCP-as-OpenAPI - fetch/search/wiki/arxiv/time/memory)"
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Switch model:    .\start.cmd -Pick"
Write-Host "  Measure perf:    .\start.cmd -Benchmark"
Write-Host "  Stop all:        Get-Process llama-server,open-webui,mcpo | Stop-Process -Force"

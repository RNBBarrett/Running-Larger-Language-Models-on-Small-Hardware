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
    [switch]$Force
)

# ---------- Curated abliterated model catalog ----------
# MinRamGiB is the comfortable minimum (model + 8 GiB OS headroom).
# Pattern is the HF allow_patterns glob for snapshot_download.
# File is the path to pass to llama-server -m (relative to dir).
$Catalog = @(
    [pscustomobject]@{ Id='coder-iq2';    Name='Qwen3-Coder-Next 80B-A3B abliterated  IQ2_XXS (~21 GB)';      Repo='mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF';                File='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf';            Pattern='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf';            SizeGiB=21;  MinRamGiB=16; Tag='code, agents (default)';            IsDefault=$true }
    [pscustomobject]@{ Id='coder-iq3';    Name='Qwen3-Coder-Next 80B-A3B abliterated  IQ3_XXS (~31 GB)';      Repo='mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF';                File='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ3_XXS.gguf';            Pattern='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ3_XXS.gguf';            SizeGiB=31;  MinRamGiB=24; Tag='code, better quality' }
    [pscustomobject]@{ Id='coder-q4';     Name='Qwen3-Coder-Next 80B-A3B abliterated  Q4_K_M (~48 GB)';        Repo='mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF';                File='Huihui-Qwen3-Coder-Next-abliterated.i1-Q4_K_M.gguf';             Pattern='Huihui-Qwen3-Coder-Next-abliterated.i1-Q4_K_M.gguf';             SizeGiB=48;  MinRamGiB=56; Tag='code, high quality' }
    [pscustomobject]@{ Id='instruct-iq2'; Name='Qwen3-Next 80B-A3B Instruct Decensored IQ2_XXS (~21 GB)';      Repo='mradermacher/Qwen3-Next-80B-A3B-Instruct-Decensored-i1-GGUF';             File='Qwen3-Next-80B-A3B-Instruct-Decensored.i1-IQ2_XXS.gguf';         Pattern='Qwen3-Next-80B-A3B-Instruct-Decensored.i1-IQ2_XXS.gguf';         SizeGiB=21;  MinRamGiB=16; Tag='general chat, fast' }
    [pscustomobject]@{ Id='thinking-iq2';Name='Qwen3-Next 80B-A3B Thinking-Uncensored IQ2_XXS (~21 GB)';       Repo='mradermacher/Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored-i1-GGUF';        File='Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored.i1-IQ2_XXS.gguf';    Pattern='Qwen3-Next-80B-A3B-Thinking-GRPO-Uncensored.i1-IQ2_XXS.gguf';    SizeGiB=21;  MinRamGiB=16; Tag='research, reasoning' }
    [pscustomobject]@{ Id='qwen36-q4';    Name='Qwen3.6-35B-A3B abliterated UD-Q4_K_XL (~22 GB)';              Repo='unsloth/Qwen3.6-35B-A3B-GGUF';                                            File='Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf';                                Pattern='Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf';                                SizeGiB=22;  MinRamGiB=16; Tag='newer training, smaller (NOT abliterated)' }
    [pscustomobject]@{ Id='qwen30-coder-q4';Name='Qwen3-Coder-30B-A3B abliterated Q4_K_M (~19 GB)';            Repo='mradermacher/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated-i1-GGUF';    File='Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated.i1-Q4_K_M.gguf'; Pattern='Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated.i1-Q4_K_M.gguf'; SizeGiB=19;  MinRamGiB=16; Tag='smaller code, faster' }
    [pscustomobject]@{ Id='glm-air';      Name='Huihui GLM-4.5-Air abliterated UD-Q4_K_XL (~63 GB)';           Repo='huihui-ai/Huihui-GLM-4.5-Air-abliterated-GGUF';                           File='GLM-4.5-Air-abliterated-UD-Q4_K_XL.gguf';                        Pattern='*UD-Q4_K_XL*.gguf';                                              SizeGiB=63;  MinRamGiB=72; Tag='best for research, slow (A12B)' }
    [pscustomobject]@{ Id='qwen35-122b';  Name='Qwen3.5-122B-A10B abliterated Q4_K (sharded ~74 GB)';          Repo='huihui-ai/Huihui-Qwen3.5-122B-A10B-abliterated-GGUF';                     File='Q4_K-GGUF\Q4_K-GGUF-00001-of-00008.gguf';                        Pattern='Q4_K-GGUF/*.gguf';                                               SizeGiB=74;  MinRamGiB=80; Tag='biggest abliterated Qwen' }
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

# ---------- 2. Resolve model: explicit -Model > local default > picker ----------
Section "Model"

# Find the catalog default
$defaultEntry = $Catalog | Where-Object { $_.IsDefault } | Select-Object -First 1

# If user passed -Model explicitly, try to honor it
$selected = $null
if ($Model) {
    # First check catalog by filename
    $selected = $Catalog | Where-Object { $_.File -eq $Model -or $_.Id -eq $Model } | Select-Object -First 1
    if (-not $selected) {
        # Custom filename not in catalog — synthesize a minimal entry
        $selected = [pscustomobject]@{
            Id      = 'custom'
            Name    = "Custom: $Model"
            Repo    = if ($ModelRepo) { $ModelRepo } else { '' }
            File    = $Model
            Pattern = $Model
            SizeGiB = 0
            MinRamGiB = 0
            Tag     = 'user-specified'
        }
    }
}

# If -Pick was set OR no -Model AND default isn't local, show picker
if (-not $selected -and ($Pick -or -not (Test-Path (Join-Path $here $defaultEntry.File)))) {
    Write-Host "No local model found (or -Pick was set). Showing catalog..."
    $selected = Select-Model $ramGiB
    if (-not $selected) { Write-Host "Aborted."; return }
}

# Fallback to default entry if still nothing
if (-not $selected) { $selected = $defaultEntry }

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

# Skip launching if already up
$llamaUp = Get-NetTCPConnection -LocalPort 8088 -State Listen -ErrorAction SilentlyContinue
if ($llamaUp) {
    Write-Host "llama-server already running on :8088 (PID $($llamaUp.OwningProcess)). Use -Force to relaunch."
} else {
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
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $mcpoConfig -Encoding utf8
    if (-not (Test-Path $arxivStorage)) { New-Item -ItemType Directory -Path $arxivStorage -Force | Out-Null }

    Start-Process -FilePath $mcpo -ArgumentList "--config",$mcpoConfig,"--port","8091","--host","127.0.0.1" -WindowStyle Normal
    Write-Host "MCPO          -> http://127.0.0.1:8091  (free MCPs: fetch, ddg, wiki, arxiv, time, memory)"
} else {
    Write-Host "MCPO not installed - skipping" -ForegroundColor Yellow
}

# ---------- 8. Done ----------
Section "Ready"
Write-Host "Chat:  http://127.0.0.1:3000  (Open WebUI)"
Write-Host "API:   http://127.0.0.1:8088/v1  (OpenAI-compatible)"
Write-Host "Tools: http://127.0.0.1:8091     (MCP-as-OpenAPI)"
Write-Host ""
Write-Host "Switch model: .\start.ps1 -Model `"<filename>`" -Force"
Write-Host "Stop all:     Get-Process llama-server,open-webui,mcpo | Stop-Process -Force"

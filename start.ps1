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
    [ValidateSet('','coding','general','reasoning','cyber-offense','cyber-defense','newest','popular','downloaded','speed','smartness','context')]
    [string]$Sort = "",
    [switch]$Pick,
    [switch]$DownloadOnly,
    [switch]$OnlyLlama,
    [switch]$Force,
    [switch]$Benchmark,
    [switch]$LocalOnly  # default is LAN-accessible (0.0.0.0); pass -LocalOnly to bind 127.0.0.1 only
)

# ---------- Catalog: loaded from catalog.json (ships in repo) ----------
# Schema: see catalog.json. Fall back to a tiny embedded set if catalog.json
# is missing so the script still works on a pared-down install.
function Import-Catalog {
    param([string]$JsonPath)
    if (Test-Path $JsonPath) {
        try {
            $data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            return ,$data.models
        } catch {
            Write-Host ("WARN: failed to parse {0}: {1}" -f $JsonPath, $_) -ForegroundColor Yellow
        }
    }
    Write-Host "WARN: catalog.json not found - using minimal embedded fallback" -ForegroundColor Yellow
    return ,@(
        [pscustomobject]@{ id='qwen3-4b-instruct'; name='Qwen3-4B-Instruct-2507 abliterated  Q4_K_M (~3 GB)'; family='qwen3'; tier=1; category='general'; abliterated=$true;
            repo='mradermacher/Huihui-Qwen3-4B-Instruct-2507-abliterated-i1-GGUF'; file='Huihui-Qwen3-4B-Instruct-2507-abliterated.i1-Q4_K_M.gguf'; pattern='Huihui-Qwen3-4B-Instruct-2507-abliterated.i1-Q4_K_M.gguf';
            sizeGiB=3; minRamGiB=8; activeB=4; releaseDate='2025-07-25'; good='snappy, 8 GiB-RAM friendly'; bad='shallow on niche topics' }
        [pscustomobject]@{ id='coder-80b-iq2'; name='Qwen3-Coder-Next 80B-A3B abliterated  IQ2_XXS (~21 GB)'; family='qwen3-next'; tier=5; category='coding'; abliterated=$true;
            repo='mradermacher/Huihui-Qwen3-Coder-Next-abliterated-i1-GGUF'; file='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf'; pattern='Huihui-Qwen3-Coder-Next-abliterated.i1-IQ2_XXS.gguf';
            sizeGiB=21; minRamGiB=16; activeB=3; releaseDate='2025-09-12'; good='80B brain for code+agents via NVMe streaming'; bad='cold prompts slow on tight RAM' }
    )
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------- Paths ----------
# All tool paths are derived from $env:USERPROFILE so the script is portable.
# Override any of these by setting the matching env var before launching.
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Catalog    = Import-Catalog (Join-Path $here "catalog.json")
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

# Estimate tok/s for a catalog entry given user's hardware. Approximate buckets;
# real numbers vary by quant and CPU but this gives an honest expectation.
function Get-TokSecEstimate($m, $ramGiBVal, $vramGiBVal) {
    # Active-param working set (Q4-ish: ~0.5 bytes per param)
    $activeGB = [double]$m.ActiveB * 0.5
    $availRam = [Math]::Max(2, $ramGiBVal - 4)

    # Mode 1: model fits entirely in VRAM (GPU-bound)
    if ($m.SizeGiB -le ($vramGiBVal - 0.5)) {
        if ($activeGB -le 1) { return 60 }
        if ($activeGB -le 2) { return 40 }
        if ($activeGB -le 4) { return 22 }
        if ($activeGB -le 8) { return 14 }
        return 8
    }
    # Mode 2: file > VRAM but fits in RAM cache (partial GPU + RAM bandwidth bound)
    if ($m.SizeGiB -le $availRam) {
        if ($activeGB -le 1)  { return 25 }
        if ($activeGB -le 3)  { return 15 }
        if ($activeGB -le 6)  { return 8 }
        if ($activeGB -le 10) { return 4 }
        return 2
    }
    # Mode 3: streaming from disk
    $cacheHit = [Math]::Min(0.95, $availRam / $m.SizeGiB)
    if ($activeGB -le 1.5) { return [int][Math]::Max(2, 7 + 8 * $cacheHit) }
    if ($activeGB -le 3)   { return [int][Math]::Max(1, 3 + 4 * $cacheHit) }
    if ($activeGB -le 6)   { return [int][Math]::Max(1, 1 + 2 * $cacheHit) }
    return 1
}

# Map a category to its primary benchmark for sorting.
function Get-PrimaryBench($category) {
    switch ($category) {
        'coding'        { return 'liveCodeBench' }
        'reasoning'     { return 'gpqaDiamond' }
        'cyber-offense' { return 'cyberMetric' }
        'cyber-defense' { return 'cyberMetric' }
        default         { return 'mmluPro' }   # general + everything else
    }
}

# Composite "smartness" score: average of the three general benchmarks (MMLU-Pro,
# LiveCodeBench, GPQA Diamond), each on 0-100. Returns $null if entry has none.
function Get-Smartness($entry) {
    $b = $entry.benchmarks
    if (-not $b) { return $null }
    $vals = @()
    foreach ($k in 'mmluPro','liveCodeBench','gpqaDiamond') {
        if ($b.PSObject.Properties[$k] -and $b.$k -ne $null) { $vals += [double]$b.$k }
    }
    if ($vals.Count -eq 0) { return $null }
    return [int][Math]::Round(($vals | Measure-Object -Average).Average)
}

# Sort an array of catalog entries by the named sort key.
# Sort keys: coding | general | reasoning | cyber-offense | cyber-defense | newest | popular | downloaded | speed | smartness
# Entries lacking a value sort to the end.
function Sort-CatalogEntries($entries, $sortKey, $ramGiBVal = 0, $vramGiBVal = 0) {
    $bench = $null
    switch ($sortKey) {
        'coding'        { $bench = 'liveCodeBench' }
        'general'       { $bench = 'mmluPro' }
        'reasoning'     { $bench = 'gpqaDiamond' }
        'cyber-offense' { $bench = 'cyberMetric' }
        'cyber-defense' { $bench = 'cyberMetric' }
        'smartness'     {
            return $entries | Sort-Object -Descending -Property @{Expression={
                $s = Get-Smartness $_
                if ($s -ne $null) { $s } else { -1 }
            }}
        }
        'speed'         {
            return $entries | Sort-Object -Descending -Property @{Expression={
                Get-TokSecEstimate $_ $ramGiBVal $vramGiBVal
            }}
        }
        'context'       {
            return $entries | Sort-Object -Descending -Property @{Expression={
                if ($null -ne $_.contextWindow) { [long]$_.contextWindow } else { -1 }
            }}
        }
        'newest'        {
            return $entries | Sort-Object -Descending -Property @{Expression={
                if ($_.releaseDate) { [DateTime]::Parse($_.releaseDate) } else { [DateTime]::MinValue }
            }}
        }
        'popular'       {
            return $entries | Sort-Object -Descending -Property @{Expression={
                if ($_.huggingfaceLikes -ne $null) { [long]$_.huggingfaceLikes } else { -1 }
            }}
        }
        'downloaded'    {
            return $entries | Sort-Object -Descending -Property @{Expression={
                if ($_.huggingfaceDownloads -ne $null) { [long]$_.huggingfaceDownloads } else { -1 }
            }}
        }
        default         { $bench = 'mmluPro' }
    }
    return $entries | Sort-Object -Descending -Property @{Expression={
        $b = $_.benchmarks
        if ($b -and $b.PSObject.Properties[$bench] -and $b.$bench -ne $null) { [double]$b.$bench } else { -1 }
    }}
}

# Compute days since release (or $null if releaseDate missing).
function Get-AgeDays($entry) {
    if (-not $entry.releaseDate) { return $null }
    try {
        $d = [DateTime]::Parse($entry.releaseDate)
        return [int]((Get-Date) - $d).TotalDays
    } catch { return $null }
}

# Format an entry's age as a human string ("374 days ago", "2 yrs ago").
function Format-Age($age) {
    if ($age -eq $null) { return "release date unknown" }
    if ($age -lt 30)   { return "$age days ago" }
    if ($age -lt 365)  { return "{0} months ago" -f [int]($age / 30) }
    return "{0:N1} years ago" -f ($age / 365)
}

# Build the four-bench summary line, with a marker on the entry's primary bench.
function Format-BenchLine($entry, $primaryKey) {
    $b = $entry.benchmarks
    if (-not $b) { return "" }
    function _fmt($k, $label) {
        $v = if ($b.PSObject.Properties[$k] -and $b.$k -ne $null) { $b.$k } else { '-' }
        $marker = if ($k -eq $primaryKey) { '*' } else { ' ' }
        "{0}{1} {2}" -f $marker, $label, $v
    }
    $parts = @(
        (_fmt 'mmluPro'       'MMLU'),
        (_fmt 'liveCodeBench' 'LCB'),
        (_fmt 'gpqaDiamond'   'GPQA')
    )
    if ($b.cyberMetric -ne $null) { $parts += (_fmt 'cyberMetric' 'Cyber') }
    return ($parts -join '  ')
}

# Wrap a long string at ~72 chars, indenting continuation lines.
function Format-Wrapped($text, $width = 72, $indent = "              ") {
    if (-not $text) { return @() }
    $words = $text -split '\s+'
    $lines = @()
    $current = ""
    foreach ($w in $words) {
        if (("$current $w").Trim().Length -le $width) {
            $current = ("$current $w").Trim()
        } else {
            if ($current) { $lines += $current }
            $current = $w
        }
    }
    if ($current) { $lines += $current }
    return $lines
}

# Format a context window in tokens as "32K", "128K", "262K", etc.
function Format-Context($ctx) {
    if ($null -eq $ctx) { return "ctx ?" }
    $n = [long]$ctx
    if ($n -ge 1000000) { return ("ctx {0:N1}M" -f ($n / 1000000.0)) }
    if ($n -ge 1024)    { return ("ctx {0}K" -f [int][Math]::Round($n / 1024.0)) }
    return "ctx $n"
}

# Pretty-print one entry block.
function Show-Entry($rank, $m, $ramGiBVal, $vramGiBVal, $primaryKey, $isTop) {
    $s         = Get-ModelScore     $m $ramGiBVal
    $tps       = Get-TokSecEstimate $m $ramGiBVal $vramGiBVal
    $smart     = Get-Smartness $m
    $age       = Get-AgeDays $m
    $ageTxt    = Format-Age $age
    $bench     = Format-BenchLine $m $primaryKey
    $catLabel  = if ($m.category) { $m.category } else { "uncategorized" }
    $fitWord   = switch ($s.Tag) { 'ok' { 'fits cleanly' } 'tight' { 'tight, NVMe streaming' } default { 'needs more RAM' } }
    $rankBadge = if ($isTop) { ("#{0}  ★ best in {1}" -f $rank, $catLabel) } else { ("#{0}" -f $rank) }
    $smartTxt  = if ($smart -ne $null) { ("smartness {0}/100" -f $smart) } else { "smartness n/a" }
    $ctxTxt    = Format-Context $m.contextWindow

    Write-Host ""
    Write-Host ("  {0}" -f $rankBadge) -ForegroundColor Yellow
    Write-Host ("       {0,-50}  [{1}]" -f $m.name, $catLabel)
    Write-Host ("       {0}  ~{1} t/s  -  {2}  -  {3}  -  released {4}" -f $s.Marker, $tps, $fitWord, $ctxTxt, $ageTxt) -ForegroundColor $s.Color
    if ($bench) {
        Write-Host ("       {0}    {1}" -f $bench, $smartTxt) -ForegroundColor DarkCyan
    }
    if ($m.good) {
        Write-Host "       GOOD AT  " -NoNewline -ForegroundColor Green
        $first = $true
        foreach ($line in (Format-Wrapped $m.good 64 "                ")) {
            if ($first) { Write-Host $line -ForegroundColor DarkGreen; $first = $false }
            else        { Write-Host ("                " + $line) -ForegroundColor DarkGreen }
        }
    }
    if ($m.bad) {
        Write-Host "       WEAK AT  " -NoNewline -ForegroundColor DarkYellow
        $first = $true
        foreach ($line in (Format-Wrapped $m.bad 64 "                ")) {
            if ($first) { Write-Host $line -ForegroundColor DarkGray; $first = $false }
            else        { Write-Host ("                " + $line) -ForegroundColor DarkGray }
        }
    }
}

function Show-CatalogEntries($entries, $ramGiBVal, $vramGiBVal, $sortLabel, $primaryKey, $warnBanner = "") {
    Write-Host ""
    Write-Host ("Models (sorted by: {0}, RAM={1} GiB, VRAM={2} GiB):" -f $sortLabel, $ramGiBVal, $vramGiBVal) -ForegroundColor Cyan
    if ($warnBanner) {
        Write-Host ""
        Write-Host ("  [!] {0}" -f $warnBanner) -ForegroundColor Yellow
    }
    Write-Host "  [ok] fits cleanly  [~] tight (NVMe streaming)  [!] needs more RAM" -ForegroundColor DarkGray
    Write-Host "  benchmarks: full-precision base, quants take a small hit (see quantPenalty in catalog.json)" -ForegroundColor DarkGray
    Write-Host "  '*' on a bench label = primary metric for the active sort" -ForegroundColor DarkGray
    $i = 0
    foreach ($m in $entries) {
        $i++
        Show-Entry $i $m $ramGiBVal $vramGiBVal $primaryKey ($i -eq 1)
    }
    Write-Host ""
}

# Group catalog by category and return counts.
function Get-CategoryCounts($catalog) {
    $counts = @{}
    foreach ($m in $catalog) {
        if (-not $m.category) { continue }
        $counts[$m.category] = 1 + ($counts[$m.category] | ForEach-Object { if ($_ -is [int]) { $_ } else { 0 } })
    }
    return $counts
}

function Select-Category($catalog) {
    $cats = @('coding','general','reasoning','cyber-offense','cyber-defense')
    $counts = Get-CategoryCounts $catalog
    Write-Host ""
    Write-Host "Use case (filters the list):" -ForegroundColor Cyan
    $i = 0
    foreach ($c in $cats) {
        $i++
        $n = if ($counts.ContainsKey($c)) { $counts[$c] } else { 0 }
        Write-Host ("  [{0}] {1,-15} ({2} models)" -f $i, $c, $n)
    }
    $i++
    Write-Host ("  [{0}] all             ({1} models)" -f $i, $catalog.Count)
    Write-Host "  [q] quit"
    while ($true) {
        $sel = Read-Host "Pick"
        if ($sel -eq 'q' -or $sel -eq 'Q') { return $null }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n)) {
            if ($n -ge 1 -and $n -le $cats.Count) { return $cats[$n - 1] }
            if ($n -eq $cats.Count + 1)           { return 'all' }
        }
        Write-Host "Invalid. Pick a number or q." -ForegroundColor Yellow
    }
}

function Select-Sort($category) {
    $bench = Get-PrimaryBench $category
    Write-Host ""
    Write-Host "Sort by:" -ForegroundColor Cyan
    Write-Host ("  [1] smartest in {0,-15} ({1}, default)" -f $category, $bench)
    Write-Host  "  [2] fastest on this machine    (estimated tok/s, descending)"
    Write-Host  "  [3] smartest overall           (composite of MMLU-Pro + LCB + GPQA)"
    Write-Host  "  [4] biggest context window     (longest native context, descending)"
    Write-Host  "  [5] newest first"
    Write-Host  "  [6] most popular               (HF likes - refresh-catalog.py first)"
    Write-Host  "  [7] most downloaded            (HF downloads - refresh-catalog.py first)"
    Write-Host  "  [8] back"
    while ($true) {
        $sel = Read-Host "Pick (1-8)"
        if ($sel -eq '8' -or $sel -eq 'b' -or $sel -eq 'B') { return $null }
        switch ($sel) {
            '1' { return $category }
            ''  { return $category }
            '2' { return 'speed' }
            '3' { return 'smartness' }
            '4' { return 'context' }
            '5' { return 'newest' }
            '6' { return 'popular' }
            '7' { return 'downloaded' }
        }
        Write-Host "Invalid. 1-8." -ForegroundColor Yellow
    }
}

function Select-Model($ramGiBVal, $vramGiBVal, $preselectedSort = "") {
    # Step 1: pick category
    $category = Select-Category $Catalog
    if (-not $category) { return $null }

    # Step 2: pick sort (skip if -Sort was passed and is non-empty)
    if ($preselectedSort) {
        $sortKey = $preselectedSort
    } else {
        $sortKey = Select-Sort $category
        if (-not $sortKey) { return $null }
    }

    # Step 3: filter + sort + show
    $entries = if ($category -eq 'all') { $Catalog } else { $Catalog | Where-Object { $_.category -eq $category } }

    # Detect popular/downloaded with no live data and warn + fall back
    $warnBanner = ""
    $effectiveSort = $sortKey
    if ($sortKey -eq 'popular' -or $sortKey -eq 'downloaded') {
        $field = if ($sortKey -eq 'popular') { 'huggingfaceLikes' } else { 'huggingfaceDownloads' }
        $hasData = $false
        foreach ($e in $entries) {
            if ($e.PSObject.Properties[$field] -and $null -ne $e.$field) { $hasData = $true; break }
        }
        if (-not $hasData) {
            $warnBanner = "$sortKey data not yet refreshed. Run 'python scripts/refresh-catalog.py' first. Falling back to MMLU-Pro."
            $effectiveSort = 'general'
        }
    }

    $entries = @(Sort-CatalogEntries $entries $effectiveSort $ramGiBVal $vramGiBVal)

    $sortLabel = switch ($effectiveSort) {
        'speed'      { 'fastest on this machine (estimated tok/s)' }
        'smartness'  { 'smartness composite (MMLU + LCB + GPQA averaged)' }
        'context'    { 'biggest context window (native max)' }
        'newest'     { 'newest first' }
        'popular'    { 'HuggingFace likes' }
        'downloaded' { 'HuggingFace downloads' }
        default      { (Get-PrimaryBench $category) + ' (higher = better)' }
    }

    # Primary bench for the '*' marker on the bench line
    $primaryKey = switch ($effectiveSort) {
        'speed'      { '' }
        'smartness'  { '' }
        'context'    { '' }
        'newest'     { '' }
        'popular'    { '' }
        'downloaded' { '' }
        default      { Get-PrimaryBench $category }
    }

    Show-CatalogEntries $entries $ramGiBVal $vramGiBVal $sortLabel $primaryKey $warnBanner

    while ($true) {
        $sel = Read-Host "Pick a number 1-$($entries.Count) ('b' back, 'q' quit)"
        if ($sel -eq 'q' -or $sel -eq 'Q') { return $null }
        if ($sel -eq 'b' -or $sel -eq 'B') { return Select-Model $ramGiBVal $vramGiBVal $preselectedSort }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $entries.Count) {
            return $entries[$n - 1]
        }
        Write-Host "Invalid. Pick a number 1-$($entries.Count), 'b' or 'q'." -ForegroundColor Yellow
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
function Manage-LocalModels($localModels, $baseDir, $ramGiBVal, $vramGiBVal, $preselectedSort = "") {
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
            return Select-Model $ramGiBVal $vramGiBVal $preselectedSort
        }

        if ($sel -eq 'a' -or $sel -eq 'A') {
            Write-Host "Deleting all on-disk catalog models..." -ForegroundColor Yellow
            foreach ($lm in $localModels) { Remove-LocalModel $lm $baseDir }
            return Select-Model $ramGiBVal $vramGiBVal $preselectedSort
        }

        Write-Host "Invalid. Pick 1-$($localModels.Count), 'd N', 'n', 'a', or 'q'." -ForegroundColor Yellow
    }
    # All models deleted by the loop above
    return Select-Model $ramGiBVal $vramGiBVal $preselectedSort
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
    $selected = $Catalog | Where-Object { $_.file -eq $Model -or $_.id -eq $Model } | Select-Object -First 1
    if (-not $selected) {
        $selected = [pscustomobject]@{
            id='custom'; name="Custom: $Model"
            repo=$(if ($ModelRepo) { $ModelRepo } else { '' })
            file=$Model; pattern=$Model
            sizeGiB=0; minRamGiB=0; category='general'; activeB=0
        }
    }
}

# 2b. -Pick forces the picker
if (-not $selected -and $Pick) {
    $selected = Select-Model $ramGiB $vramGiB $Sort
    if (-not $selected) { Write-Host "Aborted."; return }
}

# 2c. No -Model and no -Pick: scan disk for catalog models
if (-not $selected) {
    $localModels = Get-LocalModels $here
    if ($localModels.Count -gt 0) {
        # Models exist on disk — let user manage them (run / delete / download new)
        $selected = Manage-LocalModels $localModels $here $ramGiB $vramGiB $Sort
        if (-not $selected) { Write-Host "Aborted."; return }
    }
}

# 2d. Nothing on disk → catalog picker (never silently auto-pick anything)
if (-not $selected) {
    Write-Host "No local model found." -ForegroundColor Yellow
    Write-Host "Below is a catalog of models filtered against your detected RAM."
    $selected = Select-Model $ramGiB $vramGiB $Sort
    if (-not $selected) { Write-Host "Aborted."; return }
}

$Model        = $selected.file
$modelPath    = Join-Path $here $Model
$ModelRepo    = $selected.repo
$ModelPattern = if ($selected.pattern) { $selected.pattern } else { $selected.file }
$ModelId      = $selected.id

Write-Host ("Selected: {0}" -f $selected.name)

if (Test-Path $modelPath) {
    $mb = [math]::Round((Get-Item $modelPath).Length / 1GB, 2)
    Write-Host ("OK on disk: {0} GiB" -f $mb)
} else {
    Write-Host ("Not on disk. Probing mirrors and downloading from {0} ..." -f $ModelRepo) -ForegroundColor Yellow
    if (-not $ModelRepo) { throw "no repo for custom model; pass -ModelRepo" }
    if (-not (Test-Path $venvPy)) { throw "venv python not found at $venvPy" }

    # Warn if RAM is too low for chosen model
    if ($selected.minRamGiB -gt 0 -and $ramGiB -lt $selected.minRamGiB) {
        Write-Host ("  WARNING: this model recommends {0}+ GiB RAM, you have {1}." -f $selected.minRamGiB, $ramGiB) -ForegroundColor Yellow
        Write-Host "  Will run with mmap streaming but cold prompts will be very slow." -ForegroundColor Yellow
    }

    $downloadScript = Join-Path $here "scripts\download.py"
    if ((Test-Path $downloadScript) -and ($ModelId -ne 'custom')) {
        # Use download.py for mirror probing + hf_transfer
        & $venvPy $downloadScript --id $ModelId --catalog (Join-Path $here "catalog.json") --dest $here
    } else {
        # Custom model or scripts/ missing: fall back to direct snapshot_download
        $env:HF_HUB_ENABLE_HF_TRANSFER = "1"
        & $venvPy -c "from huggingface_hub import snapshot_download; p = snapshot_download(repo_id='$ModelRepo', allow_patterns=['$ModelPattern'], local_dir=r'$here'); print('->', p)"
    }
    if (-not (Test-Path $modelPath)) { throw "download failed (file $Model not present after download)" }
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

# LAN access is on by default - bind to 0.0.0.0 so other devices on your LAN
# can reach http://<your-ip>:3000. Pass -LocalOnly to bind 127.0.0.1 only.
# Trusted-network assumption: WEBUI_AUTH stays off, so anyone on the LAN gets in.
$bindHost = if ($LocalOnly) { "127.0.0.1" } else { "0.0.0.0" }
$lanIp = $null
if (-not $LocalOnly) {
    try {
        $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                  Select-Object -First 1).IPAddress
    } catch { }
    if (-not $lanIp) { $lanIp = "<your-lan-ip>" }
    Write-Host ("LAN access: binding to 0.0.0.0 - reachable at http://{0}:3000 from other devices on your LAN" -f $lanIp) -ForegroundColor Yellow
    Write-Host "            Windows Firewall may prompt to allow llama-server / python.exe on 'Private' networks - click Allow." -ForegroundColor DarkGray
    Write-Host "            Pass -LocalOnly to bind 127.0.0.1 instead." -ForegroundColor DarkGray
}

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
        "--host", $bindHost, "--port", "8088"
    )
    if ($useOtCpu) { $llamaArgs += @("--override-tensor", "exps=CPU") }
    if ($useMlock) { $llamaArgs += "--mlock" }

    Start-Process -FilePath $llama -ArgumentList $llamaArgs -WindowStyle Normal
    Write-Host ("llama-server -> http://{0}:8088" -f $bindHost)
}

if ($OnlyLlama) {
    Write-Host ""
    Write-Host ("Done (OnlyLlama). API at http://{0}:8088/v1" -f $bindHost)
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
& '$webui' serve --port 3000 --host $bindHost
"@
    Start-Process powershell -ArgumentList "-NoExit","-Command",$webuiCmd -WindowStyle Normal
    Write-Host ("Open WebUI    -> http://{0}:3000  (~30s to bind)" -f $bindHost)
    if ((-not $LocalOnly) -and $lanIp) {
        Write-Host ("              LAN URL: http://{0}:3000" -f $lanIp) -ForegroundColor Green
    }
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

    Start-Process -FilePath $mcpo -ArgumentList "--config",$mcpoConfig,"--port","8091","--host",$bindHost -WindowStyle Normal
    Write-Host ("MCPO          -> http://{0}:8091  (free MCPs: fetch, ddg, wiki, arxiv, time, memory)" -f $bindHost)
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
if ($Lan -and $lanIp) {
    Write-Host ("  LAN ACCESS:    http://{0}:3000  (other devices on your LAN)" -f $lanIp) -ForegroundColor Green
}
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
Write-Host "  Pick by use:     .\start.cmd -Pick -Sort coding   (or general/reasoning/cyber-offense/cyber-defense/context/newest/popular/downloaded)"
Write-Host "  Measure perf:    .\start.cmd -Benchmark"
Write-Host "  Refresh stats:   python scripts\refresh-catalog.py   (HF likes/downloads, then re-run with -Sort popular)"
Write-Host "  LAN-restrict:    .\start.cmd -LocalOnly   (bind 127.0.0.1 only; default is LAN-accessible)"
Write-Host "  Stop all:        Get-Process llama-server,open-webui,mcpo | Stop-Process -Force"

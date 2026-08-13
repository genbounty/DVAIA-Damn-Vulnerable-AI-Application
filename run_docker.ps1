# DVAIA Docker Compose wrapper for Windows (PowerShell).
# Prefer WSL2 + ./run_docker.sh when possible; use this from PowerShell or cmd.
# This is a test comment
param(
    [switch]$GeminiOnly,
    [switch]$OpenAIOnly,
    [switch]$Local,
    [switch]$SkipPrompt,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Show-Help {
    Write-Host @"
Usage: .\run_docker.ps1 [OPTIONS]

Windows wrapper for docker compose (same modes as run_docker.sh).
For interactive setup and full parity, use WSL2: ./run_docker.sh

Options:
  -GeminiOnly     Cloud Gemini — no Ollama
  -OpenAIOnly     Cloud OpenAI — no Ollama
  -Local          Local Ollama stack
  -SkipPrompt     Use .env flags only; default to local if unset
  -Help           Show this help

Cloud modes require API keys in .env. See .env.example.
"@
}

function Test-Truthy {
    param([string]$Value)
    switch ($Value.ToLower()) {
        { $_ -in "1", "true", "yes" } { return $true }
        default { return $false }
    }
}

function Import-EnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_ -replace "`r$", ""
        if ($line -match '^\s*#' -or $line -match '^\s*$') { return }
        if ($line -match '^\s*([^#=]+?)=(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($value -notmatch '^["'']') {
                $value = ($value -split '\s+#', 2)[0].Trim()
            }
            Set-Item -Path "env:$name" -Value $value
        }
    }
}

if ($Help) {
    Show-Help
    exit 0
}

if (-not (Test-Path .env) -and (Test-Path .env.example)) {
    Write-Host "No .env file found. Copy .env.example to .env and add API keys for cloud mode."
}

Import-EnvFile ".env"

$geminiMode = $GeminiOnly -or (Test-Truthy $env:GEMINI_ONLY)
$openaiMode = $OpenAIOnly -or (Test-Truthy $env:OPENAI_ONLY)

if ($Local) {
    $geminiMode = $false
    $openaiMode = $false
}

if ($geminiMode -and $openaiMode) {
    Write-Error "Cannot use both Gemini-only and OpenAI-only mode."
    exit 1
}

if (-not $SkipPrompt -and -not $GeminiOnly -and -not $OpenAIOnly -and -not $Local) {
    if (-not $geminiMode -and -not $openaiMode) {
        Write-Host "No mode selected. Use -Local, -GeminiOnly, -OpenAIOnly, or set GEMINI_ONLY/OPENAI_ONLY in .env."
        Write-Host "For interactive setup, run ./run_docker.sh in WSL2 or Git Bash."
        exit 1
    }
}

Get-ChildItem -Recurse -Directory -Filter __pycache__ -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$composeArgs = @("compose", "up", "--build")

if ($openaiMode) {
    if (-not $env:OPENAI_API_KEY) {
        Write-Error "OPENAI_ONLY mode requires OPENAI_API_KEY in .env"
        exit 1
    }
    $env:OPENAI_ONLY = "true"
    $env:GEMINI_ONLY = "false"
    if (-not $env:EMBEDDING_BACKEND) { $env:EMBEDDING_BACKEND = "openai" }
    $env:OLLAMA_HOST = ""
    Write-Host ""
    Write-Host "OpenAI-only mode: starting Qdrant + DVAIA (skipping Ollama)"
    Write-Host ""
}
elseif ($geminiMode) {
    if (-not $env:GOOGLE_API_KEY -and -not $env:GEMINI_API_KEY) {
        Write-Error "GEMINI_ONLY mode requires GOOGLE_API_KEY or GEMINI_API_KEY in .env"
        exit 1
    }
    $env:GEMINI_ONLY = "true"
    $env:OPENAI_ONLY = "false"
    if (-not $env:EMBEDDING_BACKEND) { $env:EMBEDDING_BACKEND = "gemini" }
    $env:OLLAMA_HOST = ""
    Write-Host ""
    Write-Host "Gemini-only mode: starting Qdrant + DVAIA (skipping Ollama)"
    Write-Host ""
}
else {
    $env:OLLAMA_HOST = "http://ollama:11434"
    $env:GEMINI_ONLY = "false"
    $env:OPENAI_ONLY = "false"
    $composeArgs = @("compose", "--profile", "ollama", "up", "--build")
    Write-Host ""
    Write-Host "Local mode: building and running DVAIA with Ollama + Qdrant..."
    Write-Host "Downloads first; the app will NOT start until model downloads finish."
    Write-Host ""

    function Format-Duration([int]$Seconds) {
        $ts = [TimeSpan]::FromSeconds($Seconds)
        if ($ts.TotalHours -ge 1) { return "{0}h{1:D2}m{2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds }
        if ($ts.TotalMinutes -ge 1) { return "{0}m{1:D2}s" -f [int]$ts.TotalMinutes, $ts.Seconds }
        return "{0}s" -f $ts.Seconds
    }

    Write-Host "Starting Ollama + Qdrant first..."
    & docker compose --profile ollama up -d --build ollama qdrant

    $waited = 0
    $interval = 10
    $maxWait = 21600  # 6 hours
    $ready = $false
    $models = @(
        @{ Name = "llama3.2:3b"; Label = "~2 GB" },
        @{ Name = "nomic-embed-text"; Label = "~275 MB" },
        @{ Name = "qwen3:0.6b"; Label = "~400 MB" },
        @{ Name = "qwen2.5vl:7b"; Label = "~6 GB (largest)" }
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " Waiting for Ollama model downloads before starting the app"
    Write-Host " Total ~9-10 GB — on slow networks this can take hours"
    Write-Host (" Timeout: {0}" -f (Format-Duration $maxWait))
    Write-Host " Full live log: docker compose --profile ollama logs -f ollama"
    Write-Host "============================================================"
    Write-Host ""

    while ($waited -lt $maxWait) {
        & docker compose --profile ollama exec -T ollama test -f /tmp/dvaia-ollama-ready 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("All Ollama models ready (elapsed {0})." -f (Format-Duration $waited))
            Write-Host ""
            $ready = $true
            break
        }

        $have = @(& docker compose --profile ollama exec -T ollama ollama list 2>$null |
            Select-Object -Skip 1 |
            ForEach-Object { ($_ -split '\s+')[0] })
        $logs = & docker compose --profile ollama logs --no-log-prefix --tail 120 ollama 2>$null
        $plain = ($logs | Out-String) -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace "`r", ''
        $stage = ($plain -split "`n" | Where-Object { $_ -match 'DVAIA: (pulling|done)' } | Select-Object -Last 1)
        $layer = ($plain -split "`n" | Where-Object { $_ -match 'pulling [a-f0-9]+:' } | Select-Object -Last 1)

        $doneCount = 0
        $currentIdx = 0
        $current = $null
        for ($i = 0; $i -lt $models.Count; $i++) {
            $m = $models[$i]
            if ($have -contains $m.Name) { $doneCount++; continue }
            if ($stage -and $stage -match 'pulling' -and $stage -match [regex]::Escape($m.Name)) {
                $currentIdx = $i + 1
                $current = $m
                break
            }
            if ($null -eq $current) {
                $currentIdx = $i + 1
                $current = $m
            }
        }

        Write-Host ("-- Ollama download  elapsed {0}  ·  models {1}/{2} complete --" -f (Format-Duration $waited), $doneCount, $models.Count)
        if ($null -ne $current) {
            Write-Host ""
            Write-Host ("  >>> NOW DOWNLOADING ({0}/{1}): {2}  ({3})" -f $currentIdx, $models.Count, $current.Name, $current.Label)
            Write-Host ""
        }
        for ($i = 0; $i -lt $models.Count; $i++) {
            $m = $models[$i]
            $n = $i + 1
            if ($have -contains $m.Name) {
                Write-Host ("  {0}/{1}  [OK   ] {2,-20} {3}" -f $n, $models.Count, $m.Name, $m.Label)
            }
            elseif ($null -ne $current -and $m.Name -eq $current.Name) {
                Write-Host ("  {0}/{1}  [>>>  ] {2,-20} {3}  <== current" -f $n, $models.Count, $m.Name, $m.Label)
            }
            else {
                Write-Host ("  {0}/{1}  [wait ] {2,-20} {3}" -f $n, $models.Count, $m.Name, $m.Label)
            }
        }
        if ($layer) { Write-Host "  Progress: $($layer.Trim())" }
        else { Write-Host "  Progress: (waiting for layer data...)" }
        Write-Host ""

        Start-Sleep -Seconds $interval
        $waited += $interval
    }
    if (-not $ready) {
        Write-Error ("Timed out after {0} waiting for Ollama models." -f (Format-Duration $maxWait))
        exit 1
    }
    Write-Host "Starting DVAIA app (models already ready)..."
    Write-Host ""
}

& docker @composeArgs

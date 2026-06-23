# DVAIA Docker Compose wrapper for Windows (PowerShell).
# Prefer WSL2 + ./run_docker.sh when possible; use this from PowerShell or cmd.

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
    Write-Host ""
}

& docker @composeArgs

# Project Archiving Utility - Bootstrap Installer/Launcher
# Usage: irm https://raw.githubusercontent.com/slitzer/Project-Archiving-Utility/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$RepoZip = "https://github.com/slitzer/Project-Archiving-Utility/archive/refs/heads/main.zip"
$Base    = Join-Path $env:ProgramData "ProjectArchivingUtility"
$ZipPath = Join-Path $env:TEMP "Project-Archiving-Utility-main.zip"

Write-Host "== Project Archiving Utility ==" -ForegroundColor Cyan
Write-Host "Install folder: $Base"
Write-Host "Downloading:    $RepoZip"

# Ensure folders
New-Item -ItemType Directory -Path $Base -Force | Out-Null

# Download
Invoke-WebRequest -Uri $RepoZip -OutFile $ZipPath -UseBasicParsing

# Extract
Write-Host "Extracting..."
Expand-Archive -Path $ZipPath -DestinationPath $Base -Force

# Find extracted folder
$Extracted = Join-Path $Base "Project-Archiving-Utility-main"
$UiPath    = Join-Path $Extracted "ArchiveUI.ps1"

if (!(Test-Path $UiPath)) {
    throw "ArchiveUI.ps1 not found at expected path: $UiPath"
}

Write-Host "Launching UI..." -ForegroundColor Green
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UiPath

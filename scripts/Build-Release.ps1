# SPDX-License-Identifier: GPL-3.0-or-later

param(
    [string]$Version = '',
    [string]$Runtime = 'win-x64',
    [switch]$FrameworkDependent,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Version) {
    $Version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
}

$projectPath = Join-Path $repoRoot 'src\BgwBulkEncoder\BgwBulkEncoder.csproj'
$distDir = Join-Path $repoRoot 'dist'
$publishDir = Join-Path $distDir 'publish'
$packageName = "FFXI-BGW-Converter-v$Version-$Runtime"
$packageDir = Join-Path $distDir $packageName
$zipPath = Join-Path $distDir "$packageName.zip"

if (Test-Path -LiteralPath $publishDir) {
    Remove-Item -LiteralPath $publishDir -Recurse -Force
}
if (Test-Path -LiteralPath $packageDir) {
    Remove-Item -LiteralPath $packageDir -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Force -Path $publishDir, $packageDir | Out-Null

$selfContained = if ($FrameworkDependent) { 'false' } else { 'true' }
dotnet publish $projectPath -c Release -r $Runtime --self-contained $selfContained `
    -p:PublishSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:Version=$Version `
    -o $publishDir
if ($LASTEXITCODE -ne 0) {
    throw 'dotnet publish failed.'
}

New-Item -ItemType Directory -Force -Path (Join-Path $packageDir 'bin'), (Join-Path $packageDir 'examples') | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'Convert-ToBGW.ps1') -Destination $packageDir -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $packageDir -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $packageDir -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'VERSION') -Destination $packageDir -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'examples\metadata.example.csv') -Destination (Join-Path $packageDir 'examples') -Force
Copy-Item -LiteralPath (Join-Path $publishDir 'BgwBulkEncoder.exe') -Destination (Join-Path $packageDir 'bin\BgwBulkEncoder.exe') -Force

Compress-Archive -LiteralPath $packageDir -DestinationPath $zipPath -Force
if (-not $KeepStaging) {
    Remove-Item -LiteralPath $publishDir -Recurse -Force
    Remove-Item -LiteralPath $packageDir -Recurse -Force
}

Write-Host "Release package created: $zipPath"

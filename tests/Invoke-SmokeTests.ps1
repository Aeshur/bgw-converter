# SPDX-License-Identifier: GPL-3.0-or-later

param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

function Test-Tool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found on PATH."
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Get-BgwHeader([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    [pscustomobject]@{
        Magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 9)
        Size = [BitConverter]::ToInt32($bytes, 0x10)
        Id = [BitConverter]::ToInt32($bytes, 0x14)
        LoopHeader = [BitConverter]::ToInt32($bytes, 0x1c)
        ActualSize = (Get-Item -LiteralPath $Path).Length
    }
}

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)

Test-Tool 'ffmpeg'
Test-Tool 'ffprobe'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bgw-converter-test-' + [Guid]::NewGuid().ToString('N'))
$sourceDir = Join-Path $testRoot 'input_audio'
$outputDir = Join-Path $testRoot 'output_bgw'
$metadataOutputDir = Join-Path $testRoot 'metadata_output_bgw'

try {
    New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:duration=1' -ac 2 -ar 44100 -c:a libvorbis (Join-Path $sourceDir '001 - Smoke Test.ogg')
    if ($LASTEXITCODE -ne 0) {
        throw 'ffmpeg failed to create smoke-test audio.'
    }

    & (Join-Path $RepoRoot 'Convert-ToBGW.ps1') -SourceDir $sourceDir -OutputDir $outputDir -StartMusicId 500 -Clean
    if ($LASTEXITCODE -ne 0) {
        throw 'Convert-ToBGW.ps1 failed folder conversion smoke test.'
    }

    $bgw = Join-Path $outputDir 'music500.bgw'
    Assert-True (Test-Path -LiteralPath $bgw) 'Expected music500.bgw was not created.'
    $header = Get-BgwHeader $bgw
    Assert-True ($header.Magic -eq 'BGMStream') 'music500.bgw has an invalid magic header.'
    Assert-True ($header.Id -eq 500) 'music500.bgw has the wrong internal music ID.'
    Assert-True ($header.Size -eq $header.ActualSize) 'music500.bgw has a mismatched file-size header.'
    Assert-True (Test-Path -LiteralPath (Join-Path $outputDir 'encode-report.csv')) 'encode-report.csv was not created.'
    Assert-True (Test-Path -LiteralPath (Join-Path $outputDir 'encoder-metadata.csv')) 'encoder-metadata.csv was not created.'

    $metadataPath = Join-Path $testRoot 'metadata.csv'
    @(
        'music_id,source_file,output_file,title,loop_enabled,loop_start_sample',
        '501,001 - Smoke Test.ogg,custom501.bgw,Loop From Start,true,0'
    ) | Set-Content -LiteralPath $metadataPath -Encoding UTF8

    & (Join-Path $RepoRoot 'Convert-ToBGW.ps1') -SourceDir $sourceDir -MetadataCsv $metadataPath -OutputDir $metadataOutputDir -Clean
    if ($LASTEXITCODE -ne 0) {
        throw 'Convert-ToBGW.ps1 failed metadata conversion smoke test.'
    }

    $metadataBgw = Join-Path $metadataOutputDir 'custom501.bgw'
    Assert-True (Test-Path -LiteralPath $metadataBgw) 'Expected custom501.bgw was not created.'
    $metadataHeader = Get-BgwHeader $metadataBgw
    Assert-True ($metadataHeader.Magic -eq 'BGMStream') 'custom501.bgw has an invalid magic header.'
    Assert-True ($metadataHeader.Id -eq 501) 'custom501.bgw has the wrong internal music ID.'
    Assert-True ($metadataHeader.Size -eq $metadataHeader.ActualSize) 'custom501.bgw has a mismatched file-size header.'
    Assert-True ($metadataHeader.LoopHeader -eq 1) 'custom501.bgw should loop from sample 0.'

    Write-Host 'Smoke tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

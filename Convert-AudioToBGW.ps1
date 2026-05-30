# SPDX-License-Identifier: GPL-3.0-or-later

param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [string]$MetadataCsv = '',
    [string]$OutputDir = '',
    [int]$StartMusicId = 300,
    [string]$WorkDir = '',
    [switch]$Recurse,
    [switch]$Clean,
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'

$SupportedExtensions = @('.ogg', '.wav', '.flac', '.mp3', '.m4a', '.aac', '.opus', '.aif', '.aiff', '.wma')
$TargetSampleRate = 44100

function Test-Tool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found on PATH."
    }
}

function ConvertTo-SafeFileName([string]$Name) {
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $Name = $Name.Replace($char, '-')
    }
    return ($Name -replace '\s+', ' ').Trim()
}

function Get-RowValue($Row, [string[]]$Names, [string]$Default = '') {
    foreach ($name in $Names) {
        $property = $Row.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return $Default
}

function ConvertTo-Bool([string]$Value, [bool]$Default) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }
    return $Value.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'y')
}

function Resolve-SourceFile([string]$BaseDir, [string]$FileName) {
    if ([IO.Path]::IsPathRooted($FileName)) {
        $resolved = [IO.Path]::GetFullPath($FileName)
        if (Test-Path -LiteralPath $resolved) {
            return $resolved
        }
        throw "Missing source audio file: $FileName"
    }

    $candidates = @(
        (Join-Path $BaseDir $FileName),
        (Join-Path $BaseDir ([IO.Path]::GetFileName($FileName)))
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw "Missing source audio file: $FileName"
}

function Get-AudioRowsFromMetadata([string]$Path, [string]$BaseDir) {
    $rows = Import-Csv -LiteralPath $Path
    foreach ($row in $rows) {
        $musicId = Get-RowValue $row @('music_id', 'id')
        if (-not $musicId) {
            throw "Metadata row is missing music_id."
        }

        $sourceFile = Get-RowValue $row @('source_file', 'input_file', 'file')
        if (-not $sourceFile) {
            throw "Metadata row for music_id=$musicId is missing source_file."
        }

        $sourcePath = Resolve-SourceFile $BaseDir $sourceFile
        $title = Get-RowValue $row @('title', 'english_title', 'name') ([IO.Path]::GetFileNameWithoutExtension($sourcePath))
        $outputFile = Get-RowValue $row @('output_file', 'bgw_file') ('music{0:000}.bgw' -f [int]$musicId)

        [pscustomobject]@{
            music_id = [string]$musicId
            title = $title
            source_path = $sourcePath
            output_file = $outputFile
            loop_enabled = Get-RowValue $row @('loop_enabled') ''
            loop_start_sample = Get-RowValue $row @('loop_start_sample') ''
        }
    }
}

function Get-AudioRowsFromFolder([string]$BaseDir, [int]$FirstMusicId, [bool]$Recursive) {
    $childArgs = @{
        LiteralPath = $BaseDir
        File = $true
    }
    if ($Recursive) {
        $childArgs.Recurse = $true
    }

    $files = Get-ChildItem @childArgs |
        Where-Object { $SupportedExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object FullName

    $index = 0
    foreach ($file in $files) {
        $musicId = $FirstMusicId + $index
        $index++

        [pscustomobject]@{
            music_id = [string]$musicId
            title = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            source_path = $file.FullName
            output_file = 'music{0:000}.bgw' -f $musicId
            loop_enabled = ''
            loop_start_sample = ''
        }
    }
}

function Get-ProbeInfo([string]$Path) {
    $json = & ffprobe -v error -show_entries stream=sample_rate,channels,duration_ts:stream_tags=LoopStart,LoopEnd -of json $Path
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe failed for $Path"
    }

    $probe = $json | ConvertFrom-Json
    if (-not $probe.streams -or $probe.streams.Count -eq 0) {
        throw "No audio stream found in $Path"
    }

    return $probe.streams[0]
}

function Convert-LoopSampleToTargetRate([string]$SampleText, [int]$SourceRate) {
    if (-not $SampleText) {
        return ''
    }

    $sample = [double]::Parse($SampleText, [Globalization.CultureInfo]::InvariantCulture)
    if ($SourceRate -le 0 -or $SourceRate -eq $TargetSampleRate) {
        return [string][int64][math]::Round($sample)
    }

    return [string][int64][math]::Round($sample * $TargetSampleRate / $SourceRate)
}

$SourceDir = [IO.Path]::GetFullPath($SourceDir)
if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "SourceDir does not exist: $SourceDir"
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $SourceDir 'BGW_Output'
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)

$autoWorkDir = -not $WorkDir
if ($autoWorkDir) {
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('ffxi-bgw-tools-' + [Guid]::NewGuid().ToString('N'))
}
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
$inputWav = Join-Path $WorkDir 'input_wav'
$encoderMetadata = Join-Path $WorkDir 'encoder-metadata.csv'
$reportPath = Join-Path $OutputDir 'encode-report.csv'
$projectPath = Join-Path $PSScriptRoot 'src\BgwBulkEncoder\BgwBulkEncoder.csproj'

Test-Tool 'ffmpeg'
Test-Tool 'ffprobe'
Test-Tool 'dotnet'

try {
    New-Item -ItemType Directory -Force -Path $inputWav, $OutputDir | Out-Null

    if ($MetadataCsv) {
        $metadataPath = [IO.Path]::GetFullPath($MetadataCsv)
        $audioRows = @(Get-AudioRowsFromMetadata $metadataPath $SourceDir)
    }
    else {
        $audioRows = @(Get-AudioRowsFromFolder $SourceDir $StartMusicId $Recurse.IsPresent)
    }

    if ($audioRows.Count -eq 0) {
        throw "No supported audio files were found."
    }

    $encoderRows = @(foreach ($row in $audioRows) {
        $probe = Get-ProbeInfo $row.source_path
        $sourceRate = [int]$probe.sample_rate
        $tags = $probe.tags
        $hasLoopStartTag = $false
        if ($tags) {
            $hasLoopStartTag = [bool]($tags.PSObject.Properties.Name -contains 'LoopStart')
        }

        $metadataLoopEnabled = ConvertTo-Bool $row.loop_enabled $hasLoopStartTag
        $loopStart = if ($row.loop_start_sample) {
            [string]$row.loop_start_sample
        }
        elseif ($hasLoopStartTag) {
            Convert-LoopSampleToTargetRate ([string]$tags.LoopStart) $sourceRate
        }
        else {
            '0'
        }

        $wavName = 'music{0} - {1}.wav' -f $row.music_id, (ConvertTo-SafeFileName $row.title)
        $wavPath = Join-Path $inputWav $wavName
        & ffmpeg -hide_banner -loglevel error -y -i $row.source_path -vn -ac 2 -ar $TargetSampleRate -c:a pcm_s16le $wavPath
        if ($LASTEXITCODE -ne 0) {
            throw "ffmpeg failed for $($row.source_path)"
        }

        [pscustomobject]@{
            music_id = $row.music_id
            output_file = $row.output_file
            input_wav = $wavName
            title = $row.title
            source_file = $row.source_path
            loop_enabled = $metadataLoopEnabled.ToString().ToLowerInvariant()
            loop_start_sample = $loopStart
        }
    })

    $encoderRows | Export-Csv -LiteralPath $encoderMetadata -NoTypeInformation -Encoding UTF8
    dotnet run --project $projectPath -c Release -- --input $inputWav --out $OutputDir --metadata $encoderMetadata --report $reportPath --clean $Clean.IsPresent.ToString().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0) {
        throw 'BgwBulkEncoder failed.'
    }

    Copy-Item -LiteralPath $encoderMetadata -Destination (Join-Path $OutputDir 'encoder-metadata.csv') -Force
    Write-Host "Done: $($encoderRows.Count) BGWs written to $OutputDir"
}
finally {
    if ($autoWorkDir -and -not $KeepWorkDir -and (Test-Path -LiteralPath $WorkDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
}

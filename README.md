# BGW Converter

## What It Does

- Converts common audio formats into FFXI `BGMStream` `.bgw` files.
- Assigns FFXI music IDs such as `music300.bgw`.
- Preserves `LoopStart` tags when present.
- Supports a CSV file for exact IDs, output names, and loop points.

## Requirements

- Windows PowerShell 5 or newer
- [FFmpeg](https://ffmpeg.org/download.html), including `ffprobe`, on `PATH`

If you use the source version, you also need the [.NET 8 SDK](https://dotnet.microsoft.com/download). Release zips include the BGW encoder executable.

## Quick Start

Put audio files in a folder, then run:

```powershell
.\Convert-ToBGW.ps1 `
  -SourceDir '.\input_audio' `
  -OutputDir '.\output_bgw' `
  -StartMusicId 300 `
  -Clean
```

Files are sorted by filename. The first file becomes `music300.bgw`, the next becomes `music301.bgw`, and so on.

Supported input formats include `.ogg`, `.wav`, `.flac`, `.mp3`, `.m4a`, `.aac`, `.opus`, `.aif`, `.aiff`, and `.wma`.

If you hear clipping or light static in-game, try adding a little headroom before encoding:

```powershell
.\Convert-ToBGW.ps1 `
  -SourceDir '.\input_audio' `
  -OutputDir '.\output_bgw_headroom' `
  -StartMusicId 300 `
  -GainDb -3 `
  -Clean
```

`-GainDb` applies gain during the WAV preparation step. Negative values lower volume; `-3` is a good first test.

## Metadata CSV

Use a CSV when you want exact IDs, names, or loop points:

```csv
music_id,source_file,output_file,title,loop_enabled,loop_start_sample
300,track001.ogg,music300.bgw,Opening,true,0
301,track002.ogg,music301.bgw,Field Theme,false,0
```

Then run:

```powershell
.\Convert-ToBGW.ps1 `
  -SourceDir '.\input_audio' `
  -MetadataCsv '.\examples\metadata.example.csv' `
  -OutputDir '.\output_bgw' `
  -GainDb -3 `
  -Clean
```

Metadata notes:

- `source_file` is relative to `SourceDir`, unless you use an absolute path.
- `loop_enabled=true` with `loop_start_sample=0` loops from the beginning.
- If loop columns are omitted, the converter uses `LoopStart` tags when present.
- Loop tag sample positions are converted to the 44.1 kHz BGW output rate when needed.

## Output

The output folder receives:

- `.bgw` files
- `encode-report.csv`
- `encoder-metadata.csv`

Temporary WAV files are created in the system temp folder and deleted automatically. Use `-KeepWorkDir -WorkDir '.\work'` to keep them for inspection.

## Known Limitations

- The converter writes FFXI style BGW music files, but you should test the result in pivot or client setup.
- Loop quality depends on the source `LoopStart` tag or the loop point you provide in CSV.
- Audio is encoded as PlayStation ADPCM, so it is not lossless.
- This does not install BGWs into the game or assign music to zones.

## Release Builds

Create a release zip:

```powershell
.\scripts\Build-Release.ps1
```

Run smoke tests:

```powershell
.\tests\Invoke-SmokeTests.ps1
```

## Advanced

The PowerShell script prepares audio and calls the C# encoder in `src\BgwBulkEncoder`.

If you already have 16-bit stereo 44.1 kHz WAV files, you can call the encoder directly:

```powershell
dotnet run --project '.\src\BgwBulkEncoder\BgwBulkEncoder.csproj' -c Release -- `
  --input '.\input_wav' `
  --out '.\output_bgw' `
  --metadata '.\encoder-metadata.csv' `
  --report '.\encode-report.csv' `
  --clean true
```

Direct encoder CSV:

```csv
music_id,output_file,input_wav,loop_enabled,loop_start_sample
300,music300.bgw,track001.wav,true,0
301,music301.bgw,track002.wav,false,0
```

## License

BGW Converter is licensed under GPL-3.0. See [LICENSE](LICENSE).

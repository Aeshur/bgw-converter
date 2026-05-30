// SPDX-License-Identifier: GPL-3.0-or-later

using System.Globalization;
using System.Text;

var options = ParseArgs(args);
var inputWav = RequireOption(options, "input");
var outDir = RequireOption(options, "out");
var metadataPath = RequireOption(options, "metadata");
var reportPath = RequireOption(options, "report");
var cleanOutput = GetBool(options, "clean", false);

Directory.CreateDirectory(outDir);
var reportParent = Path.GetDirectoryName(reportPath);
if (!string.IsNullOrEmpty(reportParent))
    Directory.CreateDirectory(reportParent);

if (cleanOutput)
{
    foreach (var old in Directory.GetFiles(outDir, "*.bgw"))
        File.Delete(old);
}

var rows = ReadCsv(metadataPath);
var report = new List<Dictionary<string, string>>();
foreach (var row in rows)
{
    var inputWavFile = GetRequired(row, "input_wav");
    var outputFile = GetRequired(row, "output_file");
    var loopStartSample = GetOptional(row, "loop_start_sample", "0");
    var wavPath = Path.Combine(inputWav, inputWavFile);
    var outPath = Path.Combine(outDir, outputFile);
    var outParent = Path.GetDirectoryName(outPath);
    if (!string.IsNullOrEmpty(outParent))
        Directory.CreateDirectory(outParent);

    var loopEnabled = GetBool(row, "loop_enabled", long.TryParse(loopStartSample, out var loopStart) && loopStart > 0);
    var result = EncodeBgw(wavPath, outPath, int.Parse(GetRequired(row, "music_id"), CultureInfo.InvariantCulture), loopStartSample, loopEnabled);
    AddIfPresent(result, row, "album_track");
    AddIfPresent(result, row, "title");
    AddIfPresent(result, row, "english_title");
    result["input_wav"] = inputWavFile;
    report.Add(result);
}

WriteCsv(reportPath, report);
Console.WriteLine($"Encoded {report.Count} BGWs into {outDir}");
Console.WriteLine($"Report: {reportPath}");

static Dictionary<string, string> EncodeBgw(string wavPath, string outPath, int musicId, string loopStartSampleText, bool loopEnabled)
{
    var wav = ReadWavStereo16(wavPath);
    if (wav.SampleRate != 44100)
        throw new InvalidOperationException($"{wavPath} must be 44100 Hz.");

    var usableSamples = Math.Min(wav.Left.Length, wav.Right.Length) / 16 * 16;
    var blockCount = usableSamples / 16;
    var loopValue = 0;
    if (loopEnabled && long.TryParse(loopStartSampleText, out var loopStartSample) && loopStartSample >= 0)
        loopValue = (int)(loopStartSample / 16) + 1;

    using var data = new MemoryStream(blockCount * 18);
    int leftH1 = 0, leftH2 = 0, rightH1 = 0, rightH2 = 0;
    Span<byte> leftFrame = stackalloc byte[9];
    Span<byte> rightFrame = stackalloc byte[9];
    Span<short> samples = stackalloc short[16];

    for (var offset = 0; offset < usableSamples; offset += 16)
    {
        for (var i = 0; i < 16; i++) samples[i] = wav.Left[offset + i];
        EncodeFrame(samples, ref leftH1, ref leftH2, leftFrame);
        data.Write(leftFrame);

        for (var i = 0; i < 16; i++) samples[i] = wav.Right[offset + i];
        EncodeFrame(samples, ref rightH1, ref rightH2, rightFrame);
        data.Write(rightFrame);
    }

    var payload = data.ToArray();
    var fileSize = 0x30 + payload.Length;
    var header = new byte[0x30];
    Encoding.ASCII.GetBytes("BGMStream").CopyTo(header, 0);
    WriteLe32(header, 0x0c, 0);
    WriteLe32(header, 0x10, fileSize);
    WriteLe32(header, 0x14, musicId);
    WriteLe32(header, 0x18, blockCount);
    WriteLe32(header, 0x1c, loopValue);
    WriteLe32(header, 0x20, wav.SampleRate);
    WriteLe32(header, 0x24, 0);
    WriteLe32(header, 0x28, 0x30);
    header[0x2c] = 0x7f;
    header[0x2d] = 0x10;
    header[0x2e] = 0x02;
    header[0x2f] = 0x10;

    using (var output = File.Create(outPath))
    {
        output.Write(header);
        output.Write(payload);
    }

    return new Dictionary<string, string>
    {
        ["file"] = Path.GetFileName(outPath),
        ["music_id"] = musicId.ToString(CultureInfo.InvariantCulture),
        ["bytes"] = fileSize.ToString(CultureInfo.InvariantCulture),
        ["blocks"] = blockCount.ToString(CultureInfo.InvariantCulture),
        ["loop_enabled"] = loopEnabled ? "true" : "false",
        ["loop_header_value"] = loopValue.ToString(CultureInfo.InvariantCulture),
        ["loop_start_sample_requested"] = loopStartSampleText,
        ["loop_start_sample_effective"] = loopValue > 0 ? ((loopValue - 1) * 16).ToString(CultureInfo.InvariantCulture) : "0",
    };
}

static void EncodeFrame(ReadOnlySpan<short> source, ref int hist1, ref int hist2, Span<byte> frame)
{
    ReadOnlySpan<(int c1, int c2)> filters = stackalloc (int, int)[]
    {
        (0, 0),
        (60, 0),
        (115, -52),
        (98, -55),
        (122, -60),
    };

    var bestFilter = 0;
    long bestFilterError = long.MaxValue;
    var bestResidualMax = 0;

    for (var f = 0; f < filters.Length; f++)
    {
        var h1 = hist1;
        var h2 = hist2;
        long error = 0;
        var residualMax = 0;
        var (c1, c2) = filters[f];

        for (var i = 0; i < 16; i++)
        {
            var sample = source[i];
            var predicted = (h1 * c1 + h2 * c2 + 32) >> 6;
            var residual = sample - predicted;
            error += (long)residual * residual;
            residualMax = Math.Max(residualMax, Math.Abs(residual));
            h2 = h1;
            h1 = sample;
        }

        if (error < bestFilterError)
        {
            bestFilterError = error;
            bestFilter = f;
            bestResidualMax = residualMax;
        }
    }

    var baseShift = 12;
    if (bestResidualMax > 7)
    {
        var stepNeeded = Math.Max(1, (int)Math.Ceiling(bestResidualMax / 7.0));
        baseShift = 12 - (int)Math.Ceiling(Math.Log2(stepNeeded));
        baseShift = Math.Clamp(baseShift, 0, 12);
    }

    var bestShift = baseShift;
    Span<int> bestNibbles = stackalloc int[16];
    Span<int> trialNibbles = stackalloc int[16];
    long bestError = long.MaxValue;
    var bestHist1 = hist1;
    var bestHist2 = hist2;
    var (coef1, coef2) = filters[bestFilter];

    for (var shift = Math.Max(0, baseShift - 1); shift <= Math.Min(12, baseShift + 1); shift++)
    {
        var h1 = hist1;
        var h2 = hist2;
        var step = 1 << (12 - shift);
        long error = 0;
        var newHist1 = h1;
        var newHist2 = h2;

        for (var i = 0; i < 16; i++)
        {
            var sample = source[i];
            var predicted = (h1 * coef1 + h2 * coef2 + 32) >> 6;
            var q = (int)Math.Round((sample - predicted) / (double)step, MidpointRounding.AwayFromZero);
            q = Math.Clamp(q, -8, 7);
            var rebuilt = Clamp16(predicted + q * step);
            var diff = sample - rebuilt;
            error += (long)diff * diff;
            trialNibbles[i] = q & 0x0f;
            newHist2 = h1;
            newHist1 = rebuilt;
            h2 = h1;
            h1 = rebuilt;
        }

        if (error < bestError)
        {
            bestError = error;
            bestShift = shift;
            bestHist1 = newHist1;
            bestHist2 = newHist2;
            trialNibbles.CopyTo(bestNibbles);
        }
    }

    frame[0] = (byte)((bestFilter << 4) | bestShift);
    for (var i = 0; i < 16; i += 2)
        frame[1 + i / 2] = (byte)(bestNibbles[i] | (bestNibbles[i + 1] << 4));

    hist1 = bestHist1;
    hist2 = bestHist2;
}

static int Clamp16(int value) => Math.Clamp(value, short.MinValue, short.MaxValue);

static WavData ReadWavStereo16(string path)
{
    var bytes = File.ReadAllBytes(path);
    if (Encoding.ASCII.GetString(bytes, 0, 4) != "RIFF" || Encoding.ASCII.GetString(bytes, 8, 4) != "WAVE")
        throw new InvalidOperationException($"{path} is not a RIFF/WAVE file.");

    var offset = 12;
    ushort channels = 0, bits = 0;
    int rate = 0;
    byte[]? data = null;

    while (offset + 8 <= bytes.Length)
    {
        var id = Encoding.ASCII.GetString(bytes, offset, 4);
        var size = ReadLe32(bytes, offset + 4);
        var chunkStart = offset + 8;

        if (id == "fmt ")
        {
            var format = (ushort)ReadLe16(bytes, chunkStart);
            channels = (ushort)ReadLe16(bytes, chunkStart + 2);
            rate = ReadLe32(bytes, chunkStart + 4);
            bits = (ushort)ReadLe16(bytes, chunkStart + 14);
            if (format != 1) throw new InvalidOperationException($"{path} is not PCM WAV.");
        }
        else if (id == "data")
        {
            data = bytes.Skip(chunkStart).Take(size).ToArray();
        }

        offset = chunkStart + size + (size & 1);
    }

    if (data == null || channels != 2 || bits != 16)
        throw new InvalidOperationException($"{path} must be 16-bit stereo PCM WAV.");

    var sampleCount = data.Length / 4;
    var left = new short[sampleCount];
    var right = new short[sampleCount];
    for (var i = 0; i < sampleCount; i++)
    {
        left[i] = (short)ReadLe16(data, i * 4);
        right[i] = (short)ReadLe16(data, i * 4 + 2);
    }

    return new WavData(rate, left, right);
}

static int ReadLe16(byte[] bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8);
static int ReadLe32(byte[] bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
static void WriteLe32(byte[] bytes, int offset, int value)
{
    bytes[offset + 0] = (byte)(value & 0xff);
    bytes[offset + 1] = (byte)((value >> 8) & 0xff);
    bytes[offset + 2] = (byte)((value >> 16) & 0xff);
    bytes[offset + 3] = (byte)((value >> 24) & 0xff);
}

static List<Dictionary<string, string>> ReadCsv(string path)
{
    var lines = File.ReadAllLines(path);
    if (lines.Length == 0)
        throw new InvalidOperationException($"{path} is empty.");

    var header = ParseCsvLine(lines[0]).ToArray();
    return lines.Skip(1).Where(line => !string.IsNullOrWhiteSpace(line)).Select(line =>
    {
        var values = ParseCsvLine(line).ToArray();
        var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < header.Length; i++)
            row[header[i]] = i < values.Length ? values[i] : "";
        return row;
    }).ToList();
}

static IEnumerable<string> ParseCsvLine(string line)
{
    var value = new StringBuilder();
    var quoted = false;
    for (var i = 0; i < line.Length; i++)
    {
        var ch = line[i];
        if (quoted)
        {
            if (ch == '"')
            {
                if (i + 1 < line.Length && line[i + 1] == '"')
                {
                    value.Append('"');
                    i++;
                }
                else
                {
                    quoted = false;
                }
            }
            else value.Append(ch);
        }
        else
        {
            if (ch == '"') quoted = true;
            else if (ch == ',')
            {
                yield return value.ToString();
                value.Clear();
            }
            else value.Append(ch);
        }
    }
    yield return value.ToString();
}

static void WriteCsv(string path, List<Dictionary<string, string>> rows)
{
    var headers = rows.SelectMany(row => row.Keys).Distinct().ToArray();
    using var writer = new StreamWriter(path, false, Encoding.UTF8);
    writer.WriteLine(string.Join(",", headers.Select(CsvEscape)));
    foreach (var row in rows)
        writer.WriteLine(string.Join(",", headers.Select(header => CsvEscape(row.TryGetValue(header, out var value) ? value : ""))));
}

static string CsvEscape(string value) => '"' + value.Replace("\"", "\"\"") + '"';

static bool GetBool(Dictionary<string, string> row, string key, bool fallback)
{
    if (!row.TryGetValue(key, out var value) || string.IsNullOrWhiteSpace(value))
        return fallback;
    return value.Equals("true", StringComparison.OrdinalIgnoreCase)
        || value.Equals("yes", StringComparison.OrdinalIgnoreCase)
        || value.Equals("1", StringComparison.OrdinalIgnoreCase);
}

static string GetRequired(Dictionary<string, string> row, params string[] keys)
{
    foreach (var key in keys)
    {
        if (row.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
            return value;
    }

    throw new InvalidOperationException($"Missing required metadata column/value. Expected one of: {string.Join(", ", keys)}");
}

static string GetOptional(Dictionary<string, string> row, string key, string fallback) =>
    row.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value : fallback;

static void AddIfPresent(Dictionary<string, string> target, Dictionary<string, string> source, string key)
{
    if (source.TryGetValue(key, out var value))
        target[key] = value;
}

static Dictionary<string, string> ParseArgs(string[] args)
{
    var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    for (var i = 0; i < args.Length; i++)
    {
        var arg = args[i];
        if (!arg.StartsWith("--", StringComparison.Ordinal)) continue;

        var key = arg[2..];
        if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
            throw new ArgumentException($"Missing value for {arg}.");

        options[key] = args[++i];
    }
    return options;
}

static string RequireOption(Dictionary<string, string> options, string key)
{
    if (options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
        return value;

    throw new ArgumentException($"Missing required option --{key}. Required: --input <wav-dir> --out <bgw-dir> --metadata <csv> --report <csv>");
}

record WavData(int SampleRate, short[] Left, short[] Right);

using System.Text.Json;
using System.Text.Json.Serialization;
using ScriptIX.Mvvm;

namespace ScriptIX;

/// <summary>A picture kept as bytes, so a moved or deleted file never breaks the report.</summary>
public sealed class ReportImage : ObservableObject
{
    public const long MaxBytes = 4 * 1024 * 1024;

    string caption = "";
    public string Name { get; set; } = "";
    public byte[] Data { get; set; } = Array.Empty<byte>();
    public string Caption { get => caption; set => Set(ref caption, value ?? ""); }

    /// <summary>Type taken from the bytes, never from the file name. Null when it isn't a supported picture.</summary>
    [JsonIgnore] public string? Mime => Sniff(Data);

    public static string? Sniff(byte[] d)
    {
        bool At(int i, params byte[] sig) => d.Length >= i + sig.Length && d.AsSpan(i, sig.Length).SequenceEqual(sig);
        if (At(0, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) return "image/png";
        if (At(0, 0xFF, 0xD8, 0xFF)) return "image/jpeg";
        if (At(0, 0x47, 0x49, 0x46, 0x38)) return "image/gif";
        if (At(0, 0x42, 0x4D)) return "image/bmp";
        return null;
    }

    public static ReportImage Load(IFileService files, string path)
    {
        if (files.Size(path) > MaxBytes)
            throw new FormatException($"That picture is bigger than {MaxBytes / 1024 / 1024} MB. Pick a smaller one.");
        using var s = files.OpenRead(path);
        using var m = new MemoryStream();
        s.CopyTo(m);
        var img = new ReportImage { Name = Path.GetFileName(path), Data = m.ToArray() };
        if (img.Mime == null) throw new FormatException("That isn't a picture ScriptIX can use. Pick a PNG, JPG, GIF or BMP file.");
        return img;
    }
}

public sealed class ReportDetails
{
    public string Title { get; set; } = "";
    /// <summary>One name per line.</summary>
    public string Names { get; set; } = "";
    public string Organization { get; set; } = "";
    public string Notes { get; set; } = "";
    public ReportImage? Logo { get; set; }
    public List<ReportImage> Pictures { get; set; } = new();

    [JsonIgnore]
    public string NamesText => string.Join(", ", (Names ?? "").Split('\n').Select(n => n.Trim().TrimEnd(',', ';')).Where(n => n.Length > 0));
}

/// <summary>Remembers the report details between sessions.</summary>
public sealed class ReportDetailsStore
{
    readonly IFileService files;
    readonly string path;

    public ReportDetailsStore(IFileService files, string? path = null)
    {
        this.files = files;
        this.path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptIX", "report.json");
    }

    public ReportDetails Load()
    {
        try
        {
            var d = files.Exists(path) ? JsonSerializer.Deserialize<ReportDetails>(files.ReadAllText(path)) : null;
            if (d == null) return new ReportDetails();
            if (d.Logo?.Mime == null) d.Logo = null;
            d.Pictures = (d.Pictures ?? new()).Where(p => p?.Mime != null).ToList();
            return d;
        }
        catch (Exception) { return new ReportDetails(); }   // a damaged file only means empty details
    }

    public void Save(ReportDetails d) => files.WriteAllText(path, JsonSerializer.Serialize(d));
}

using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Xml;

namespace ScriptIX;

public enum Choice { Yes, No, Cancel }

public interface IFileService
{
    string ReadAllText(string path);
    Stream OpenRead(string path);
    string ReadFirstLine(string path);
    void WriteAllText(string path, string content);
    void WriteAllBytes(string path, byte[] content);
    bool Exists(string path);
    long Size(string path);
}

public interface IDialogService
{
    string? PickFile(string filter, string title = "Open");
    string? PickSavePath(string suggestedName, string filter);
    string? PickFolder(string title);
    void Message(string text);
    bool Confirm(string text);
    Choice AskYesNoCancel(string text);
}

public interface IClipboardService { void SetText(string text); }
public interface ICrashLog { void Write(string action, Exception ex); string Location { get; } }
public interface IShell
{
    void OpenFolder(string path);
    void OpenFile(string path);
    /// <summary>Runs a batch file ScriptIX wrote, in a normal console window.</summary>
    void RunInWindow(string batchFile);
    /// <summary>Prints HTML to PDF bytes with the PC's own browser. Throws FormatException when none can do it.</summary>
    byte[] HtmlToPdf(string html, CancellationToken ct);
}

public sealed record AppServices(IDialogService Dialogs, IFileService Files, IClipboardService Clipboard,
                                 ICrashLog Crash, IShell Shell);

public sealed class DiskFileService : IFileService
{
    static readonly UTF8Encoding Utf8NoBom = new(false);

    public string ReadAllText(string path) => File.ReadAllText(path);
    public Stream OpenRead(string path) => new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan);
    public bool Exists(string path) => File.Exists(path);
    public long Size(string path) => new FileInfo(path).Length;

    public string ReadFirstLine(string path)
    {
        using var r = new StreamReader(path);
        return r.ReadLine() ?? "";
    }

    // Temp file + replace, so a crash or a second instance can't leave a half-written file.
    public void WriteAllText(string path, string content) => WriteAllBytes(path, Utf8NoBom.GetBytes(content));

    public void WriteAllBytes(string path, byte[] content)
    {
        var full = Path.GetFullPath(path);
        var dir = Path.GetDirectoryName(full);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = full + "." + Environment.ProcessId + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp";
        try
        {
            File.WriteAllBytes(tmp, content);
            File.Move(tmp, full, true);
        }
        finally
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch (IOException) { }
        }
    }
}

public sealed class FileCrashLog : ICrashLog
{
    const long MaxBytes = 1024 * 1024;
    readonly string path;

    public FileCrashLog(string? path = null) =>
        this.path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptIX", "logs", "crash_log.txt");

    public string Location => path;

    public void Write(string action, Exception ex)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > MaxBytes) File.Move(path, path + ".old", true);
            File.AppendAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {AppInfo.Name} {AppInfo.Version} action: {action}{Environment.NewLine}{ex}{Environment.NewLine}{Environment.NewLine}");
        }
        catch (Exception) { /* logging must never crash the app */ }
    }
}

public static class Errors
{
    public static string Describe(Exception ex, string action) => ex switch
    {
        OperationCanceledException => "Cancelled.",
        UnauthorizedAccessException => $"Windows blocked access while {action}. Pick a file or folder you have rights to.",
        FileNotFoundException or DirectoryNotFoundException => $"The file wasn't found while {action}. Check that it still exists and try again.",
        PathTooLongException => $"The path is too long while {action}. Use a shorter folder name.",
        IOException io when (io.HResult & 0xFFFF) is 0x70 or 0x27 => $"The disk is full while {action}. Free some space and try again.",
        IOException => $"The file is in use by another program while {action}. Close it there and try again.",
        XmlException x => $"That XML file can't be read safely ({x.Message}). It may be damaged, or it uses a DTD, which ScriptIX refuses for safety.",
        JsonException j => $"That JSON file isn't valid ({j.Message}). Check it and try again.",
        FormatException => $"{ex.Message}",
        OutOfMemoryException => $"The file is too big to load while {action}.",
        _ => $"Something went wrong while {action}. Your work is safe. Details were saved to the crash log."
    };
}

public sealed class AutosaveState
{
    public string ManualText { get; set; } = "";
    public List<RuleItem> Rules { get; set; } = new();
    public bool StopOnFail { get; set; }
    public int TimeoutSeconds { get; set; } = 60;
    public bool Redact { get; set; } = true;
}

/// Saves the user's work a couple of seconds after the last change, so a crash never loses it.
public sealed class AutosaveService
{
    static readonly JsonSerializerOptions Json = new() { Converters = { new JsonStringEnumConverter() } };

    readonly IFileService files;
    readonly string path;
    readonly SynchronizationContext? ctx = SynchronizationContext.Current;
    Timer? timer;
    Func<AutosaveState>? snapshot;

    public AutosaveService(IFileService files, string? path = null)
    {
        this.files = files;
        this.path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptIX", "autosave.json");
    }

    public void Request(Func<AutosaveState> snap)
    {
        snapshot = snap;
        timer ??= new Timer(_ => { if (ctx != null) ctx.Post(__ => Flush(), null); else Flush(); },
                            null, Timeout.Infinite, Timeout.Infinite);
        timer.Change(2000, Timeout.Infinite);
    }

    public void Flush()
    {
        try
        {
            var s = snapshot?.Invoke();
            if (s != null) files.WriteAllText(path, JsonSerializer.Serialize(s, Json));
        }
        catch (Exception) { /* autosave is best effort */ }
    }

    public AutosaveState? Load()
    {
        try
        {
            return files.Exists(path) ? JsonSerializer.Deserialize<AutosaveState>(files.ReadAllText(path), Json) : null;
        }
        catch (Exception) { return null; }
    }
}

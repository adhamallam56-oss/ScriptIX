using System.Diagnostics;
using System.Windows;
using Microsoft.Win32;

namespace ScriptIX.App.Services;

public sealed class WpfDialogService : IDialogService
{
    static Window? Owner => Application.Current?.MainWindow is { IsVisible: true } w ? w : null;

    public string? PickFile(string filter, string title = "Open")
    {
        var dlg = new OpenFileDialog { Filter = filter, Title = title };
        return dlg.ShowDialog(Owner) == true ? dlg.FileName : null;
    }

    public string? PickSavePath(string suggestedName, string filter)
    {
        var dlg = new SaveFileDialog { Filter = filter, FileName = suggestedName, OverwritePrompt = true };
        return dlg.ShowDialog(Owner) == true ? dlg.FileName : null;
    }

    public string? PickFolder(string title)
    {
        var dlg = new OpenFolderDialog { Title = title };
        return dlg.ShowDialog(Owner) == true ? dlg.FolderName : null;
    }

    public void Message(string text) => Show(text, MessageBoxButton.OK, MessageBoxImage.Information);

    public bool Confirm(string text) =>
        Show(text, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;

    public Choice AskYesNoCancel(string text) =>
        Show(text, MessageBoxButton.YesNoCancel, MessageBoxImage.Question) switch
        {
            MessageBoxResult.Yes => Choice.Yes,
            MessageBoxResult.No => Choice.No,
            _ => Choice.Cancel
        };

    static MessageBoxResult Show(string text, MessageBoxButton b, MessageBoxImage i) =>
        Owner is { } o ? MessageBox.Show(o, text, AppInfo.Name, b, i) : MessageBox.Show(text, AppInfo.Name, b, i);
}

public sealed class WpfClipboardService : IClipboardService
{
    public void SetText(string text) => Clipboard.SetDataObject(text, true);
}

/// Opens Explorer or the default app. Only for files ScriptIX itself wrote or its own folders.
public sealed class WindowsShell : IShell
{
    public void OpenFolder(string path) =>
        Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { path }, UseShellExecute = false });

    public void OpenFile(string path) =>
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    public void RunInWindow(string batchFile) =>
        Process.Start(new ProcessStartInfo(batchFile) { UseShellExecute = true, WorkingDirectory = System.IO.Path.GetDirectoryName(batchFile)! });

    /// Edge ships with Windows; Chrome works the same way. The page is our own HTML: no scripts, no external links.
    public byte[] HtmlToPdf(string html, CancellationToken ct)
    {
        var exe = new[] { Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.LocalApplicationData }
            .SelectMany(f => new[] { @"Microsoft\Edge\Application\msedge.exe", @"Google\Chrome\Application\chrome.exe" }
                .Select(x => System.IO.Path.Combine(Environment.GetFolderPath(f), x)))
            .FirstOrDefault(System.IO.File.Exists)
            ?? throw new FormatException("PDF export needs Microsoft Edge or Google Chrome on this PC. Export as Word or HTML instead.");

        var dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ScriptIX", "pdf_" + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(dir);
        try
        {
            var page = System.IO.Path.Combine(dir, "report.html");
            var pdf = System.IO.Path.Combine(dir, "report.pdf");
            System.IO.File.WriteAllText(page, html, new System.Text.UTF8Encoding(false));
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "--headless", "--disable-gpu", "--disable-extensions", "--no-first-run", "--no-default-browser-check",
                                      "--no-pdf-header-footer", "--print-to-pdf-no-header", "--user-data-dir=" + System.IO.Path.Combine(dir, "profile"),
                                      "--print-to-pdf=" + pdf, new Uri(page).AbsoluteUri })
                psi.ArgumentList.Add(a);
            using var p = Process.Start(psi) ?? throw new FormatException("The browser could not be started to make the PDF. Export as Word or HTML instead.");
            var until = DateTime.UtcNow.AddSeconds(120);
            while (!p.WaitForExit(200))
            {
                if (!ct.IsCancellationRequested && DateTime.UtcNow < until) continue;
                try { p.Kill(true); } catch (InvalidOperationException) { }
                ct.ThrowIfCancellationRequested();
                throw new FormatException("Making the PDF took too long. Export as Word or HTML instead.");
            }
            var data = System.IO.File.Exists(pdf) ? System.IO.File.ReadAllBytes(pdf) : Array.Empty<byte>();
            if (data.Length < 5 || data[0] != '%' || data[1] != 'P')
                throw new FormatException("The browser did not make a PDF (company settings may block it). Export as Word or HTML instead.");
            return data;
        }
        finally
        {
            // the browser can hold its profile for a moment after it exits
            for (int i = 0; i < 10 && System.IO.Directory.Exists(dir); i++)
                try { System.IO.Directory.Delete(dir, true); }
                catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException) { Thread.Sleep(200); }
        }
    }
}

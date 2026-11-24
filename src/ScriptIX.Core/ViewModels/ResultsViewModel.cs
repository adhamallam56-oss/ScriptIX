using ScriptIX.Mvvm;
using ScriptIX.Scap;

namespace ScriptIX.ViewModels;

public sealed class ResultsViewModel : ViewModelBase
{
    public const string FilterAll = "All", FilterFailed = "Failed", FilterPassed = "Passed", FilterSkipped = "Skipped", FilterChanged = "Changed",
                        AsScanned = "As scanned";

    List<ResultRow> rows = new();
    IReadOnlyList<ResultRow> visibleRows = Array.Empty<ResultRow>();
    ResultSummary summary = new(0, 0, 0, 0);
    ResultRow? selectedRow;
    string filter = FilterAll, search = "", sourcePath = "", host = "", when = "";

    public System.Collections.ObjectModel.ObservableCollection<string> Filters { get; } = new() { FilterAll, FilterFailed, FilterPassed, FilterSkipped };
    public IReadOnlyList<string> Answers { get; } = new[] { AsScanned, "PASS", "FAIL", "NOT-APPLICABLE", "WAIVED" };
    /// <summary>The SCAP content open on the Rules page, for scores and XCCDF/ARF files.</summary>
    public Func<(XccdfDocument? Doc, XccdfProfile? Profile)>? ScapContext { get; set; }
    public AsyncRelayCommand CompareCommand { get; }
    bool compared;
    IReadOnlyList<ScapScore> scores = Array.Empty<ScapScore>();
    public AsyncRelayCommand OpenCommand { get; }
    public RelayCommand FixFailedCommand { get; }
    public RelayCommand RerunFailedCommand { get; }
    public AsyncRelayCommand ExportCommand { get; }
    public RelayCommand CopyHistoryCommand { get; }
    public RelayCommand SaveHistoryCommand { get; }
    public ReportDetailsViewModel Details { get; }

    /// bool: true = use the rules' fix commands, false = re-run the exact commands.
    public event Action? Opened;
    public event Action<IReadOnlyList<ResultRow>, bool>? FixRequested;

    public ResultsViewModel(AppServices s) : base(s)
    {
        Details = new ReportDetailsViewModel(s);
        OpenCommand = new AsyncRelayCommand((p, ct) => OpenAsync(p as string, ct));
        FixFailedCommand = new RelayCommand(() => FixRequested?.Invoke(Failed(), true), () => summary.Failed > 0);
        RerunFailedCommand = new RelayCommand(() => FixRequested?.Invoke(Failed(), false), () => summary.Failed > 0);
        ExportCommand = new AsyncRelayCommand((p, ct) => ExportAsync(p as string ?? "html", ct), () => rows.Count > 0);
        CopyHistoryCommand = new RelayCommand(() =>
        {
            if (Safe("copying the history", () => S.Clipboard.SetText(ResultsParser.HistoryText(rows)))) Status("History copied.");
        }, () => rows.Count > 0);
        SaveHistoryCommand = new RelayCommand(SaveHistory, () => rows.Count > 0);
        CompareCommand = new AsyncRelayCommand((p, ct) => CompareAsync(p as string, ct), () => rows.Count > 0);
    }

    (XccdfDocument? Doc, XccdfProfile? Profile) Context()
    {
        var (doc, profile) = ScapContext?.Invoke() ?? (null, null);
        return doc is { Prebuilt: null } && ScapResults.Fits(rows, doc) ? (doc, profile) : (null, null);
    }

    // ---------- score ----------
    public bool HasScore => scores.Count > 0 && summary.Passed + summary.Failed > 0;
    public string ScoreText => scores.Count == 0 ? "" : scores[0].Percent.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "%";
    public string ScoreTip => "XCCDF scores\n" + string.Join("\n", scores.Select(s => FormattableString.Invariant($"{s.Name}: {s.Score:0.##} of {s.Maximum:0.##}")));

    public void Count()
    {
        Summary = ResultsParser.Summarize(rows);
        var (doc, profile) = Context();
        scores = doc == null ? Array.Empty<ScapScore>() : ScapResults.Scores(rows, doc, profile);
        foreach (var n in new[] { nameof(HasScore), nameof(ScoreText), nameof(ScoreTip), nameof(HasFailures) }) OnPropertyChanged(n);
        FixFailedCommand.RaiseCanExecuteChanged();
        RerunFailedCommand.RaiseCanExecuteChanged();
    }

    // ---------- a result changed by hand ----------
    public string Answer
    {
        get => selectedRow is { OverrideText.Length: > 0 } r ? r.OverrideText : AsScanned;
        set
        {
            if (selectedRow is not { } row || value == null || value == Answer) return;
            row.Override(value == AsScanned ? "" : value);
            Count();
            Rebuild(row);
            selectedRow = null;   // the same row again: make the details redraw
            OnPropertyChanged(nameof(SelectedRow));
            selectedRow = row;
            OnPropertyChanged(nameof(SelectedRow));
            OnPropertyChanged();
        }
    }
    public string AnswerReason
    {
        get => selectedRow?.Reason ?? "";
        set { if (selectedRow is { } row && row.Reason != (value ?? "")) { row.Reason = value ?? ""; OnPropertyChanged(); } }
    }

    // ---------- compare two runs ----------
    public bool IsCompared
    {
        get => compared;
        private set
        {
            if (!Set(ref compared, value)) return;
            if (value) Filters.Add(FilterChanged); else Filters.Remove(FilterChanged);
        }
    }

    Task CompareAsync(string? path, CancellationToken ct)
    {
        path ??= S.Dialogs.PickFile("Results (*.csv, *.xml)|*.csv;*.xml|All files|*.*", "Pick the older results");
        return path == null ? Task.CompletedTask : SafeAsync("comparing the results", async () =>
        {
            var old = await Task.Run(() => Read(path, ct).Rows, ct);
            var (good, bad, other) = ResultsCompare.Apply(rows, old);
            int gone = old.Count(o => rows.All(r => r.Id != o.Id));
            IsCompared = true;
            filter = FilterChanged;
            OnPropertyChanged(nameof(Filter));
            Rebuild();
            Status($"Compared with {Path.GetFileName(path)}: {good} now pass, {bad} now fail, {other} other change(s)" + (gone > 0 ? $", {gone} only in the old run." : "."));
        });
    }

    (List<ResultRow> Rows, string Name) Read(string path, CancellationToken ct)
    {
        if (!Path.GetExtension(path).Equals(".xml", StringComparison.OrdinalIgnoreCase)) return (ResultsParser.Parse(S.Files.ReadAllText(path)), path);
        using var st = S.Files.OpenRead(path);
        var l = ScapResults.Read(st, ct);
        return (l.Rows, ScapResults.SourceName(l, path));
    }

    List<ResultRow> Failed() => rows.Where(r => r.Result == "FAIL").ToList();

    public IReadOnlyList<ResultRow> VisibleRows { get => visibleRows; private set => Set(ref visibleRows, value); }
    public ResultRow? SelectedRow { get => selectedRow; set { if (Set(ref selectedRow, value)) { OnPropertyChanged(nameof(HasSelection)); OnPropertyChanged(nameof(Answer)); OnPropertyChanged(nameof(AnswerReason)); } } }
    public bool HasSelection => selectedRow != null;
    public ResultSummary Summary { get => summary; private set => Set(ref summary, value); }
    public bool HasRows => rows.Count > 0;
    public bool IsEmpty => rows.Count == 0;
    public bool HasFailures => summary.Failed > 0;
    string shownName = "";
    public string SourceName => shownName;
    public string RunInfo => host.Length > 0 ? $"Host {host} · run {when} · {SourceName}" : SourceName;

    public string Filter { get => filter; set { if (Set(ref filter, value ?? FilterAll)) Rebuild(); } }
    public string Search { get => search; set { if (Set(ref search, value ?? "")) Rebuild(); } }

    public void Load(IEnumerable<ResultRow> newRows, string path, string? shown = null)
    {
        shownName = Path.GetFileName(shown ?? path);
        rows = newRows.ToList();
        sourcePath = path;
        (host, when) = ResultsParser.Describe(path);
        CompareCommand.RaiseCanExecuteChanged();
        Count();
        filter = summary.Failed > 0 ? FilterFailed : FilterAll;
        OnPropertyChanged(nameof(Filter));
        IsCompared = false;
        Rebuild();
        foreach (var n in new[] { nameof(HasRows), nameof(IsEmpty), nameof(HasFailures), nameof(SourceName), nameof(RunInfo) })
            OnPropertyChanged(n);
        ExportCommand.RaiseCanExecuteChanged();
        CopyHistoryCommand.RaiseCanExecuteChanged();
        SaveHistoryCommand.RaiseCanExecuteChanged();
        Status($"{summary.Total} results loaded: {summary.Passed} passed, {summary.Failed} failed, {summary.Skipped} skipped.");
    }

    void Rebuild(ResultRow? keep = null)
    {
        var q = search.Trim();
        VisibleRows = rows.Where(r => r == keep || filter switch   // a row just answered stays in view
            {
                FilterFailed => r.Result == "FAIL",
                FilterPassed => r.Result == "PASS",
                FilterSkipped => r.Result == "SKIPPED",
                FilterChanged => r.Changed,
                _ => true
            })
            .Where(r => q.Length == 0 || r.Id.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                        r.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                        r.Command.Contains(q, StringComparison.OrdinalIgnoreCase))
            .ToList();
        SelectedRow = keep != null && VisibleRows.Contains(keep) ? keep : VisibleRows.FirstOrDefault();
    }

    async Task OpenAsync(string? path, CancellationToken ct)
    {
        path ??= S.Dialogs.PickFile("Results (*.csv, *.xml)|*.csv;*.xml|All files|*.*", "Open results: a ScriptIX .csv, or XCCDF, ARF or OVAL results");
        if (path == null) return;
        await SafeAsync("opening the results", async () =>
        {
            var (list, name) = await Task.Run(() => Read(path, ct), ct);
            Load(list, name, path);
            Opened?.Invoke();
        });
    }

    static readonly (string Ext, string Filter)[] Formats =
    {
        ("pdf", "PDF (*.pdf)|*.pdf"), ("docx", "Word (*.docx)|*.docx"), ("xlsx", "Excel (*.xlsx)|*.xlsx"), ("html", "HTML (*.html)|*.html"),
        ("md", "Markdown (*.md)|*.md"), ("txt", "Text (*.txt)|*.txt"), ("csv", "CSV (*.csv)|*.csv"), ("json", "JSON (*.json)|*.json")
    };
    static readonly (string Ext, string Filter)[] ScapFormats =
    {
        ("xccdf", "XCCDF 1.2 results (*.xml)|*.xml"), ("arf", "ARF results (*.xml)|*.xml")
    };

    Task ExportAsync(string format, CancellationToken ct) => SafeAsync("exporting the report", async () =>
    {
        var name = Path.GetFileNameWithoutExtension(sourcePath);
        var stem = name.StartsWith("results_", StringComparison.Ordinal) ? "report_" + name[8..] : "report";
        var data = new ReportData(rows, sourcePath, DateTime.Now, Details.Snapshot());
        Details.Save();

        if (format == "all")
        {
            var dir = S.Dialogs.PickFolder("Pick a folder for the reports");
            if (dir == null) return;
            var targets = Formats.Select(f => (f.Ext, Path: Path.Combine(dir, stem + "." + f.Ext))).ToList();
            var existing = targets.Where(t => S.Files.Exists(t.Path)).Select(t => Path.GetFileName(t.Path)).ToList();
            if (existing.Count > 0 && !S.Dialogs.Confirm($"These files already exist and will be replaced:\n\n{string.Join("\n", existing)}\n\nContinue?")) return;
            Status("Exporting all formats...");
            string? pdfProblem = null;
            await Task.Run(() =>
            {
                foreach (var t in targets)
                {
                    ct.ThrowIfCancellationRequested();
                    try { Write(data, t.Ext, t.Path, ct); }
                    catch (FormatException ex) when (t.Ext == "pdf") { pdfProblem = ex.Message; }   // the other formats don't need a browser
                }
            }, ct);
            Status(pdfProblem == null ? $"Saved {targets.Count} reports to {dir}" : $"Saved {targets.Count - 1} reports to {dir}. No PDF: {pdfProblem}");
            S.Shell.OpenFolder(dir);
            return;
        }

        if (ScapFormats.Any(x => x.Ext == format))
        {
            var to = S.Dialogs.PickSavePath($"{stem}_{format}.xml", ScapFormats.First(x => x.Ext == format).Filter);
            if (to == null) return;
            var (doc, profile) = Context();
            await Task.Run(() => S.Files.WriteAllText(to, format == "arf"
                ? ScapResults.Arf(data.Rows, doc, profile, data.SourceFile, data.Generated, data.Details)
                : ScapResults.Xccdf(data.Rows, doc, profile, data.SourceFile, data.Generated, data.Details)), ct);
            Status($"Saved {Path.GetFileName(to)}." + (doc == null ? " Open the SCAP content on the Rules page first to put the benchmark in the file too." : ""));
            return;
        }
        var f = Formats.First(x => x.Ext == format);
        var path = S.Dialogs.PickSavePath($"{stem}.{f.Ext}", f.Filter);
        if (path == null) return;
        Status($"Saving {Path.GetFileName(path)}...");
        await Task.Run(() => Write(data, f.Ext, path, ct), ct);
        Status($"Report saved: {Path.GetFileName(path)}");
        S.Shell.OpenFile(path);
    });

    void Write(ReportData d, string ext, string path, CancellationToken ct)
    {
        string Html() => HtmlReport.Build(d.Rows, d.SourceFile, d.Generated, d.Details);
        switch (ext)
        {
            case "pdf": S.Files.WriteAllBytes(path, S.Shell.HtmlToPdf(Html(), ct)); break;
            case "docx": S.Files.WriteAllBytes(path, ReportExport.Docx(d)); break;
            case "xlsx": S.Files.WriteAllBytes(path, ReportExport.Xlsx(d)); break;
            case "html": S.Files.WriteAllText(path, Html()); break;
            case "md":
                // Markdown can't hold pictures, so they go in a folder next to the file
                var assets = Path.GetFileNameWithoutExtension(path) + "_files";
                foreach (var (n, bytes) in ReportExport.MarkdownAssets(d))
                    S.Files.WriteAllBytes(Path.Combine(Path.GetDirectoryName(path)!, assets, n), bytes);
                S.Files.WriteAllText(path, ReportExport.Markdown(d, assets));
                break;
            case "txt": S.Files.WriteAllText(path, ReportExport.Text(d)); break;
            case "csv": S.Files.WriteAllText(path, "\uFEFF" + ReportExport.CsvText(d)); break;   // BOM so Excel reads UTF-8
            case "json": S.Files.WriteAllText(path, ReportExport.Json(d)); break;
        }
    }

    void SaveHistory() => Safe("saving the history", () =>
    {
        var path = S.Dialogs.PickSavePath("history.txt", "Text (*.txt)|*.txt");
        if (path == null) return;
        S.Files.WriteAllText(path, ResultsParser.HistoryText(rows));
        Status($"History saved: {Path.GetFileName(path)}");
    });
}

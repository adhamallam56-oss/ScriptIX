using ScriptIX.Mvvm;
using ScriptIX.Scap;

namespace ScriptIX.ViewModels;

/// <summary>One XCCDF value the user can change.</summary>
public sealed class ValueRow : ObservableObject
{
    string text = "";
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string Description { get; init; } = "";
    public string Original { get; init; } = "";
    public IReadOnlyList<string> Choices { get; init; } = Array.Empty<string>();
    public string Text { get => text; set { if (Set(ref text, value ?? "")) OnPropertyChanged(nameof(IsChanged)); } }
    public bool IsChanged => Text != Original;
}

/// <summary>The SCAP menu of the Rules page.</summary>
public sealed class ScapViewModel : ViewModelBase
{
    readonly RulesViewModel rules;
    List<ValueRow> allValues = new();
    IReadOnlyList<ValueRow> values = Array.Empty<ValueRow>();
    string panel = "", panelTitle = "", panelText = "", search = "", vector = "", score = "";

    public AsyncRelayCommand InfoCommand { get; }
    public RelayCommand ValuesCommand { get; }
    public AsyncRelayCommand ApplyValuesCommand { get; }
    public RelayCommand ResetValuesCommand { get; }
    public AsyncRelayCommand LoadTailoringCommand { get; }
    public RelayCommand SaveTailoringCommand { get; }
    public AsyncRelayCommand GuideCommand { get; }
    public RelayCommand FixCommand { get; }
    public AsyncRelayCommand CheckContentCommand { get; }
    public RelayCommand CvssCommand { get; }
    public RelayCommand OscapCommand { get; }
    public RelayCommand CopyTextCommand { get; }
    public RelayCommand CloseCommand { get; }

    /// Raised with a job that runs the server's own oscap.
    public event Action<ScriptJob>? ScriptRequested;

    public ScapViewModel(AppServices s, RulesViewModel rules) : base(s)
    {
        this.rules = rules;
        InfoCommand = new AsyncRelayCommand((_, ct) => SafeAsync("reading the SCAP file", async () =>
        {
            if (Doc is not { } doc) return;
            Show("text", "SCAP info", await Task.Run(() => ScapExport.Info(doc), ct));
        }));
        ValuesCommand = new RelayCommand(OpenValues);
        ApplyValuesCommand = new AsyncRelayCommand((_, ct) => ApplyValues(ct));
        ResetValuesCommand = new RelayCommand(() => { foreach (var v in allValues) v.Text = v.Original; });
        LoadTailoringCommand = new AsyncRelayCommand((p, ct) => LoadTailoring(p as string, ct));
        SaveTailoringCommand = new RelayCommand(SaveTailoring);
        GuideCommand = new AsyncRelayCommand((_, ct) => SafeAsync("making the guide", async () =>
        {
            if (Doc is not { } doc) return;
            var path = S.Dialogs.PickSavePath("guide.html", "HTML (*.html)|*.html");
            if (path == null) return;
            var ids = rules.ProfileIds(); var p = rules.SelectedProfile;
            await Task.Run(() => S.Files.WriteAllText(path, ScapExport.Guide(doc, p, ids, DateTime.Now)), ct);
            Status($"Guide saved: {Path.GetFileName(path)}");
            S.Shell.OpenFile(path);
        }));
        FixCommand = new RelayCommand(p => Safe("exporting the fixes", () =>
        {
            if (Doc is not { } doc || p is not string kind) return;
            var (_, name, ext) = ScapExport.FixKinds.First(k => k.Kind == kind);
            var text = ScapExport.Fixes(doc, rules.SelectedProfile, kind, rules.ProfileIds());
            var path = S.Dialogs.PickSavePath($"fixes.{ext}", $"{name} (*.{ext})|*.{ext}|All files|*.*");
            if (path == null) return;
            S.Files.WriteAllText(path, text);
            Status($"Fixes saved: {Path.GetFileName(path)}. This file has no backup or undo; the ScriptIX apply script has.");
        }));
        CheckContentCommand = new AsyncRelayCommand((_, ct) => SafeAsync("checking the content", async () =>
        {
            if (Doc == null || rules.ScapPath.Length == 0) return;
            var file = rules.ScapPath;
            var bad = await Task.Run(() =>
            {
                using var st = S.Files.OpenRead(file);
                var dir = Path.GetDirectoryName(file)!;
                return ScapExport.Validate(st, n => S.Files.Exists(Path.Combine(dir, n)) ? S.Files.OpenRead(Path.Combine(dir, n)) : null, ct);
            }, ct);
            Show("text", "Content check", bad.Count == 0 ? "No problems found." : $"{bad.Count} problem(s):\n\n" + string.Join("\n", bad.Take(500)));
        }));
        CvssCommand = new RelayCommand(() => Show("cvss", "CVSS score", ""));
        OscapCommand = new RelayCommand(() =>
        {
            if (Doc is not { } doc) return;
            if (rules.SelectedProfile is { Tailored: true })
            {
                S.Dialogs.Message("This profile comes from a tailoring file. Copy the tailoring file next to the script and add --tailoring-file to its oscap line, or pick one of the benchmark's own profiles.");
                return;
            }
            ScriptRequested?.Invoke(new ScriptJob("scriptix_oscap.sh", "oscap", new[] { ScapExport.OscapCommand(doc, rules.SelectedProfile, Path.GetFileName(rules.ScapPath)) },
                                                  true, true, "Scans with the server's own oscap; changes nothing"));
        });
        CopyTextCommand = new RelayCommand(() => { if (Safe("copying", () => S.Clipboard.SetText(panelText))) Status("Copied."); });
        CloseCommand = new RelayCommand(() => Panel = "");
    }

    XccdfDocument? Doc => rules.HasScap ? rules.Scap : null;

    string Panel
    {
        get => panel;
        set
        {
            if (!Set(ref panel, value)) return;
            foreach (var n in new[] { nameof(IsOpen), nameof(ShowText), nameof(ShowValues), nameof(ShowCvss) }) OnPropertyChanged(n);
        }
    }
    public bool IsOpen => panel.Length > 0;
    public bool ShowText => panel == "text";
    public bool ShowValues => panel == "values";
    public bool ShowCvss => panel == "cvss";
    public string PanelTitle { get => panelTitle; private set => Set(ref panelTitle, value); }
    public string PanelText { get => panelText; private set => Set(ref panelText, value); }

    void Show(string what, string title, string text) { PanelTitle = title; PanelText = text; Panel = what; }

    // ---------- CVSS ----------
    public string Vector
    {
        get => vector;
        set
        {
            if (!Set(ref vector, value ?? "")) return;
            if (vector.Trim().Length == 0) { Score = ""; return; }
            try
            {
                var c = Cvss.Score(vector);
                static string N(double d) => d.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
                Score = $"{N(c.Overall)}  {c.Rating}\n\nCVSS {c.Version}   base {N(c.Base)}" + (c.Temporal is { } t ? $"   temporal {N(t)}" : "") + (c.Environmental is { } e ? $"   environmental {N(e)}" : "");
            }
            catch (FormatException ex) { Score = ex.Message; }
        }
    }
    public string Score { get => score; private set => Set(ref score, value); }

    // ---------- values ----------
    public IReadOnlyList<ValueRow> Values { get => values; private set => Set(ref values, value); }
    public string ValueSearch { get => search; set { if (Set(ref search, value ?? "")) FilterValues(); } }

    void FilterValues()
    {
        var q = search.Trim();
        Values = q.Length == 0 ? allValues : allValues.Where(v => v.Title.Contains(q, StringComparison.OrdinalIgnoreCase) || v.Id.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    void OpenValues() => Safe("reading the values", () =>
    {
        if (Doc is not { } doc) return;
        var p = rules.SelectedProfile;
        allValues = doc.UsedValues(rules.ProfileIds()).OrderBy(v => v.Title, StringComparer.OrdinalIgnoreCase).Select(v =>
        {
            var original = doc.ProfileValue(v.Id, p) ?? "";
            return new ValueRow
            {
                Id = v.Id, Title = v.Title.Length > 0 ? v.Title : XccdfImporter.Short(v.Id, "_value_"), Description = v.Description, Original = original,
                Choices = v.BySelector.Values.Append(original).Distinct().ToList(), Text = doc.Value(v.Id, p) ?? ""
            };
        }).ToList();
        if (allValues.Count == 0) { S.Dialogs.Message("The rules of this profile have no values to change."); return; }
        search = "";
        OnPropertyChanged(nameof(ValueSearch));
        FilterValues();
        Show("values", "Values", "");
    });

    Task ApplyValues(CancellationToken ct) => SafeAsync("applying the values", async () =>
    {
        if (Doc is not { } doc) return;
        Panel = "";
        // changes of values that this profile doesn't use stay as they are
        var wanted = new Dictionary<string, string>(doc.Overrides, StringComparer.Ordinal);
        foreach (var v in allValues) { if (v.IsChanged) wanted[v.Id] = v.Text; else wanted.Remove(v.Id); }
        if (wanted.Count == doc.Overrides.Count && wanted.All(w => doc.Overrides.TryGetValue(w.Key, out var o) && o == w.Value)) return;
        await rules.RebuildScap(() =>
        {
            doc.Overrides.Clear();
            foreach (var (k, v) in wanted) doc.Overrides[k] = v;
        }, ct);
        Status($"{allValues.Count(v => v.IsChanged)} value(s) changed.");
    });

    // ---------- tailoring ----------
    public Task LoadTailoring(string? path, CancellationToken ct) => SafeAsync("loading the tailoring", async () =>
    {
        if (Doc is not { } doc) throw new FormatException("Open the benchmark first, then load its tailoring file.");
        path ??= S.Dialogs.PickFile("XCCDF tailoring (*.xml)|*.xml|All files|*.*", "Load a tailoring file");
        if (path == null) return;
        var added = await Task.Run(() => { using var st = S.Files.OpenRead(path); return Tailoring.Load(doc, st, ct); }, ct);
        rules.RefreshProfiles();
        rules.SelectedProfile = added[0];
        Status($"Tailoring loaded: {added[0].Title}.");
    });

    void SaveTailoring() => Safe("saving the tailoring", () =>
    {
        if (Doc is not { } doc) return;
        var ids = rules.ProfileIds();
        if (ids.Count == 0) throw new FormatException("The profile has no rules.");
        var path = S.Dialogs.PickSavePath("tailoring.xml", "XCCDF tailoring (*.xml)|*.xml");
        if (path == null) return;
        var p = rules.SelectedProfile;
        var title = p == null ? "Custom profile" : p.Tailored ? p.Title : p.Title + " (tailored)";
        S.Files.WriteAllText(path, Tailoring.Write(doc, p, title, ids, DateTime.Now));
        Status($"Tailoring saved: {Path.GetFileName(path)}. oscap reads it too (--tailoring-file).");
    });
}

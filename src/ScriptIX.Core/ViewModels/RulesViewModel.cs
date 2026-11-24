using System.Collections.ObjectModel;
using System.ComponentModel;
using ScriptIX.Mvvm;

namespace ScriptIX.ViewModels;

public sealed class RulesViewModel : ViewModelBase
{
    public const string FilterAll = "All rules", FilterReady = "Ready", FilterReview = "Needs review",
                        FilterRisky = "Risky", FilterTicked = "Ticked", FilterProfile = "In profile";

    RuleItem? selectedRule;
    IReadOnlyList<RuleItem> visibleRules = Array.Empty<RuleItem>();
    XccdfDocument? scap;
    XccdfProfile? selectedProfile;
    string searchText = "", filter = FilterAll, sourceName = "", busyText = "";
    bool isBusy, alsoCreateCheck = true, suspend;
    int ready, review, risky, ticked;

    public ObservableCollection<RuleItem> Rules { get; } = new();
    public ObservableCollection<XccdfProfile> Profiles { get; } = new();
    public IReadOnlyList<string> Filters { get; } = new[] { FilterAll, FilterReady, FilterReview, FilterRisky, FilterTicked, FilterProfile };
    public Array CompareModes { get; } = Enum.GetValues(typeof(CompareMode));
    public Array OsTargets { get; } = Enum.GetValues(typeof(OsTarget));
    public Array Severities { get; } = Enum.GetValues(typeof(Severity));
    public IReadOnlyList<string> Shells { get; } = new[] { "sh", "bash" };

    public AsyncRelayCommand ImportCommand { get; }
    public RelayCommand CancelCommand { get; }
    public RelayCommand SelectSafeCommand { get; }
    public RelayCommand SelectShownCommand { get; }
    public RelayCommand SelectNoneCommand { get; }
    public RelayCommand AddRuleCommand { get; }
    public RelayCommand DeleteRuleCommand { get; }
    public RelayCommand LoadSamplesCommand { get; }
    public RelayCommand SaveRulesCommand { get; }
    public RelayCommand ClearCommand { get; }
    public RelayCommand ClearSearchCommand { get; }
    public ScapViewModel ScapTools { get; }

    /// Raised when a .txt/.sh file was picked: its text belongs in the own-commands editor.
    public event Action<string>? CommandsFileLoaded;
    public event EventHandler? Changed;

    public RulesViewModel(AppServices s) : base(s)
    {
        ImportCommand = new AsyncRelayCommand((p, ct) => ImportAsync(p as string, ct));
        CancelCommand = new RelayCommand(() => ImportCommand.Cancel());
        SelectSafeCommand = new RelayCommand(() => Bulk(r => r.Selected = r.Status == RuleStatus.Ready && r.InProfile), () => Rules.Count > 0);
        SelectShownCommand = new RelayCommand(() => Bulk(r => { if (VisibleRules.Contains(r) && r.Status != RuleStatus.Risky) r.Selected = true; }), () => Rules.Count > 0);
        SelectNoneCommand = new RelayCommand(() => Bulk(r => r.Selected = false), () => Rules.Count > 0);
        AddRuleCommand = new RelayCommand(AddRule);
        DeleteRuleCommand = new RelayCommand(DeleteRule, () => SelectedRule != null);
        LoadSamplesCommand = new RelayCommand(LoadSamples);
        SaveRulesCommand = new RelayCommand(SaveRules, () => Rules.Count > 0);
        ClearCommand = new RelayCommand(ClearAll, () => Rules.Count > 0);
        ClearSearchCommand = new RelayCommand(() => SearchText = "");
        ScapTools = new ScapViewModel(s, this);

        Rules.CollectionChanged += (_, e) =>
        {
            if (e.NewItems != null) foreach (RuleItem r in e.NewItems) r.PropertyChanged += OnRuleChanged;
            if (e.OldItems != null) foreach (RuleItem r in e.OldItems) r.PropertyChanged -= OnRuleChanged;
            if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Reset)
                foreach (var r in detached) r.PropertyChanged -= OnRuleChanged;
            if (!suspend) { Refresh(); Rebuild(); }
        };
    }

    // Reset doesn't report removed items, so remember them for unhooking.
    readonly List<RuleItem> detached = new();

    public RuleItem? SelectedRule
    {
        get => selectedRule;
        set { if (Set(ref selectedRule, value)) { OnPropertyChanged(nameof(HasSelection)); DeleteRuleCommand.RaiseCanExecuteChanged(); } }
    }
    public bool HasSelection => selectedRule != null;
    public IReadOnlyList<RuleItem> VisibleRules { get => visibleRules; private set => Set(ref visibleRules, value); }
    public bool IsBusy { get => isBusy; private set => Set(ref isBusy, value); }
    public string BusyText { get => busyText; private set => Set(ref busyText, value); }
    public bool AlsoCreateCheck { get => alsoCreateCheck; set => Set(ref alsoCreateCheck, value); }
    public bool HasRules => Rules.Count > 0;
    public bool IsEmpty => Rules.Count == 0;
    public bool HasProfiles => Profiles.Count > 0;
    public XccdfDocument? Scap => scap;
    /// <summary>A real SCAP benchmark is loaded (not a CIS PDF or an OVAL file).</summary>
    public bool HasScap => scap is { Prebuilt: null };
    public string ScapPath { get; private set; } = "";
    /// <summary>Full ids of the rules in the profile, with the changes made here.</summary>
    public HashSet<string> ProfileIds() => Rules.Where(r => r.InProfile && r.FullId.Length > 0).Select(r => r.FullId).ToHashSet(StringComparer.Ordinal);

    void SetScap(XccdfDocument? doc, string path)
    {
        scap = doc;
        ScapPath = doc == null ? "" : path;
        RefreshProfiles();
        OnPropertyChanged(nameof(HasScap));
    }

    public void RefreshProfiles()
    {
        selectedProfile = null;
        Profiles.Clear();
        if (scap != null) foreach (var p in scap.Profiles) Profiles.Add(p);
        OnPropertyChanged(nameof(SelectedProfile));
        OnPropertyChanged(nameof(HasProfiles));
    }

    /// Builds the rules again after a change to the benchmark values; ticks, profile and own edits stay.
    public async Task RebuildScap(Action change, CancellationToken ct)
    {
        if (scap is not { } doc) return;
        IsBusy = true;
        BusyText = "Updating the rules...";
        try
        {
            var profile = selectedProfile;
            var (before, after) = await Task.Run(() => { var b = doc.ToRules(profile, ct); change(); return (b, doc.ToRules(profile, ct)); }, ct);
            var old = Rules.Where(r => r.FullId.Length > 0).GroupBy(r => r.FullId).ToDictionary(g => g.Key, g => g.First());
            var was = before.ToDictionary(r => r.FullId);
            suspend = true;
            try
            {
                foreach (var n in after)
                {
                    if (!old.TryGetValue(n.FullId, out var o)) continue;   // deleted here
                    var b = was[n.FullId];
                    if (o.Remediation == b.Remediation) o.Remediation = n.Remediation;
                    if (o.Command == b.Command && o.Mode == b.Mode) { o.Command = n.Command; o.Oval = n.Oval; o.CheckGap = n.CheckGap; }
                }
            }
            finally { suspend = false; }
            Refresh();
            Rebuild();
        }
        finally { IsBusy = false; BusyText = ""; }
    }
    public string SourceName { get => sourceName; private set => Set(ref sourceName, value); }

    public int TotalCount => Rules.Count;
    public int ReadyCount { get => ready; private set => Set(ref ready, value); }
    public int ReviewCount { get => review; private set => Set(ref review, value); }
    public int RiskyCount { get => risky; private set => Set(ref risky, value); }
    public int SelectedCount { get => ticked; private set => Set(ref ticked, value); }
    public string ShownText => VisibleRules.Count == Rules.Count ? $"{Rules.Count} rules" : $"Showing {VisibleRules.Count} of {Rules.Count}";

    public string SearchText
    {
        get => searchText;
        set { if (Set(ref searchText, value ?? "")) Rebuild(); }
    }

    public string Filter
    {
        get => filter;
        set { if (Set(ref filter, value ?? FilterAll)) Rebuild(); }
    }

    public XccdfProfile? SelectedProfile
    {
        get => selectedProfile;
        set
        {
            if (!Set(ref selectedProfile, value) || scap == null || value == null) return;
            ReplaceAll(scap.ToRules(value));
            var inProfile = Rules.Count(r => r.InProfile);
            Filter = FilterProfile;
            Status($"Profile \"{value.Title}\": {inProfile} rules, {SelectedCount} ready ones ticked. Risky and needs-review rules stay unticked.");
        }
    }

    public void ReplaceAll(IEnumerable<RuleItem> items)
    {
        suspend = true;
        try
        {
            detached.Clear();
            detached.AddRange(Rules);
            Rules.Clear();
            detached.Clear();
            foreach (var r in items) Rules.Add(r);
        }
        finally { suspend = false; }
        SelectedRule = null;
        Refresh();
        Rebuild();
    }

    public void AddRange(IEnumerable<RuleItem> items)
    {
        suspend = true;
        try { foreach (var r in items) Rules.Add(r); }
        finally { suspend = false; }
        Refresh();
        Rebuild();
    }

    void Bulk(Action<RuleItem> change)
    {
        suspend = true;
        try { foreach (var r in Rules) change(r); }
        finally { suspend = false; }
        Refresh();
        if (filter == FilterTicked) Rebuild();
    }

    void OnRuleChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuleItem.InProfile) or nameof(RuleItem.RiskText) or nameof(RuleItem.ReversibleText)) return;
        if (suspend) return;
        if (e.PropertyName is nameof(RuleItem.Selected) or nameof(RuleItem.Status)) Refresh();
        else Changed?.Invoke(this, EventArgs.Empty);
    }

    void Refresh()
    {
        int rd = 0, rv = 0, rk = 0, sel = 0;
        foreach (var r in Rules)
        {
            if (r.Selected) sel++;
            switch (r.Status)
            {
                case RuleStatus.Ready: rd++; break;
                case RuleStatus.NeedsReview: rv++; break;
                default: rk++; break;
            }
        }
        ReadyCount = rd; ReviewCount = rv; RiskyCount = rk; SelectedCount = sel;
        OnPropertyChanged(nameof(TotalCount));
        OnPropertyChanged(nameof(HasRules));
        OnPropertyChanged(nameof(IsEmpty));
        SelectSafeCommand.RaiseCanExecuteChanged();
        SelectShownCommand.RaiseCanExecuteChanged();
        SelectNoneCommand.RaiseCanExecuteChanged();
        SaveRulesCommand.RaiseCanExecuteChanged();
        ClearCommand.RaiseCanExecuteChanged();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    void Rebuild()
    {
        var q = searchText.Trim();
        var list = new List<RuleItem>(Rules.Count);
        foreach (var r in Rules)
        {
            bool ok = filter switch
            {
                FilterReady => r.Status == RuleStatus.Ready,
                FilterReview => r.Status == RuleStatus.NeedsReview,
                FilterRisky => r.Status == RuleStatus.Risky,
                FilterTicked => r.Selected,
                FilterProfile => r.InProfile,
                _ => true
            };
            if (ok && q.Length > 0)
                ok = r.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                     r.Id.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                     r.Remediation.Contains(q, StringComparison.OrdinalIgnoreCase);
            if (ok) list.Add(r);
        }
        VisibleRules = list;
        OnPropertyChanged(nameof(ShownText));
    }

    // ---------- import ----------
    public static string ImportFilter => "Rules and benchmarks|*.pdf;*.csv;*.json;*.xml;*.txt;*.sh|All files|*.*";

    public event Action? Opened;

    async Task ImportAsync(string? path, CancellationToken ct)
    {
        path ??= S.Dialogs.PickFile(ImportFilter, "Open a rules file, SCAP benchmark or command list");
        if (path == null) return;
        var ext = Path.GetExtension(path).ToLowerInvariant();

        IsBusy = true;
        BusyText = $"Reading {Path.GetFileName(path)}...";
        try
        {
            await SafeAsync("importing the file", async () =>
            {
                if (ext is ".txt" or ".sh")
                {
                    var t = await Task.Run(() => S.Files.ReadAllText(path), ct);
                    CommandsFileLoaded?.Invoke(t);
                    return;
                }
                if (ext == ".pdf" && S.Files.Size(path) > CisPdfImporter.MaxPdf)
                    throw new FormatException("That PDF is larger than 200 MB, which is far bigger than any CIS benchmark.");
                if (ext is not ".xml" and not ".pdf" && S.Files.Size(path) > RuleImporter.MaxTextFile)
                    throw new FormatException("That file is larger than 100 MB. Split it, or use a SCAP .xml file, which is read as a stream.");
                if (ext == ".pdf") BusyText = $"Reading the PDF {Path.GetFileName(path)} (a big benchmark takes a few seconds)...";

                var report = await Task.Run(() =>
                {
                    if (ext == ".pdf")
                    {
                        using var st = S.Files.OpenRead(path);
                        return CisPdfImporter.Load(st, path, ct);
                    }
                    if (ext == ".xml")
                    {
                        using var st = S.Files.OpenRead(path);
                        return XccdfImporter.Load(st, path, ct);
                    }
                    var text = S.Files.ReadAllText(path);
                    return ext == ".json" ? RuleImporter.FromJson(text, path) : RuleImporter.FromCsv(text, path);
                }, ct);
                ct.ThrowIfCancellationRequested();

                bool replace = true;
                if (Rules.Count > 0)
                {
                    var c = S.Dialogs.AskYesNoCancel($"You already have {Rules.Count} rules.\n\nYes = replace them with the new file\nNo = add the new rules to them");
                    if (c == Choice.Cancel) return;
                    replace = c == Choice.Yes;
                }

                if (replace) ReplaceAll(report.Rules); else AddRange(report.Rules);

                SetScap(report.Scap, path);
                Opened?.Invoke();
                Filter = FilterAll;
                SourceName = Path.GetFileName(path);
                Status($"Loaded {report.Found} rules from {SourceName}.");
                IsBusy = false;
                S.Dialogs.Message(report.ToText());
            });
        }
        finally
        {
            IsBusy = false;
            BusyText = "";
        }
    }

    void LoadSamples()
    {
        if (Rules.Count > 0 && !S.Dialogs.Confirm($"Replace your {Rules.Count} rules with the example rules?")) return;
        SetScap(null, "");
        ReplaceAll(Samples.Load());
        SourceName = "Example rules";
        Status("Loaded the example rules. Ready rules are ticked; risky ones never are.");
    }

    void AddRule()
    {
        var n = Rules.Count + 1;
        while (Rules.Any(r => r.Id == $"R-{n:000}")) n++;
        var rule = new RuleItem { Id = $"R-{n:000}", Title = "New rule" };
        Rules.Add(rule);
        if (!VisibleRules.Contains(rule)) { Filter = FilterAll; SearchText = ""; }
        SelectedRule = rule;
    }

    void DeleteRule()
    {
        if (SelectedRule == null) return;
        var r = SelectedRule;
        Rules.Remove(r);
        Status($"Deleted rule {r.Id}.");
    }

    void ClearAll()
    {
        if (!S.Dialogs.Confirm($"Remove all {Rules.Count} rules from the list?")) return;
        SetScap(null, "");
        ReplaceAll(Array.Empty<RuleItem>());
        SourceName = "";
    }

    void SaveRules() => Safe("saving the rules file", () =>
    {
        var path = S.Dialogs.PickSavePath("rules.json", "ScriptIX rules (*.json)|*.json");
        if (path == null) return;
        S.Files.WriteAllText(path, RuleImporter.ToJson(Rules));
        Status($"Saved {Rules.Count} rules to {Path.GetFileName(path)}.");
    });
}

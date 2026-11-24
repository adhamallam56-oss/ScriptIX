using ScriptIX.Mvvm;
using ScriptIX.Scap;

namespace ScriptIX.ViewModels;

public sealed class MainViewModel : ViewModelBase
{
    public const int TabRules = 0, TabManual = 1, TabScript = 2, TabServers = 3, TabResults = 4, TabHelp = 5;

    readonly AutosaveService? auto;
    int selectedTab;
    string status = "Ready";

    public RulesViewModel Rules { get; }
    public ManualViewModel Manual { get; }
    public ScriptViewModel Script { get; }
    public ServersViewModel Servers { get; }
    public ResultsViewModel Results { get; }
    public TutorialViewModel Tutorial { get; }

    public RelayCommand CreateFromRulesCommand { get; }
    public RelayCommand CheckOnlyCommand { get; }
    public RelayCommand CreateFromManualCommand { get; }
    public RelayCommand OpenPathCommand { get; }
    public RelayCommand GoToCommand { get; }
    public RelayCommand EscapeCommand { get; }
    public RelayCommand OpenLogFolderCommand { get; }

    public string Title => $"{AppInfo.Name} {AppInfo.Version} · {AppInfo.Tagline}";
    public string Version => $"v{AppInfo.Version}";
    public HelpViewModel Help { get; } = new();

    public MainViewModel(AppServices services, AutosaveService? autosave = null) : base(services)
    {
        auto = autosave;
        Rules = new RulesViewModel(services);
        Manual = new ManualViewModel(services);
        Script = new ScriptViewModel(services);
        Servers = new ServersViewModel(services, Script.Scripts, Script.SavePackagesCommand);
        Results = new ResultsViewModel(services);
        Tutorial = new TutorialViewModel(services.Files, t => SelectedTab = t);

        CreateFromRulesCommand = new RelayCommand(CreateFromRules, () => Rules.SelectedCount > 0);
        CheckOnlyCommand = new RelayCommand(CheckOnly, () => Rules.Rules.Count > 0);
        CreateFromManualCommand = new RelayCommand(CreateFromManual, () => Manual.CommandCount > 0);
        OpenPathCommand = new RelayCommand(p => { if (p is string path) OpenPath(path); });
        GoToCommand = new RelayCommand(p => { if (int.TryParse(p?.ToString(), out var t)) SelectedTab = t; });
        EscapeCommand = new RelayCommand(() =>
        {
            if (Tutorial!.Visible) Tutorial.SkipCommand.Execute(null);
            else if (Results.Details.IsOpen) Results.Details.DoneCommand.Execute(null);
            else if (Rules.ScapTools.IsOpen) Rules.ScapTools.CloseCommand.Execute(null);
            else if (SelectedTab == TabServers) Servers.CloseCommand.Execute(null);
        });
        OpenLogFolderCommand = new RelayCommand(() => Safe("opening the log folder", () =>
            S.Shell.OpenFolder(Path.GetDirectoryName(S.Crash.Location)!)));

        foreach (var vm in new ViewModelBase[] { Rules, Rules.ScapTools, Manual, Script, Servers, Results, Results.Details })
            vm.StatusChanged += t => StatusText = t;
        StatusChanged += t => StatusText = t;

        Rules.CommandsFileLoaded += text => { Manual.Load(text); SelectedTab = TabManual; };
        Rules.Opened += () => SelectedTab = TabRules;      // Ctrl+O and Ctrl+R work from any page
        Results.Opened += () => SelectedTab = TabResults;
        Results.FixRequested += OnFixRequested;
        Results.ScapContext = () => (Rules.Scap, Rules.SelectedProfile);
        Rules.ScapTools.ScriptRequested += job => Safe("creating the script", () => { Script.Show(new[] { job }, Array.Empty<string>()); SelectedTab = TabScript; });
        Script.ResultsReady += OpenPath;
        Servers.OpenRequested += OpenPath;
        Rules.Changed += (_, _) => { CheckOnlyCommand.RaiseCanExecuteChanged(); CreateFromRulesCommand.RaiseCanExecuteChanged(); RequestAutosave(); };
        Manual.Changed += (_, _) => { CreateFromManualCommand.RaiseCanExecuteChanged(); RequestAutosave(); };
        Script.OptionsChanged += (_, _) => RequestAutosave();
    }

    public int SelectedTab
    {
        get => selectedTab;
        set { if (Set(ref selectedTab, value) && value == TabResults && Results.HasRows) Results.Count(); }   // the SCAP content may have changed
    }
    public string StatusText { get => status; private set => Set(ref status, value); }

    // ---------- drag and drop / open ----------
    public void OpenPath(string path) => Safe("opening the file", () =>
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext == ".csv" && ResultsParser.LooksLikeResults(S.Files.ReadFirstLine(path)))
        {
            SelectedTab = TabResults;
            Results.OpenCommand.Execute(path);
            return;
        }
        if (ext == ".xml")
        {
            string kind;
            using (var st = S.Files.OpenRead(path)) kind = ScapSource.Sniff(st);
            if (kind == "results") { SelectedTab = TabResults; Results.OpenCommand.Execute(path); return; }
            if (kind == "tailoring") { SelectedTab = TabRules; Rules.ScapTools.LoadTailoringCommand.Execute(path); return; }
        }
        if (ext is ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp")
        {
            SelectedTab = TabResults;
            Results.Details.OpenCommand.Execute(null);
            Results.Details.AddPicture(path);
            return;
        }
        if (ext is ".csv" or ".json" or ".xml" or ".txt" or ".sh" or ".pdf")
        {
            if (ext is ".csv" or ".json" or ".xml" or ".pdf") SelectedTab = TabRules;
            Rules.ImportCommand.Execute(path);
            return;
        }
        S.Dialogs.Message($"ScriptIX can't open {ext} files. Drop a CIS benchmark (.pdf), a SCAP benchmark (.xml), a rules file (.csv, .json), a command list (.txt, .sh), results (.csv, .xml), or a picture for the report.");
    });

    // ---------- create scripts ----------
    void CreateFromRules() => Safe("creating the script", () =>
    {
        var chosen = Rules.Rules.Where(r => r.Selected).ToList();
        if (chosen.Count == 0) { S.Dialogs.Message("Tick at least one rule first."); return; }

        var items = ScriptBuilder.ApplyItems(chosen);
        int noFix = chosen.Count - items.Count;
        if (items.Count == 0) { S.Dialogs.Message("None of the ticked rules has a fix command. Add one in the rule details."); return; }

        var risky = chosen.Where(r => r.Status == RuleStatus.Risky).ToList();
        if (risky.Count > 0 && !S.Dialogs.Confirm(
            $"{risky.Count} ticked rule(s) can lock you out or break services:\n\n" +
            string.Join("\n", risky.Take(12).Select(r => $"• {r.Id}: {r.Title}")) +
            (risky.Count > 12 ? $"\n• ... and {risky.Count - 12} more" : "") +
            "\n\nRun --dry-run first. Keep a second admin session open.\n\nCreate the script with these rules?"))
            return;
        var review = chosen.Where(r => r.Status == RuleStatus.NeedsReview && !string.IsNullOrWhiteSpace(r.Remediation)).ToList();
        if (review.Count > 0 && !S.Dialogs.Confirm(
            $"{review.Count} ticked rule(s) still need review (placeholders like <user>):\n\n" +
            string.Join("\n", review.Take(10).Select(r => $"• {r.Id}: {r.Title}")) +
            "\n\nThey will fail or do the wrong thing until you fill them in. Continue anyway?"))
            return;
        if (!Validate(items)) return;

        var jobs = new List<ScriptJob> { new("scriptix_apply.sh", "apply", items, Purpose: "Applies the fixes (changes the server)") };
        if (Rules.AlsoCreateCheck)
        {
            var checks = ScriptBuilder.CheckItems(chosen);
            if (checks.Count > 0)
                jobs.Add(new("scriptix_check.sh", "check", checks, RequireRoot: false, ReadOnly: true, Purpose: "Only checks; changes nothing"));
        }
        var undo = ScriptBuilder.UndoItems(chosen);
        if (undo.Count > 0)
            jobs.Add(new("scriptix_undo_rules.sh", "undo-rules", undo, Purpose: "Runs the rules' own undo commands"));

        Script.Show(jobs, Notes(jobs.SelectMany(j => j.Items).ToList()));
        SelectedTab = TabScript;
        StatusText = $"Created {jobs.Count} script(s) with {items.Count} fix commands." +
                     (noFix > 0 ? $" {noFix} ticked rule(s) without a fix command were left out." : "");
    });

    // like "oscap xccdf eval": every rule of the profile, nothing is changed
    void CheckOnly() => Safe("creating the check script", () =>
    {
        var ticked = Rules.Rules.Where(r => r.Selected).ToList();
        var list = Rules.SelectedProfile != null ? Rules.Rules.Where(r => r.InProfile).ToList() : ticked.Count > 0 ? ticked : Rules.Rules.ToList();
        var items = ScriptBuilder.CheckItems(list, true);
        if (items.All(i => i.Mode == "manual")) { S.Dialogs.Message("None of these rules has a check command."); return; }
        if (!Validate(items)) return;
        Script.Show(new[] { new ScriptJob("scriptix_check.sh", "check", items, RequireRoot: false, ReadOnly: true, Purpose: "Only checks; changes nothing") }, Notes(items));
        SelectedTab = TabScript;
        var manual = items.Count(i => i.Mode == "manual");
        StatusText = $"Check script created for {items.Count} rules." + (manual > 0 ? $" {manual} must be answered by hand on the Results page." : "");
    });

    void CreateFromManual() => Safe("creating the script", () =>
    {
        var items = Manual.Items();
        if (items.Count == 0) { S.Dialogs.Message("Type or import at least one command first."); return; }
        var risky = Risk.WarningsFor(items, 12);
        if (risky.Count > 0 && !S.Dialogs.Confirm(
            "Some commands look dangerous:\n\n" + string.Join("\n", risky.Select(w => "• " + w)) +
            "\n\nRun --dry-run first and keep a second admin session open.\n\nCreate the script anyway?"))
            return;
        if (!Validate(items)) return;

        Script.Show(new[] { new ScriptJob("scriptix_commands.sh", "manual", items, Purpose: "Your own commands") }, Notes(items));
        SelectedTab = TabScript;
        StatusText = $"Script created with {items.Count} commands.";
    });

    bool Validate(IReadOnlyCollection<ScriptItem> items)
    {
        var blocking = Validator.Blocking(items);
        if (blocking.Count > 0)
        {
            S.Dialogs.Message("Fix these first:\n\n• " + string.Join("\n• ", blocking.Take(12)));
            return false;
        }
        var warn = Validator.Warnings(items);
        return warn.Count == 0 || S.Dialogs.Confirm(
            "Please have a look at these:\n\n• " + string.Join("\n• ", warn.Take(12)) +
            (warn.Count > 12 ? $"\n• ... and {warn.Count - 12} more" : "") + "\n\nCreate the script anyway?");
    }

    static IEnumerable<string> Notes(IReadOnlyCollection<ScriptItem> items)
    {
        var bash = items.Count(i => i.Shell == "bash");
        if (bash > 0) yield return $"{bash} command(s) run with bash. Where bash is missing they are SKIPPED (NEEDS-BASH).";
        foreach (var p in Validator.Portability(items)) yield return p;
    }

    // ---------- fix / re-run failed ----------
    void OnFixRequested(IReadOnlyList<ResultRow> failed, bool useFixes) => Safe("building the script for the failed items", () =>
    {
        var manual = Manual.Items().GroupBy(i => i.Id).ToDictionary(g => g.Key, g => g.First());
        var rules = Rules.Rules.GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First());
        var items = new List<ScriptItem>();
        int fromRules = 0, fromHistory = 0, noContent = 0;
        foreach (var row in failed)
        {
            if (useFixes && rules.TryGetValue(row.Id, out var r) && !string.IsNullOrWhiteSpace(r.Remediation))
            {
                items.Add(ScriptBuilder.ApplyItems(new[] { r })[0]);   // a failed check: apply its fix
                fromRules++;
            }
            else if (manual.TryGetValue(row.Id, out var m) && m.Command == row.Command)
                items.Add(m);                                            // same own-command list: exact original
            else if (rules.TryGetValue(row.Id, out var c) && c.Oval.Length > 0 && c.Command.Length > 0)
                items.Add(ScriptBuilder.CheckItems(new[] { c })[0]);     // an OVAL check needs its definitions, which only the rule has
            else if (row.Mode is "oval" or "manual")
                noContent++;
            else if (!string.IsNullOrWhiteSpace(row.Command))
            {
                // schema 3 files carry the original check; older ones only have the expected text
                var mode = row.Mode.Length > 0 ? row.Mode : row.Expected.Length > 0 ? "contains" : "rc0";
                items.Add(new ScriptItem(row.Id, row.Title, row.Severity, row.Os.Length > 0 ? row.Os : "any", mode,
                                         row.Expected, row.Command, row.Timeout, row.Shell == "bash" ? "bash" : "sh"));
                fromHistory++;
            }
        }
        if (items.Count == 0)
        {
            S.Dialogs.Message(noContent > 0 ? "These are OVAL checks. Open the SCAP content on the Rules page first, then try again."
                                            : "None of the failed items has a command I can run again.");
            return;
        }
        if (!Validate(items)) return;
        var name = useFixes ? "scriptix_fix_failed.sh" : "scriptix_rerun_failed.sh";
        Script.Show(new[] { new ScriptJob(name, useFixes ? "fix" : "rerun", items, Purpose: useFixes ? "Fixes the failed items" : "Runs the failed commands again") },
                    Notes(items));
        SelectedTab = TabScript;
        StatusText = $"Script created for {items.Count} failed item(s)" +
                     (useFixes ? $": {fromRules} from rule fixes, {items.Count - fromRules} re-run as they were." : ".");
        if (noContent > 0) StatusText += $" {noContent} OVAL check(s) left out: open the SCAP content on the Rules page first.";
        if (fromHistory > 0 && useFixes)
            StatusText += " Some came from the results file only (no matching rule loaded).";
    });

    // ---------- autosave and closing ----------
    void RequestAutosave() => auto?.Request(() => new AutosaveState
    {
        ManualText = Manual.CommandsText,
        Rules = Rules.Rules.ToList(),
        StopOnFail = Script.StopOnFail,
        TimeoutSeconds = Script.TimeoutSeconds,
        Redact = Script.Redact
    });

    public void OfferRestore()
    {
        var st = auto?.Load();
        if (st == null) return;
        Script.SetOptions(st.StopOnFail, st.TimeoutSeconds, st.Redact);
        if (st.ManualText.Trim().Length == 0 && st.Rules.Count == 0) return;
        var what = new List<string>();
        if (st.Rules.Count > 0) what.Add($"{st.Rules.Count} rules");
        if (st.ManualText.Trim().Length > 0) what.Add("your own commands");
        if (!S.Dialogs.Confirm($"Restore your last session ({string.Join(" and ", what)})?")) return;
        Manual.CommandsText = st.ManualText;
        Rules.ReplaceAll(st.Rules);
        StatusText = "Last session restored.";
        if (st.Rules.Count == 0 && st.ManualText.Trim().Length > 0) SelectedTab = TabManual;
    }

    public bool ConfirmClose()
    {
        auto?.Flush();
        Results.Details.Save();
        if (!Script.HasUnsaved) return true;
        return S.Dialogs.AskYesNoCancel("The script isn't saved yet. Save it first?") switch
        {
            Choice.Yes => Script.SaveAll(),
            Choice.No => true,
            _ => false
        };
    }
}

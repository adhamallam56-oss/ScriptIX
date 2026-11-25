using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using ScriptIX.Mvvm;
using ScriptIX.Packaging;

namespace ScriptIX.ViewModels;

/// <summary>One saved server. Never has a password: ssh asks for it in its own window.</summary>
public sealed class ServerItem : ObservableObject
{
    string group = "", user = "root", key = "", file = "", when = "", state = "";
    int port = 22, passed, failed, skipped;
    bool sudo, selected, busy;

    public string Host { get; set; } = "";
    public string Group { get => group; set => Set(ref group, (value ?? "").Trim()); }
    public string User { get => user; set => Set(ref user, (value ?? "").Trim()); }
    public int Port { get => port; set => Set(ref port, value); }
    public string KeyFile { get => key; set => Set(ref key, (value ?? "").Trim()); }
    public bool Sudo { get => sudo; set => Set(ref sudo, value); }
    public bool Selected { get => selected; set => Set(ref selected, value); }

    // the last results
    public string LastFile { get => file; set { if (Set(ref file, value ?? "")) OnPropertyChanged(nameof(HasResults)); } }
    public string LastScan { get => when; set => Set(ref when, value ?? ""); }
    public int Passed { get => passed; set { if (Set(ref passed, value)) OnPropertyChanged(nameof(PassedText)); } }
    public int Failed { get => failed; set { if (Set(ref failed, value)) OnPropertyChanged(nameof(FailedText)); } }
    public int Skipped { get => skipped; set { if (Set(ref skipped, value)) OnPropertyChanged(nameof(SkippedText)); } }

    [JsonIgnore] public bool HasResults => file.Length > 0;
    [JsonIgnore] public string PassedText => HasResults ? passed.ToString() : "";
    [JsonIgnore] public string FailedText => HasResults ? failed.ToString() : "";
    [JsonIgnore] public string SkippedText => HasResults ? skipped.ToString() : "";
    /// <summary>What happens now or happened last in this session.</summary>
    [JsonIgnore] public string State { get => state; set => Set(ref state, value); }
    [JsonIgnore] public bool Busy { get => busy; set => Set(ref busy, value); }
    [JsonIgnore] public SshTarget Target => new(Host, User, Port, KeyFile, Sudo);

    public void TakeResults(string path, string scanned, ResultSummary s)
    {
        LastFile = path; LastScan = scanned;
        Passed = s.Passed; Failed = s.Failed; Skipped = s.Skipped;
        foreach (var n in new[] { nameof(PassedText), nameof(FailedText), nameof(SkippedText) }) OnPropertyChanged(n);
    }
}

public sealed class ServersViewModel : ViewModelBase
{
    public const string AllGroups = "All groups", MatrixAll = "All rules", MatrixDiffer = "Different", MatrixFailed = "Failed";
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    readonly string path;
    bool loading, addOpen, packageOpen, matrixOpen, addSudo, daily;
    string group = AllGroups, addHosts = "", addGroup = "", addUser = "root", addPort = "22", addKey = "", time = "02:30", matrixFilter = MatrixDiffer;
    ServerItem? current;
    GeneratedScript? script;
    FleetTable? table;
    CancellationTokenSource watch = new();

    public ObservableCollection<ServerItem> Servers { get; } = new();
    public ObservableCollection<GeneratedScript> Scripts { get; }
    public ObservableCollection<string> Groups { get; } = new() { AllGroups };
    public IReadOnlyList<string> MatrixFilters { get; } = new[] { MatrixDiffer, MatrixFailed, MatrixAll };

    public RelayCommand AddOpenCommand { get; }
    public RelayCommand AddCommand { get; }
    public RelayCommand KeyCommand { get; }
    public RelayCommand RemoveCommand { get; }
    public RelayCommand TickAllCommand { get; }
    public RelayCommand RunCommand { get; }
    public RelayCommand PackageCommand { get; }
    public RelayCommand SavePackagesCommand { get; }
    public RelayCommand InstallCommand { get; }
    public RelayCommand ScanInstalledCommand { get; }
    public RelayCommand CollectCommand { get; }
    public RelayCommand ScheduleCommand { get; }
    public RelayCommand ScheduleOffCommand { get; }
    public RelayCommand UninstallCommand { get; }
    public RelayCommand OpenResultsCommand { get; }
    public AsyncRelayCommand MatrixCommand { get; }
    public RelayCommand MatrixSaveCommand { get; }
    public RelayCommand StopWaitingCommand { get; }
    public RelayCommand CloseCommand { get; }

    public event Action<string>? OpenRequested;

    public ServersViewModel(AppServices s, ObservableCollection<GeneratedScript> scripts, RelayCommand savePackages, string? path = null) : base(s)
    {
        SavePackagesCommand = savePackages;
        this.path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptIX", "servers.json");
        Scripts = scripts;
        scripts.CollectionChanged += (_, _) => PickScript();

        AddOpenCommand = new RelayCommand(() => { var v = !AddOpen; Close(); AddOpen = v; });
        AddCommand = new RelayCommand(() => Safe("adding the servers", Add));
        KeyCommand = new RelayCommand(() => { if (S.Dialogs.PickFile("All files|*.*", "Pick your private key file") is { } p) AddKey = p; });
        RemoveCommand = new RelayCommand(() => Safe("removing the servers", Remove), () => TickedCount > 0);
        TickAllCommand = new RelayCommand(() => { var on = VisibleServers.Any(x => !x.Selected); foreach (var x in VisibleServers) x.Selected = on; });
        RunCommand = new RelayCommand(() => Safe("starting ssh", RunScript), () => TickedCount > 0 && SelectedScript != null);
        PackageCommand = new RelayCommand(() => { var v = !PackageOpen; Close(); PackageOpen = v; });
        InstallCommand = new RelayCommand(() => Safe("making the packages", Install), () => TickedCount > 0);
        ScanInstalledCommand = new RelayCommand(() => Safe("starting ssh", () => Start(SshRun.ScanInstalled(), "", null, "Scanning")), () => TickedCount > 0);
        CollectCommand = new RelayCommand(() => Safe("starting ssh", () => Start(SshRun.Collect(), "", null, "Getting results")), () => TickedCount > 0);
        ScheduleCommand = new RelayCommand(() => Safe("starting ssh", () => { Packages.CheckTime(Time.Trim()); Start(SshRun.Schedule(Time.Trim()), "", null, "Daily scan"); }), () => TickedCount > 0);
        ScheduleOffCommand = new RelayCommand(() => Safe("starting ssh", () => Start(SshRun.Schedule(""), "", null, "Daily scan off")), () => TickedCount > 0);
        UninstallCommand = new RelayCommand(() => Safe("starting ssh", () =>
        {
            if (S.Dialogs.Confirm("Remove the scriptix package from these servers? The results stay on the servers.\n\n" + Names(Ticked())))
                Start(SshRun.Remove(), SshRun.RemoveName, System.Text.Encoding.ASCII.GetBytes(SshRun.RemoveScript), "Removing");
        }), () => TickedCount > 0);
        OpenResultsCommand = new RelayCommand(p =>
        {
            if (p is not ServerItem { HasResults: true } item) return;
            if (S.Files.Exists(item.LastFile)) OpenRequested?.Invoke(item.LastFile);
            else S.Dialogs.Message("The results file was moved or deleted. Scan the server again.");
        });
        MatrixCommand = new AsyncRelayCommand(_ => ShowMatrix());
        MatrixSaveCommand = new RelayCommand(() => Safe("saving the table", () =>
        {
            if (table == null || S.Dialogs.PickSavePath($"servers_{DateTime.Now:yyyyMMdd_HHmm}.csv", "CSV (*.csv)|*.csv") is not { } p) return;
            S.Files.WriteAllText(p, FleetMatrix.Csv(table));
            Status($"Saved {Path.GetFileName(p)}");
        }));
        StopWaitingCommand = new RelayCommand(StopWaiting);
        CloseCommand = new RelayCommand(Close);
        Load();
    }

    // ---------- the list ----------
    public IReadOnlyList<ServerItem> VisibleServers { get; private set; } = Array.Empty<ServerItem>();
    public bool IsEmpty => Servers.Count == 0;
    public bool HasServers => Servers.Count > 0;
    public int TickedCount => Ticked().Count;
    public string TickedText => $"{TickedCount} of {VisibleServers.Count} ticked";
    // only servers that are shown: one hidden by the group filter is never touched by surprise
    public bool IsWaiting => Servers.Any(x => x.Busy);
    public ServerItem? Current { get => current; set => Set(ref current, value); }
    public string Group { get => group; set { if (Set(ref group, value ?? AllGroups)) Rebuild(); } }
    public GeneratedScript? SelectedScript { get => script; set { if (Set(ref script, value)) RunCommand.RaiseCanExecuteChanged(); } }
    public bool HasScripts => Scripts.Count > 0;

    void PickScript()
    {
        SelectedScript = Scripts.FirstOrDefault(x => x.FileName == script?.FileName) ?? Scripts.FirstOrDefault(ScriptViewModel.IsCheck) ?? Scripts.FirstOrDefault();
        OnPropertyChanged(nameof(HasScripts));
    }

    List<ServerItem> Ticked() => VisibleServers.Where(x => x.Selected).ToList();
    static string Names(IReadOnlyCollection<ServerItem> l) => string.Join("\n", l.Take(15).Select(x => x.Host)) + (l.Count > 15 ? $"\n... and {l.Count - 15} more" : "");

    void Load()
    {
        loading = true;
        try
        {
            if (S.Files.Exists(path))
                foreach (var i in JsonSerializer.Deserialize<List<ServerItem>>(S.Files.ReadAllText(path), Json) ?? new())
                    if (i.Host.Length > 0 && Find(i.Host) == null) AddItem(i);
        }
        catch (Exception ex)
        {
            S.Crash.Write("loading the server list", ex);
            try { File.Copy(path, path + ".bad", true); } catch (Exception) { /* the old file stays until the next change */ }
        }
        loading = false;
        Rebuild();
    }

    void Save()
    {
        if (loading) return;
        try { S.Files.WriteAllText(path, JsonSerializer.Serialize(Servers, Json)); }
        catch (Exception ex) { S.Crash.Write("saving the server list", ex); Status("The server list couldn't be saved. " + Errors.Describe(ex, "saving the server list")); }
    }

    ServerItem? Find(string host) => Servers.FirstOrDefault(x => x.Host.Equals(host, StringComparison.OrdinalIgnoreCase));

    void AddItem(ServerItem i)
    {
        i.PropertyChanged += (_, e) =>
        {
            switch (e.PropertyName)
            {
                case nameof(ServerItem.Selected): Ticks(); Save(); break;
                case nameof(ServerItem.Group): Rebuild(); Save(); break;
                case nameof(ServerItem.User) or nameof(ServerItem.Port) or nameof(ServerItem.KeyFile) or nameof(ServerItem.Sudo): Save(); break;
                case nameof(ServerItem.Busy): OnPropertyChanged(nameof(IsWaiting)); break;
            }
        };
        Servers.Add(i);
    }

    void Ticks()
    {
        OnPropertyChanged(nameof(TickedCount));
        OnPropertyChanged(nameof(TickedText));
        foreach (var c in new[] { RemoveCommand, RunCommand, InstallCommand, ScanInstalledCommand, CollectCommand, ScheduleCommand, ScheduleOffCommand, UninstallCommand })
            c.RaiseCanExecuteChanged();
    }

    void Rebuild()
    {
        if (loading) return;
        var want = new[] { AllGroups }.Concat(Servers.Select(x => x.Group).Where(g => g.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(g => g, StringComparer.OrdinalIgnoreCase)).ToList();
        if (!want.SequenceEqual(Groups))
        {
            var keep = want.Contains(group) ? group : AllGroups;
            for (int i = Groups.Count - 1; i > 0; i--) Groups.RemoveAt(i);
            foreach (var g in want.Skip(1)) Groups.Add(g);
            group = keep;
            OnPropertyChanged(nameof(Group));
        }
        VisibleServers = Servers.Where(x => group == AllGroups || x.Group.Equals(group, StringComparison.OrdinalIgnoreCase)).ToList();
        foreach (var n in new[] { nameof(VisibleServers), nameof(IsEmpty), nameof(HasServers) }) OnPropertyChanged(n);
        Ticks();
    }

    // ---------- add and remove ----------
    public bool AddOpen { get => addOpen; set => Set(ref addOpen, value); }
    public string AddHosts { get => addHosts; set => Set(ref addHosts, value ?? ""); }
    public string AddGroup { get => addGroup; set => Set(ref addGroup, value ?? ""); }
    public string AddUser { get => addUser; set => Set(ref addUser, value ?? ""); }
    public string AddPort { get => addPort; set => Set(ref addPort, value ?? ""); }
    public string AddKey { get => addKey; set => Set(ref addKey, value ?? ""); }
    public bool AddSudo { get => addSudo; set => Set(ref addSudo, value); }

    void Add()
    {
        int.TryParse(addPort.Trim(), out var port);
        var t = new SshTarget(addHosts, addUser.Trim(), port, addKey.Trim(), addSudo);
        SshRun.Check(t);
        if (t.KeyFile.Length > 0 && !S.Files.Exists(t.KeyFile)) throw new FormatException("The key file is missing.");
        var hosts = SshRun.Hosts(addHosts);
        var fresh = hosts.Where(h => Find(h) == null).ToList();
        foreach (var h in fresh)
            AddItem(new ServerItem { Host = h, Group = addGroup, User = t.User, Port = port, KeyFile = t.KeyFile, Sudo = addSudo, Selected = true });
        Group = AllGroups;
        Rebuild();
        Save();
        AddHosts = "";
        var had = hosts.Count - fresh.Count;
        Status($"{fresh.Count} server(s) added." + (had > 0 ? $" {had} already in the list." : ""));
        if (fresh.Count > 0) AddOpen = false;
    }

    void Remove()
    {
        var l = Ticked();
        if (l.Any(x => x.Busy)) throw new FormatException("One of these servers is still working. Wait for it, or press Stop waiting.");
        if (!S.Dialogs.Confirm($"Take {l.Count} server(s) off this list?\n\n{Names(l)}\n\nNothing is changed on the servers.")) return;
        foreach (var x in l) Servers.Remove(x);
        Rebuild();
        Save();
        Status($"{l.Count} server(s) removed from the list.");
    }

    // ---------- over ssh ----------
    void RunScript()
    {
        var g = SelectedScript;
        if (g == null) return;
        var check = ScriptViewModel.IsCheck(g);
        if (!check && !S.Dialogs.Confirm($"{g.FileName} changes the server. It will run on:\n\n{Names(Ticked())}\n\nThe script asks again in the window before it changes anything. Continue?")) return;
        Start(SshRun.Script(g.FileName, check), g.FileName, new System.Text.UTF8Encoding(false).GetBytes(g.Content), check ? "Scanning" : "Running");
    }

    public bool PackageOpen { get => packageOpen; set => Set(ref packageOpen, value); }
    public bool Daily { get => daily; set => Set(ref daily, value); }
    public string Time { get => time; set => Set(ref time, value ?? ""); }

    /// <summary>Asks for the SCAP files that go into the package. null = cancelled.</summary>
    public Func<List<(string Name, byte[] Data)>?>? AskContent { get; set; }

    void Install()
    {
        var at = daily ? Time.Trim() : "";
        if (daily) Packages.CheckTime(at);
        var names = Scripts.Select(x => x.FileName).ToList();
        if (!Scripts.Any(ScriptViewModel.IsCheck)) names.Add("the basic checks");
        var inside = "Scripts inside: " + string.Join(", ", names) + ". Installing runs none of them.";
        if (!S.Dialogs.Confirm($"Install the scriptix package on:\n\n{Names(Ticked())}\n\n{inside}")) return;
        var content = AskContent == null ? new() : AskContent();
        if (content == null) return;
        Start(SshRun.Install(), SshRun.BundleName, new Packages(Scripts.ToList(), DateTime.UtcNow, content).Bundle(at), "Installing");
    }

    void Start(SshJob job, string payloadName, byte[]? payload, string doing)
    {
        var list = Ticked();
        if (list.Count == 0) return;
        if (list.FirstOrDefault(x => x.Busy) is { } b) throw new FormatException($"{b.Host} is still working. Wait for it, or press Stop waiting.");
        foreach (var x in list)
        {
            try { SshRun.Check(x.Target); }
            catch (FormatException ex) { throw new FormatException($"{x.Host}: {ex.Message}"); }
            if (x.KeyFile.Length > 0 && !S.Files.Exists(x.KeyFile)) throw new FormatException($"{x.Host}: the key file is missing.");
        }
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptIX", "ssh");
        var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var dir = Path.Combine(root, stamp);
        for (int i = 2; Directory.Exists(dir); i++) { dir = Path.Combine(root, $"{stamp}_{i}"); }
        if (payload != null) S.Files.WriteAllBytes(Path.Combine(dir, payloadName), payload);
        var bat = Path.Combine(dir, "run.cmd");
        S.Files.WriteAllText(bat, SshRun.Batch(list.Select(x => x.Target).ToList(), job, stamp, "Finished. Go back to ScriptIX."));
        foreach (var x in list) { x.State = doing + "…"; x.Busy = true; }
        S.Shell.RunInWindow(bat);
        Status("ssh runs in its own window. Type the password there.");
        _ = SafeAsync("reading the results", () => Watch(list, dir, stamp, job.Results.Length > 0, watch.Token));
    }

    /// <summary>Picks up every server's result as the ssh window writes it.</summary>
    async Task Watch(List<ServerItem> list, string dir, string stamp, bool results, CancellationToken ct)
    {
        try
        {
            for (int k = 1; k <= list.Count; k++)
            {
                var x = list[k - 1];
                var status = Path.Combine(dir, SshRun.StatusName(k));
                var csv = Path.Combine(dir, SshRun.CsvName(x.Host, stamp));
                while (!File.Exists(status)) await Task.Delay(700, ct);
                var rc = (await File.ReadAllTextAsync(status, ct)).Trim();
                if (results)
                {
                    if (File.Exists(csv)) { await Take(x, csv, stamp, ct); }
                    else x.State = rc == "255" ? "No connection" : rc == SshRun.NotInstalled.ToString() ? "Package not installed" : "No results";
                }
                else x.State = rc == "0" ? "Done" : rc == "255" ? "No connection" : rc == SshRun.NotInstalled.ToString() ? "Package not installed" : $"Failed (exit code {rc})";
                x.Busy = false;
                Save();
            }
            Status($"{list.Count} server(s) finished.");
        }
        finally { foreach (var x in list.Where(x => x.Busy)) { x.Busy = false; x.State = ""; } }
    }

    static async Task Take(ServerItem x, string csv, string stamp, CancellationToken ct)
    {
        try
        {
            var text = await File.ReadAllTextAsync(csv, ct);
            // the installed command says when the results are from
            var m = Regex.Match(text, @"^#scriptix (\d{8}_\d{6})\r?\n");
            if (m.Success)
            {
                var named = Path.Combine(Path.GetDirectoryName(csv)!, SshRun.CsvName(x.Host, m.Groups[1].Value));
                await File.WriteAllTextAsync(named, text[m.Length..], new System.Text.UTF8Encoding(false), ct);
                if (named != csv) File.Delete(csv);
                (csv, stamp) = (named, m.Groups[1].Value);
            }
            var s = await Task.Run(() => ResultsParser.Summarize(ResultsParser.Parse(m.Success ? text[m.Length..] : text)), ct);
            if (s.Total == 0) { x.State = "No results"; return; }
            x.TakeResults(csv, $"{stamp[..4]}-{stamp[4..6]}-{stamp[6..8]} {stamp[9..11]}:{stamp[11..13]}", s);
            x.State = "Done";
        }
        catch (FormatException) { x.State = "Unreadable results"; }
    }

    void StopWaiting()
    {
        watch.Cancel();
        watch = new CancellationTokenSource();
        Status("Not waiting any more. The ssh window goes on by itself.");
    }

    // ---------- side by side ----------
    public bool MatrixOpen { get => matrixOpen; set => Set(ref matrixOpen, value); }
    public string MatrixFilter { get => matrixFilter; set { if (Set(ref matrixFilter, value ?? MatrixAll)) OnPropertyChanged(nameof(MatrixRows)); } }
    public IReadOnlyList<string> MatrixServers => table?.Servers ?? Array.Empty<string>();
    public IReadOnlyList<FleetRow> MatrixRows => table == null ? Array.Empty<FleetRow>()
        : matrixFilter == MatrixDiffer ? table.Rows.Where(r => r.Differs).ToList()
        : matrixFilter == MatrixFailed ? table.Rows.Where(r => r.Failed).ToList() : table.Rows;
    public string MatrixText => table == null ? "" : $"{table.Servers.Count} servers, {table.Rows.Count} rules, {table.Rows.Count(r => r.Differs)} different, {table.Rows.Count(r => r.Failed)} failed somewhere";

    Task ShowMatrix() => SafeAsync("comparing the servers", async () =>
    {
        if (MatrixOpen) { MatrixOpen = false; return; }
        var pool = TickedCount > 0 ? Ticked() : VisibleServers.ToList();
        var with = pool.Where(x => x.HasResults && S.Files.Exists(x.LastFile)).ToList();
        if (with.Count == 0) { S.Dialogs.Message("These servers have no results yet. Scan them first."); return; }
        table = await Task.Run(() => FleetMatrix.Build(with.Select(x => new FleetResult(x.Host, ResultsParser.Parse(S.Files.ReadAllText(x.LastFile)))).ToList()));
        Close();
        foreach (var n in new[] { nameof(MatrixServers), nameof(MatrixRows), nameof(MatrixText) }) OnPropertyChanged(n);
        MatrixOpen = true;
    });

    void Close() { AddOpen = false; PackageOpen = false; MatrixOpen = false; }
}

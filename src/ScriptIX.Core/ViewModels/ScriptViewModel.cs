using System.Collections.ObjectModel;
using ScriptIX.Mvvm;
using ScriptIX.Packaging;

namespace ScriptIX.ViewModels;

public sealed class ScriptViewModel : ViewModelBase
{
    readonly List<ScriptJob> jobs = new();
    GeneratedScript? selected;
    bool stopOnFail, redact = true;
    int timeoutSeconds = 60;
    IReadOnlyList<RunStep> steps = Array.Empty<RunStep>();

    public ObservableCollection<GeneratedScript> Scripts { get; } = new();
    public ObservableCollection<string> Notes { get; } = new();
    public IReadOnlyList<int> TimeoutChoices { get; } = new[] { 0, 10, 30, 60, 120, 300, 600, 1800 };

    public RelayCommand SaveCommand { get; }
    public RelayCommand SaveAllCommand { get; }
    public RelayCommand SavePackagesCommand { get; }
    public RelayCommand CopyCommand { get; }
    public RelayCommand CopyHashCommand { get; }
    public RelayCommand CopyPasteBlockCommand { get; }
    public RelayCommand EmailCommand { get; }
    public RelayCommand EmailFillCommand { get; }
    public RelayCommand EmailOpenCommand { get; }
    public RelayCommand EmailSaveCommand { get; }
    public RelayCommand EmailMailToCommand { get; }
    public RelayCommand EmailCloseCommand { get; }
    public RelayCommand CopyTextCommand { get; }

    public RelayCommand SshCommand { get; }
    public RelayCommand SshRunCommand { get; }
    public RelayCommand SshKeyCommand { get; }
    public RelayCommand SshResultsCommand { get; }
    public RelayCommand SshCloseCommand { get; }

    public event EventHandler? OptionsChanged;
    /// Raised with the results file an SSH run brought back.
    public event Action<string>? ResultsReady;

    public ScriptViewModel(AppServices s) : base(s)
    {
        SaveCommand = new RelayCommand(() => Safe("saving the script", () => SaveOne(SelectedScript)), () => SelectedScript != null);
        SaveAllCommand = new RelayCommand(SaveAllToFolder, () => Scripts.Count > 0);
        SavePackagesCommand = new RelayCommand(SavePackages);
        CopyCommand = new RelayCommand(() => Copy(SelectedScript?.Content, "Script copied. Paste it into a file on the server with LF line endings."), () => SelectedScript != null);
        CopyHashCommand = new RelayCommand(() => Copy(SelectedScript?.Sha256, "SHA-256 copied."), () => SelectedScript != null);
        CopyTextCommand = new RelayCommand(p => Copy(p as string, "Command copied."));
        CopyPasteBlockCommand = new RelayCommand(CopyPasteBlock, () => SelectedScript != null);
        EmailCommand = new RelayCommand(() => { SshOpen = false; if (!EmailOpen && emailAuto) FillEmail(); EmailOpen = !EmailOpen; }, () => SelectedScript != null);
        EmailFillCommand = new RelayCommand(FillEmail);
        EmailOpenCommand = new RelayCommand(() => Safe("creating the e-mail", OpenEmail), () => Scripts.Count > 0);
        EmailSaveCommand = new RelayCommand(() => Safe("saving the e-mail", SaveEmail), () => Scripts.Count > 0);
        EmailMailToCommand = new RelayCommand(() => Safe("opening your mail app", () =>
        {
            S.Shell.OpenFile(EmailDraft.MailTo(EmailTo, EmailSubject, EmailBody));
            Status("Mail app opened without the attachment (links can't carry files). Attach the saved .sh yourself, or use Open in mail app.");
        }));
        EmailCloseCommand = new RelayCommand(() => EmailOpen = false);
        SshCommand = new RelayCommand(() => { EmailOpen = false; SshOpen = !SshOpen; }, () => SelectedScript != null);
        SshCloseCommand = new RelayCommand(() => SshOpen = false);
        SshKeyCommand = new RelayCommand(() => { if (S.Dialogs.PickFile("All files|*.*", "Pick your private key file") is { } p) SshKey = p; });
        SshRunCommand = new RelayCommand(() => Safe("starting ssh", RunSsh), () => SelectedScript != null);
        SshResultsCommand = new RelayCommand(() => Safe("opening the results", OpenSshResults), () => sshFolder.Length > 0);
    }

    public GeneratedScript? SelectedScript
    {
        get => selected;
        set
        {
            if (!Set(ref selected, value)) return;
            Steps = value == null ? Array.Empty<RunStep>() : BuildSteps(value);
            OnPropertyChanged(nameof(HasScript));
            SaveCommand.RaiseCanExecuteChanged();
            CopyCommand.RaiseCanExecuteChanged();
            CopyHashCommand.RaiseCanExecuteChanged();
            CopyPasteBlockCommand.RaiseCanExecuteChanged();
            EmailCommand.RaiseCanExecuteChanged();
            SshCommand.RaiseCanExecuteChanged();
            SshRunCommand.RaiseCanExecuteChanged();
        }
    }

    // ---------- run over SSH: ssh runs in a console window; passwords are typed there and never seen here ----------
    bool sshOpen, sshSudo;
    string sshHosts = "", sshUser = "root", sshPort = "22", sshKey = "", sshFolder = "";
    public bool SshOpen { get => sshOpen; set { if (Set(ref sshOpen, value)) OnPropertyChanged(nameof(ShowSteps)); } }
    public string SshHosts { get => sshHosts; set => Set(ref sshHosts, value ?? ""); }
    public string SshUser { get => sshUser; set => Set(ref sshUser, value ?? ""); }
    public string SshPort { get => sshPort; set => Set(ref sshPort, value ?? ""); }
    public string SshKey { get => sshKey; set => Set(ref sshKey, value ?? ""); }
    public bool SshSudo { get => sshSudo; set => Set(ref sshSudo, value); }

    internal static bool IsCheck(GeneratedScript g) => g.Kind is "check" or "oscap";

    void RunSsh()
    {
        var g = SelectedScript;
        if (g == null) return;
        int.TryParse(sshPort.Trim(), out var port);
        var target = new SshTarget(sshHosts, sshUser.Trim(), port, sshKey.Trim(), sshSudo);
        SshRun.Check(target);
        if (target.KeyFile.Length > 0 && !S.Files.Exists(target.KeyFile)) throw new FormatException("The key file is missing.");
        var hosts = SshRun.Hosts(sshHosts);
        if (!IsCheck(g) && !S.Dialogs.Confirm($"{g.FileName} changes the server. It will run on:\n\n{string.Join("\n", hosts.Take(15))}" +
            (hosts.Count > 15 ? $"\n... and {hosts.Count - 15} more" : "") + "\n\nThe script asks again in the window before it changes anything. Continue?")) return;
        var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptIX", "ssh", stamp);
        S.Files.WriteAllText(Path.Combine(dir, g.FileName), g.Content);
        var bat = Path.Combine(dir, "run.cmd");
        S.Files.WriteAllText(bat, SshRun.Batch(target, g.FileName, IsCheck(g), stamp));
        sshFolder = dir;
        SshResultsCommand.RaiseCanExecuteChanged();
        S.Shell.RunInWindow(bat);
        Status("ssh runs in its own window. Type the password there. When it has finished, press Open the results.");
    }

    void OpenSshResults()
    {
        var found = Directory.Exists(sshFolder) ? Directory.GetFiles(sshFolder, "results_*.csv") : Array.Empty<string>();
        if (found.Length == 0) { S.Dialogs.Message("No results yet. Wait until the ssh window says Finished."); return; }
        if (found.Length == 1) { ResultsReady?.Invoke(found[0]); return; }
        S.Shell.OpenFolder(sshFolder);
        Status($"{found.Length} results files are in the folder. Drop one on the window to open it.");
    }

// ---------- e-mail ----------
    bool emailOpen, emailAll = true, emailAsTxt, emailAuto = true;   // emailAuto: subject/body untouched by the user
    string emailTo = "", emailSubject = "", emailBody = "";
    public bool EmailOpen { get => emailOpen; set { if (Set(ref emailOpen, value)) OnPropertyChanged(nameof(ShowSteps)); } }
    public bool ShowSteps => !emailOpen && !sshOpen;
    public string EmailTo { get => emailTo; set => Set(ref emailTo, value ?? ""); }
    public string EmailSubject { get => emailSubject; set { if (Set(ref emailSubject, value ?? "")) emailAuto = false; } }
    public string EmailBody { get => emailBody; set { if (Set(ref emailBody, value ?? "")) emailAuto = false; } }
    /// <summary>Attach every script (apply, check, undo), not just the selected one.</summary>
    public bool EmailAll { get => emailAll; set { if (Set(ref emailAll, value) && emailAuto) FillEmail(); } }
    /// <summary>Attach as name.sh.txt: strict mail filters drop .sh attachments.</summary>
    public bool EmailAsTxt { get => emailAsTxt; set { if (Set(ref emailAsTxt, value) && emailAuto) FillEmail(); } }

    IReadOnlyList<GeneratedScript> EmailScripts() =>
        emailAll ? Scripts.ToList() : SelectedScript != null ? new[] { SelectedScript } : Array.Empty<GeneratedScript>();

    void FillEmail()
    {
        var list = EmailScripts();
        EmailSubject = EmailDraft.AutoSubject(list);
        EmailBody = EmailDraft.AutoBody(list, emailAsTxt);
        emailAuto = true;
    }

    string WriteEml(string path)
    {
        var list = EmailScripts();
        S.Files.WriteAllText(path, EmailDraft.Build(EmailTo, EmailSubject, EmailBody, list, emailAsTxt));
        return path;
    }

    void OpenEmail()
    {
        if (EmailScripts().Count == 0) return;
        var dir = Path.Combine(Path.GetTempPath(), "ScriptIX", "mail");
        var path = WriteEml(Path.Combine(dir, $"ScriptIX_{DateTime.Now:yyyyMMdd_HHmmss}.eml"));
        try { S.Shell.OpenFile(path); }
        catch (System.ComponentModel.Win32Exception)
        {
            S.Dialogs.Message("No mail app is set up to open .eml files on this PC.\n\nUse Save .eml and open it in your mail app, or use Open without attachment.");
            return;
        }
        Status("Draft opened in your mail app with the script(s) attached. Check it and press Send there. ScriptIX sends nothing itself.");
    }

    void SaveEmail()
    {
        if (EmailScripts().Count == 0) return;
        var path = S.Dialogs.PickSavePath($"ScriptIX_{DateTime.Now:yyyyMMdd_HHmm}.eml", "E-mail draft (*.eml)|*.eml");
        if (path == null) return;
        WriteEml(path);
        Status($"Saved {Path.GetFileName(path)}. Open it in Outlook, Thunderbird or Mail to send it.");
    }

    public IReadOnlyList<RunStep> Steps { get => steps; private set => Set(ref steps, value); }
    public bool HasScript => selected != null;
    public bool IsEmpty => Scripts.Count == 0;
    public bool HasNotes => Notes.Count > 0;
    public bool HasUnsaved => Scripts.Any(x => !x.Saved);

    public bool StopOnFail { get => stopOnFail; set { if (Set(ref stopOnFail, value)) Regenerate(); } }
    public bool Redact { get => redact; set { if (Set(ref redact, value)) Regenerate(); } }
    public int TimeoutSeconds { get => timeoutSeconds; set { if (Set(ref timeoutSeconds, Math.Clamp(value, 0, 86400))) Regenerate(); } }

    public void SetOptions(bool stop, int timeout, bool red)
    {
        stopOnFail = stop; timeoutSeconds = Math.Clamp(timeout, 0, 86400); redact = red;
        OnPropertyChanged(nameof(StopOnFail)); OnPropertyChanged(nameof(TimeoutSeconds)); OnPropertyChanged(nameof(Redact));
    }

    public void Show(IEnumerable<ScriptJob> newJobs, IEnumerable<string> notes)
    {
        jobs.Clear();
        jobs.AddRange(newJobs);
        Notes.Clear();
        foreach (var n in notes) Notes.Add(n);
        OnPropertyChanged(nameof(HasNotes));
        Build(null);
    }

    void Regenerate()
    {
        OptionsChanged?.Invoke(this, EventArgs.Empty);
        if (jobs.Count == 0) return;
        Safe("rebuilding the script", () => Build(SelectedScript?.FileName));
        Status("Script rebuilt with the new options. Save it again before copying it to the server.");
    }

    void Build(string? keepSelected)
    {
        Scripts.Clear();
        foreach (var j in jobs)
            Scripts.Add(ScriptBuilder.Build(j, new ScriptOptions(j.Kind, stopOnFail, j.RequireRoot, timeoutSeconds, redact, j.ReadOnly)));
        SelectedScript = Scripts.FirstOrDefault(x => x.FileName == keepSelected) ?? Scripts.FirstOrDefault();
        if (SelectedScript != null) Steps = BuildSteps(SelectedScript);
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(HasUnsaved));
        SaveAllCommand.RaiseCanExecuteChanged();
        EmailOpenCommand.RaiseCanExecuteChanged();
        EmailSaveCommand.RaiseCanExecuteChanged();
        if (emailAuto && emailSubject.Length > 0) FillEmail();   // keep the auto text in step with new scripts
    }

    static IReadOnlyList<RunStep> BuildSteps(GeneratedScript g)
    {
        var f = g.FileName;
        var steps = new List<(string What, string Cmd)>
        {
            ("Copy to the server", $"scp {f} root@SERVER:/root/"),
            ("Verify", $"sh {f} --verify"),
            ("Self-test (first time on a new OS)", $"sh {f} --selftest"),
        };
        if (IsCheck(g))
            steps.Add(("Run the checks", $"sh {f} -y"));
        else
        {
            steps.Add(("Preview", $"sh {f} --dry-run"));
            steps.Add(("Apply", $"sh {f}"));
            steps.Add(("Undo", $"sh {f} --undo scriptix_{g.Kind}_*/changes_*.manifest"));
        }
        steps.Add(("Bring the results back", $"scp root@SERVER:/root/scriptix_{g.Kind}_*/results_*.csv ."));
        return steps.Select((s, i) => new RunStep((i + 1).ToString(), s.What, s.Cmd)).ToList();
    }

void CopyPasteBlock()
    {
        var g = SelectedScript;
        if (g == null) return;
        var warn = PasteBlock.Warnings(g);
        var msg = $"Ready to paste: in your SSH session (in the folder you want, as root or with sudo -s) paste it. It writes {g.FileName}, checks its hash" +
                  (IsCheck(g) ? "." : " and runs --dry-run. Nothing is changed.");
        if (warn.Count > 0) msg += $" Careful: {string.Join("; ", warn)}. If --verify fails, use Save .sh and scp instead.";
        Copy(PasteBlock.Build(g), msg);
    }

    void Copy(string? text, string message)
    {
        if (string.IsNullOrEmpty(text)) return;
        if (Safe("copying to the clipboard", () => S.Clipboard.SetText(text))) Status(message);
    }

    bool SaveOne(GeneratedScript? sc)
    {
        if (sc == null) return true;
        var path = S.Dialogs.PickSavePath(sc.FileName, "Shell script (*.sh)|*.sh");
        if (path == null) return false;
        S.Files.WriteAllText(path, sc.Content);   // LF endings, UTF-8 without BOM
        sc.Saved = true;
        OnPropertyChanged(nameof(HasUnsaved));
        Status($"Saved {Path.GetFileName(path)}  (SHA-256 {sc.Sha256[..12]}...)");
        return true;
    }

    void SaveAllToFolder() => Safe("saving the scripts", () =>
    {
        var dir = S.Dialogs.PickFolder("Pick a folder for the scripts");
        if (dir == null) return;
        var existing = Scripts.Where(x => S.Files.Exists(Path.Combine(dir, x.FileName))).Select(x => x.FileName).ToList();
        if (existing.Count > 0 && !S.Dialogs.Confirm($"These files already exist and will be replaced:\n\n{string.Join("\n", existing)}\n\nContinue?")) return;
        foreach (var sc in Scripts)
        {
            S.Files.WriteAllText(Path.Combine(dir, sc.FileName), sc.Content);
            sc.Saved = true;
        }
        OnPropertyChanged(nameof(HasUnsaved));
        Status($"Saved {Scripts.Count} script(s) to {dir}");
        S.Shell.OpenFolder(dir);
    });

    // .deb, .rpm and the AIX installer, with every script on this page inside
    /// <summary>The SCAP file that is open on the Rules page, or "".</summary>
    public Func<string>? OpenScapPath { get; set; }

    /// <summary>Asks whether the open SCAP file goes into the packages. null = cancelled.</summary>
    public List<(string Name, byte[] Data)>? AskContent()
    {
        var path = OpenScapPath?.Invoke() ?? "";
        if (path.Length == 0 || !S.Files.Exists(path)) return new();
        return S.Dialogs.AskYesNoCancel($"Put {Path.GetFileName(path)} in the package too?\n\nThe server can then scan with it: scriptix eval --profile NAME") switch
        {
            Choice.Yes => Packages.ContentFiles(path, S.Files.OpenRead, S.Files.Exists),
            Choice.No => new(),
            _ => null
        };
    }

    void SavePackages() => Safe("making the packages", () =>
    {
        var dir = S.Dialogs.PickFolder("Pick a folder for the packages");
        if (dir == null) return;
        if (AskContent() is not { } content) return;
        var made = new Packages(Scripts.ToList(), DateTime.UtcNow, content).Build(Packages.Kinds);
        var sums = Path.Combine(dir, "SHA256SUMS");
        if (S.Files.Exists(sums) && !S.Dialogs.Confirm("There is a SHA256SUMS file in this folder already. Replace it?")) return;
        foreach (var (name, data) in made) S.Files.WriteAllBytes(Path.Combine(dir, name), data);
        Status(Scripts.Any(IsCheck) ? $"Packages saved to {dir}" : $"Packages saved to {dir}. The basic checks are inside.");
        S.Shell.OpenFolder(dir);
    });

    public bool SaveAll()
    {
        bool ok = true;
        Safe("saving the scripts", () => { foreach (var sc in Scripts.Where(x => !x.Saved).ToList()) ok &= SaveOne(sc); });
        return ok;
    }
}

using ScriptIX.Mvvm;

namespace ScriptIX.ViewModels;

public sealed record TutorialStep(string Icon, string Title, string Text, int Tab);

/// <summary>Short first-run walkthrough. Each step shows the page it talks about behind the card.</summary>
public sealed class TutorialViewModel : ObservableObject
{
    readonly IFileService files;
    readonly string seenPath;
    readonly Action<int> goToTab;
    int index;
    bool visible;

    public IReadOnlyList<TutorialStep> Steps { get; } = new TutorialStep[]
    {
        new(">_", "Welcome to ScriptIX", "Build one script that checks or hardens AIX, Linux and Unix servers. It runs on the server, not on this PC.", MainViewModel.TabRules),
        new("1", "Pick rules", "Drop a CIS PDF, SCAP .xml or CSV here. Choose a profile, then tick rules to fix, or press Check only to scan.", MainViewModel.TabRules),
        new("1", "Or type commands", "One command per line. Add  ## expect: text  to check the output.", MainViewModel.TabManual),
        new("2", "Get it on the server", "Copy ready to paste into your SSH session, Run over SSH, Save .sh, or Email it. Always --dry-run first.", MainViewModel.TabScript),
        new("3", "Many servers", "Save your servers here once. Scan them, install the scriptix package, and see their results side by side.", MainViewModel.TabServers),
        new("4", "See what happened", "Open the results_*.csv, add your names and logo, export it as PDF, Word or Excel, or fix only what failed.", MainViewModel.TabResults),
        new("?", "You're set", "Every option and marker is on the Help page. You can replay this intro there.", MainViewModel.TabHelp),
    };

    public RelayCommand NextCommand { get; }
    public RelayCommand BackCommand { get; }
    public RelayCommand SkipCommand { get; }
    public RelayCommand StartCommand { get; }

    public TutorialViewModel(IFileService files, Action<int> goToTab, string? seenPath = null)
    {
        this.files = files;
        this.goToTab = goToTab;
        this.seenPath = seenPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptIX", "intro_seen");
        NextCommand = new RelayCommand(() => { if (IsLast) Finish(); else Index++; }, () => visible);
        BackCommand = new RelayCommand(() => Index--, () => index > 0);
        SkipCommand = new RelayCommand(Finish, () => visible);   // Esc closes it only while it is open
        StartCommand = new RelayCommand(Start);
    }

    public bool Seen
    {
        get { try { return files.Exists(seenPath); } catch { return true; } }
    }

    public bool Visible
    {
        get => visible;
        private set { if (Set(ref visible, value)) { NextCommand.RaiseCanExecuteChanged(); SkipCommand.RaiseCanExecuteChanged(); } }
    }

    public int Index
    {
        get => index;
        private set
        {
            if (!Set(ref index, Math.Clamp(value, 0, Steps.Count - 1))) return;
            Changed();
        }
    }

    public TutorialStep Current => Steps[index];
    public bool IsLast => index == Steps.Count - 1;
    public string NextText => IsLast ? "Get started" : "Next";
    public IReadOnlyList<bool> Dots => Steps.Select((_, i) => i == index).ToList();

    public void Start()
    {
        index = 0;
        Changed();
        Visible = true;
    }

    void Changed()
    {
        OnPropertyChanged(nameof(Index));
        OnPropertyChanged(nameof(Current));
        OnPropertyChanged(nameof(IsLast));
        OnPropertyChanged(nameof(NextText));
        OnPropertyChanged(nameof(Dots));
        BackCommand.RaiseCanExecuteChanged();
        goToTab(Current.Tab);
    }

    void Finish()
    {
        Visible = false;
        goToTab(MainViewModel.TabRules);
        try { files.WriteAllText(seenPath, DateTime.Now.ToString("O")); } catch { /* not worth bothering the user */ }
    }
}

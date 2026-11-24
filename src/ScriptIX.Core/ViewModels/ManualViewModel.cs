using System.Collections.ObjectModel;
using ScriptIX.Mvvm;

namespace ScriptIX.ViewModels;

public sealed class ManualViewModel : ViewModelBase
{
    string text = "";
    int count, lines;

    public ObservableCollection<string> Warnings { get; } = new();
    public RelayCommand ImportCommand { get; }
    public RelayCommand ClearCommand { get; }
    public RelayCommand ExampleCommand { get; }
    public RelayCommand SaveCommand { get; }
    public event EventHandler? Changed;

    public ManualViewModel(AppServices s) : base(s)
    {
        ImportCommand = new RelayCommand(Import);
        ClearCommand = new RelayCommand(() =>
        {
            if (text.Length == 0 || S.Dialogs.Confirm("Clear all commands?")) CommandsText = "";
        }, () => text.Length > 0);
        ExampleCommand = new RelayCommand(() =>
        {
            if (text.Trim().Length == 0 || S.Dialogs.Confirm("Replace your commands with the example?"))
                CommandsText = Samples.ManualExample.Replace("\r\n", "\n").Replace("\n", Environment.NewLine);
        });
        SaveCommand = new RelayCommand(() => Safe("saving the commands", () =>
        {
            var path = S.Dialogs.PickSavePath("commands.txt", "Text (*.txt)|*.txt|Shell (*.sh)|*.sh");
            if (path != null) S.Files.WriteAllText(path, text.Replace("\r\n", "\n"));
        }), () => text.Length > 0);
    }

    public string CommandsText
    {
        get => text;
        set { if (Set(ref text, value ?? "")) Reparse(); }
    }

    public int CommandCount { get => count; private set { if (Set(ref count, value)) OnPropertyChanged(nameof(CounterText)); } }
    public int LineCount { get => lines; private set => Set(ref lines, value); }
    public string CounterText => CommandCount == 1 ? "1 command" : $"{CommandCount:N0} commands";
    public bool HasWarnings => Warnings.Count > 0;
    public bool IsEmpty => text.Trim().Length == 0;
    public List<ScriptItem> Items() => ManualParser.Parse(text);

    void Reparse()
    {
        var items = ManualParser.Parse(text);
        CommandCount = items.Count;
        LineCount = text.Length == 0 ? 0 : text.Count(c => c == '\n') + 1;
        Warnings.Clear();
        foreach (var w in Risk.WarningsFor(items, 30)) Warnings.Add("⚠ " + w);
        foreach (var w in Validator.Portability(items, 20)) Warnings.Add("ⓘ " + w);
        OnPropertyChanged(nameof(HasWarnings));
        OnPropertyChanged(nameof(IsEmpty));
        ClearCommand.RaiseCanExecuteChanged();
        SaveCommand.RaiseCanExecuteChanged();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    void Import() => Safe("importing the commands", () =>
    {
        var path = S.Dialogs.PickFile("Commands (*.txt;*.sh)|*.txt;*.sh|All files|*.*", "Import a command list");
        if (path == null) return;
        Load(S.Files.ReadAllText(path));
        Status($"Imported {CommandCount} commands from {Path.GetFileName(path)}.");
    });

    public void Load(string content)
    {
        if (text.Trim().Length > 0)
        {
            var c = S.Dialogs.AskYesNoCancel("You already have commands here.\n\nYes = replace them\nNo = add the new ones at the end");
            if (c == Choice.Cancel) return;
            if (c == Choice.No) { CommandsText = text.TrimEnd() + Environment.NewLine + content; return; }
        }
        CommandsText = content;
    }
}

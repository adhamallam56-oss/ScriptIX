using ScriptIX.Mvvm;

namespace ScriptIX.ViewModels;

public abstract class ViewModelBase : ObservableObject
{
    protected readonly AppServices S;
    protected ViewModelBase(AppServices services) => S = services;

    /// Raised with a short plain-words message for the status bar.
    public event Action<string>? StatusChanged;
    protected void Status(string text) => StatusChanged?.Invoke(text);

    protected bool Safe(string action, Action work)
    {
        try { work(); return true; }
        catch (OperationCanceledException) { Status("Cancelled."); return false; }
        catch (FormatException ex) when (ex.TargetSite?.Module.Assembly == typeof(ViewModelBase).Assembly) { S.Dialogs.Message(ex.Message); return false; }   // a message for the user, not a crash
        catch (Exception ex) { S.Crash.Write(action, ex); S.Dialogs.Message(Errors.Describe(ex, action)); return false; }
    }

    protected async Task<bool> SafeAsync(string action, Func<Task> work)
    {
        try { await work(); return true; }
        catch (OperationCanceledException) { Status("Cancelled."); return false; }
        catch (FormatException ex) when (ex.TargetSite?.Module.Assembly == typeof(ViewModelBase).Assembly) { S.Dialogs.Message(ex.Message); return false; }
        catch (Exception ex) { S.Crash.Write(action, ex); S.Dialogs.Message(Errors.Describe(ex, action)); return false; }
    }
}

/// A step on the "run it on the server" card: label plus a command the user can copy.
public sealed record RunStep(string Number, string Label, string Command);

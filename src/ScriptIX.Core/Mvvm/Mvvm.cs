using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace ScriptIX.Mvvm;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}

public sealed class RelayCommand : ICommand
{
    readonly Action<object?> exec;
    readonly Func<object?, bool>? can;

    public RelayCommand(Action exec, Func<bool>? can = null)
        : this(_ => exec(), can == null ? null : _ => can()) { }

    public RelayCommand(Action<object?> exec, Func<object?, bool>? can = null)
    {
        this.exec = exec;
        this.can = can;
    }

    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => can?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) { if (CanExecute(parameter)) exec(parameter); }
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

/// Async command with cancellation; it can't run twice at once. The parameter is passed through.
public sealed class AsyncRelayCommand : ObservableObject, ICommand
{
    readonly Func<object?, CancellationToken, Task> exec;
    readonly Func<bool>? can;
    CancellationTokenSource? cts;
    bool running;

    public AsyncRelayCommand(Func<CancellationToken, Task> exec, Func<bool>? can = null)
        : this((_, ct) => exec(ct), can) { }

    public AsyncRelayCommand(Func<object?, CancellationToken, Task> exec, Func<bool>? can = null)
    {
        this.exec = exec;
        this.can = can;
    }

    public bool IsRunning { get => running; private set => Set(ref running, value); }
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => !IsRunning && (can?.Invoke() ?? true);
    public void Execute(object? parameter) => _ = ExecuteAsync(parameter);
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    public void Cancel() => cts?.Cancel();

    public async Task ExecuteAsync(object? parameter = null)
    {
        if (!CanExecute(parameter)) return;
        IsRunning = true;
        cts = new CancellationTokenSource();
        RaiseCanExecuteChanged();
        try { await exec(parameter, cts.Token); }
        finally
        {
            IsRunning = false;
            cts.Dispose();
            cts = null;
            RaiseCanExecuteChanged();
        }
    }
}

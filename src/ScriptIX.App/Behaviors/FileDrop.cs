using System.Windows;
using System.Windows.Input;

namespace ScriptIX.App.Behaviors;

/// <summary>
/// Attached behavior: drop a file anywhere on the element and its path goes to a command.
/// Usage: b:FileDrop.Command="{Binding OpenPathCommand}". Keeps drag-and-drop out of code-behind.
/// </summary>
public static class FileDrop
{
    public static readonly DependencyProperty CommandProperty = DependencyProperty.RegisterAttached(
        "Command", typeof(ICommand), typeof(FileDrop), new PropertyMetadata(null, OnCommandChanged));

    public static ICommand? GetCommand(DependencyObject d) => (ICommand?)d.GetValue(CommandProperty);
    public static void SetCommand(DependencyObject d, ICommand? value) => d.SetValue(CommandProperty, value);

    static void OnCommandChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not UIElement el) return;
        el.PreviewDragOver -= OnDragOver;
        el.PreviewDrop -= OnDrop;
        if (e.NewValue == null) return;
        el.AllowDrop = true;
        el.PreviewDragOver += OnDragOver;
        el.PreviewDrop += OnDrop;
    }

    static void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    static void OnDrop(object sender, DragEventArgs e)
    {
        if (sender is not DependencyObject d || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Handled = true;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } files) return;
        var cmd = GetCommand(d);
        if (cmd?.CanExecute(files[0]) == true) cmd.Execute(files[0]);
    }
}

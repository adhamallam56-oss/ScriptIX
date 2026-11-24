using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace ScriptIX.App.Behaviors;

/// <summary>
/// Attached behavior: one result column per server after the fixed columns of a DataGrid.
/// Usage: b:MatrixColumns.Servers="{Binding MatrixServers}"; the rows have a Results list.
/// </summary>
public static class MatrixColumns
{
    public static readonly DependencyProperty ServersProperty = DependencyProperty.RegisterAttached(
        "Servers", typeof(IReadOnlyList<string>), typeof(MatrixColumns), new PropertyMetadata(null, OnChanged));

    public static IReadOnlyList<string>? GetServers(DependencyObject d) => (IReadOnlyList<string>?)d.GetValue(ServersProperty);
    public static void SetServers(DependencyObject d, IReadOnlyList<string>? value) => d.SetValue(ServersProperty, value);

    static readonly DependencyProperty FixedProperty = DependencyProperty.RegisterAttached("Fixed", typeof(int), typeof(MatrixColumns), new PropertyMetadata(-1));

    static void OnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not DataGrid grid) return;
        if ((int)grid.GetValue(FixedProperty) < 0)
        {
            if (!grid.IsInitialized) { grid.Initialized += (_, _) => Fill(grid); return; }   // its own columns are not there yet
        }
        Fill(grid);
    }

    static void Fill(DataGrid grid)
    {
        var count = (int)grid.GetValue(FixedProperty);
        if (count < 0) grid.SetValue(FixedProperty, count = grid.Columns.Count);
        while (grid.Columns.Count > count) grid.Columns.RemoveAt(grid.Columns.Count - 1);
        int i = 0;
        foreach (var name in GetServers(grid) ?? Array.Empty<string>())
        {
            var path = $"Results[{i++}]";
            var style = new Style(typeof(DataGridCell), grid.TryFindResource(typeof(DataGridCell)) as Style);
            void Color(string value, string back, string fore)
            {
                var t = new DataTrigger { Binding = new Binding(path), Value = value };
                t.Setters.Add(new Setter(Control.BackgroundProperty, (Brush)grid.FindResource(back)));
                t.Setters.Add(new Setter(Control.ForegroundProperty, (Brush)grid.FindResource(fore)));
                style.Triggers.Add(t);
            }
            Color("PASS", "OkSoft", "Ok");
            Color("FAIL", "BadSoft", "Bad");
            grid.Columns.Add(new DataGridTextColumn
            {
                Header = new TextBlock { Text = name, ToolTip = name, TextTrimming = TextTrimming.CharacterEllipsis },   // a TextBlock: "_" in a name is no access key
                Binding = new Binding(path), Width = 110, CellStyle = style, SortMemberPath = path, ClipboardContentBinding = new Binding(path)
            });
        }
    }
}

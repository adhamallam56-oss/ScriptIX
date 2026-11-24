using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media.Imaging;

namespace ScriptIX.App;

/// <summary>Lets things outside the visual tree (DataGrid columns) bind to the page's view model.</summary>
public sealed class BindingProxy : System.Windows.Freezable
{
    public static readonly System.Windows.DependencyProperty DataProperty =
        System.Windows.DependencyProperty.Register(nameof(Data), typeof(object), typeof(BindingProxy));
    public object? Data { get => GetValue(DataProperty); set => SetValue(DataProperty, value); }
    protected override System.Windows.Freezable CreateInstanceCore() => new BindingProxy();
}

public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

/// null -> Collapsed, anything else -> Visible
public sealed class NullToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object parameter, CultureInfo culture) =>
        value == null ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

/// empty string -> Visible (for placeholder text), otherwise Collapsed
public sealed class EmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object parameter, CultureInfo culture) =>
        string.IsNullOrEmpty(value as string) ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

/// picture bytes -> thumbnail; a damaged picture shows nothing instead of failing
public sealed class ThumbnailConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not byte[] { Length: > 0 } data) return null;
        try
        {
            var b = new BitmapImage();
            b.BeginInit();
            b.CacheOption = BitmapCacheOption.OnLoad;
            b.DecodePixelHeight = 160;
            b.StreamSource = new System.IO.MemoryStream(data);
            b.EndInit();
            b.Freeze();
            return b;
        }
        catch (Exception) { return null; }
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

/// 60 -> "60 seconds", 0 -> "No limit"
public sealed class TimeoutTextConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        0 => "No limit",
        int s when s % 60 == 0 && s >= 120 => $"{s / 60} minutes",
        int s => $"{s} seconds",
        _ => ""
    };
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

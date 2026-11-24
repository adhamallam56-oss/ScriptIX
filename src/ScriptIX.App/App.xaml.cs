using System.Windows;
using System.Windows.Threading;
using ScriptIX.ViewModels;

namespace ScriptIX.App;

/// Composition root: the only place that creates services and view-models.
public partial class App : Application
{
    readonly FileCrashLog crash = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        DispatcherUnhandledException += OnDispatcherException;
        AppDomain.CurrentDomain.UnhandledException += (_, a) =>
            crash.Write("unhandled exception", a.ExceptionObject as Exception ?? new Exception(a.ExceptionObject?.ToString()));
        TaskScheduler.UnobservedTaskException += (_, a) =>
        {
            crash.Write("background task", a.Exception);
            a.SetObserved();
        };

        var files = new DiskFileService();
        var services = new AppServices(new Services.WpfDialogService(), files, new Services.WpfClipboardService(),
                                       crash, new Services.WindowsShell());
        var vm = new MainViewModel(services, new AutosaveService(files));

        var window = new Views.MainWindow { DataContext = vm };
        window.Closing += (_, ev) => ev.Cancel = !vm.ConfirmClose();
        MainWindow = window;
        window.Show();

        // A file passed on the command line (or "Open with") is opened like a dropped file.
        // Then the user clearly wants that file, so don't ask about restoring the last session.
        if (e.Args.Length > 0 && System.IO.File.Exists(e.Args[0])) vm.OpenPath(e.Args[0]);
        else
        {
            vm.OfferRestore();   // always first: skipping it would let autosave replace the earlier session
            if (!vm.Tutorial.Seen) vm.Tutorial.Start();
        }
    }

    void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        crash.Write("user interface", e.Exception);
        e.Handled = true;   // keep the app open
        MessageBox.Show(
            "Something went wrong. Your work is safe and the app is still open.\n\nDetails were saved to:\n" + crash.Location,
            AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}

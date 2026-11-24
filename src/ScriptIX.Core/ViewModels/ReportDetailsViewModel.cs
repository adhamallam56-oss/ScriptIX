using System.Collections.ObjectModel;
using ScriptIX.Mvvm;

namespace ScriptIX.ViewModels;

/// <summary>Who made the report and what it shows: title, names, organisation, notes, logo, pictures.</summary>
public sealed class ReportDetailsViewModel : ViewModelBase
{
    public const int MaxPictures = 8;
    const string ImageFilter = "Pictures (*.png;*.jpg;*.jpeg;*.gif;*.bmp)|*.png;*.jpg;*.jpeg;*.gif;*.bmp";

    readonly ReportDetailsStore store;
    string title, names, organization, notes;
    ReportImage? logo;
    bool isOpen, dirty;

    public ObservableCollection<ReportImage> Pictures { get; } = new();

    public RelayCommand OpenCommand { get; }
    public RelayCommand DoneCommand { get; }
    public RelayCommand PickLogoCommand { get; }
    public RelayCommand RemoveLogoCommand { get; }
    public RelayCommand AddPictureCommand { get; }
    public RelayCommand RemovePictureCommand { get; }

    public ReportDetailsViewModel(AppServices s, ReportDetailsStore? store = null) : base(s)
    {
        this.store = store ?? new ReportDetailsStore(s.Files);
        var d = this.store.Load();
        (title, names, organization, notes, logo) = (d.Title ?? "", d.Names ?? "", d.Organization ?? "", d.Notes ?? "", d.Logo);
        foreach (var p in d.Pictures) { p.PropertyChanged += (_, _) => dirty = true; Pictures.Add(p); }

        OpenCommand = new RelayCommand(() => IsOpen = true);
        DoneCommand = new RelayCommand(() => { Save(); IsOpen = false; });
        PickLogoCommand = new RelayCommand(() =>
        {
            var path = S.Dialogs.PickFile(ImageFilter, "Pick a logo");
            if (path != null) Safe("reading the logo", () => Logo = ReportImage.Load(S.Files, path));
        });
        RemoveLogoCommand = new RelayCommand(() => Logo = null);
        AddPictureCommand = new RelayCommand(() =>
        {
            var path = S.Dialogs.PickFile(ImageFilter, "Add a picture");
            if (path != null) AddPicture(path);
        }, () => Pictures.Count < MaxPictures);
        RemovePictureCommand = new RelayCommand(p =>
        {
            if (p is not ReportImage img || !Pictures.Remove(img)) return;
            dirty = true;
            AddPictureCommand.RaiseCanExecuteChanged();
        });
    }

    public bool IsOpen { get => isOpen; private set => Set(ref isOpen, value); }
    public string Title { get => title; set { if (Set(ref title, value ?? "")) dirty = true; } }
    public string Names { get => names; set { if (Set(ref names, value ?? "")) dirty = true; } }
    public string Organization { get => organization; set { if (Set(ref organization, value ?? "")) dirty = true; } }
    public string Notes { get => notes; set { if (Set(ref notes, value ?? "")) dirty = true; } }
    public ReportImage? Logo
    {
        get => logo;
        private set { if (Set(ref logo, value)) { dirty = true; OnPropertyChanged(nameof(HasLogo)); } }
    }
    public bool HasLogo => logo != null;

    public void AddPicture(string path) => Safe("reading the picture", () =>
    {
        if (Pictures.Count >= MaxPictures) throw new FormatException($"A report can hold up to {MaxPictures} pictures. Remove one first.");
        var img = ReportImage.Load(S.Files, path);
        img.PropertyChanged += (_, _) => dirty = true;
        Pictures.Add(img);
        dirty = true;
        AddPictureCommand.RaiseCanExecuteChanged();
    });

    public ReportDetails Snapshot() => new()
    {
        Title = title, Names = names, Organization = organization, Notes = notes, Logo = logo, Pictures = Pictures.ToList()
    };

    public void Save()
    {
        if (!dirty) return;
        if (Safe("saving the report details", () => store.Save(Snapshot()))) dirty = false;
    }
}

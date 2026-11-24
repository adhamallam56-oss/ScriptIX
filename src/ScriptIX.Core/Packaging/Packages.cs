using System.Formats.Tar;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ScriptIX.Packaging;

/// <summary>One file in a package. Directories end with "/" and have no data.</summary>
public sealed record PackageFile(string Path, byte[] Data, int Mode)
{
    public bool IsDir => Path.EndsWith('/');
    public string Clean => Path.TrimEnd('/');
}

/// <summary>
/// Installable packages with the "scriptix" command and the scripts made in the app: .deb, .rpm, and an installer that
/// builds a .bff on AIX with AIX's own tools. The .deb and .rpm are written here directly, so no Linux is needed.
/// </summary>
public sealed class Packages
{
    public const string Name = "scriptix";
    public const string Fileset = "scriptix.rte";
    const string Summary = "Check and harden this server with ScriptIX scripts";
    const string Description = "The scriptix command scans this server with the check scripts made in ScriptIX, keeps the results,\n" +
                               "shows what changed, and can scan on a schedule. It needs only sh and the system's own tools.";

    readonly DateTime built;
    readonly List<PackageFile> files = new();

    public string Version { get; }
    /// <summary>Grows with every build, so a newer package always upgrades an older one.</summary>
    public string Release { get; }
    /// <summary>AIX levels are four numbers of at most 2, 2, 4 and 4 digits: version, days since 2020, minute of the day.</summary>
    public string Vrmf { get; }

    public Packages(IReadOnlyList<GeneratedScript> scripts, DateTime builtUtc) : this(scripts.Select(s => (s.FileName, s.Content)).ToList(), builtUtc) { }

    public Packages(IReadOnlyList<(string Name, string Content)> scripts, DateTime builtUtc)
    {
        built = DateTime.SpecifyKind(builtUtc, DateTimeKind.Utc);
        Version = AppInfo.Version;
        Release = built.ToString("yyyyMMdd.HHmmss");
        var v = Version.Split('.');
        Vrmf = $"{v[0]}.{v[1]}.{(int)(built - new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalDays}.{built.Hour * 60 + built.Minute}";

        files.Add(new("/usr/bin/scriptix", Lf(Command($"{Version}-{Release}")), 0b111_101_101));
        files.Add(new("/usr/share/man/man8/scriptix.8", Lf(ManPage()), 0b110_100_100));
        files.Add(new("/usr/share/scriptix/", Array.Empty<byte>(), 0b111_101_101));
        files.Add(new("/usr/share/scriptix/scripts/", Array.Empty<byte>(), 0b111_000_000));   // your own commands can be private
        foreach (var (name, content) in scripts)
        {
            if (!Regex.IsMatch(name, @"^[A-Za-z0-9][A-Za-z0-9._-]{0,60}\.sh$")) throw new FormatException($"\"{name}\" can't be used as a file name in a package.");
            if (!content.Contains("\n#__SCRIPTIX_BODY__\n")) throw new FormatException($"{name} isn't a ScriptIX script.");
            if (files.Any(f => f.Path.EndsWith("/" + name, StringComparison.Ordinal))) throw new FormatException($"{name} is there twice.");
            files.Add(new("/usr/share/scriptix/scripts/" + name, Utf8(content), 0b111_000_000));
        }
        files.Sort((a, b) => string.CompareOrdinal(a.Clean, b.Clean));
    }

    public string DebName => $"{Name}_{Version}-{Release}_all.deb";
    public string RpmName => $"{Name}-{Version}-{Release}.noarch.rpm";
    /// <summary>AIX installs noarch packages made for AIX 6.1 on every later level.</summary>
    public string AixRpmName => $"{Name}-{Version}-{Release}{AixOs}.noarch.rpm";
    const string AixOs = ".aix6.1";
    public string AixName => $"{Name}-{Vrmf}-aix.sh";
    public string BffName => $"{Fileset}.{Vrmf}.bff";

    static byte[] Utf8(string s) => new UTF8Encoding(false).GetBytes(s);
    static byte[] Lf(string s) => Utf8(s.Replace("\r\n", "\n"));
    static string Read(string resource)
    {
        using var r = new StreamReader(typeof(Packages).Assembly.GetManifestResourceStream(resource)!, Encoding.UTF8);
        return r.ReadToEnd().Replace("\r\n", "\n");
    }
    static string Command(string version) => Read("ScriptIX.scriptix.sh").Replace("{{PKGVERSION}}", version);
    static string ManPage() => """
        .TH SCRIPTIX 8
        .SH NAME
        scriptix \- run the ScriptIX scripts installed on this server
        .SH SYNOPSIS
        .B scriptix
        .I command
        [options]
        .SH DESCRIPTION
        Scans this server with the check scripts made in ScriptIX, keeps the results, and shows what changed.
        Run
        .B scriptix help
        for the list of commands.
        .SH FILES
        .TP
        .I /usr/share/scriptix/scripts
        the scripts from the package
        .TP
        .I /var/lib/scriptix/scripts
        added scripts
        .TP
        .I /var/lib/scriptix/runs
        results, logs and backups. They stay when the package is removed.

        """.Replace("\r\n", "\n");

    // removing the package stops the scheduled scan; an upgrade does not
    const string StopSchedule = "if [ -x /usr/bin/scriptix ]; then /usr/bin/scriptix schedule off >/dev/null 2>&1 || :; fi\n";

    // ------------------------------------------------------------------ .deb

    public byte[] Deb()
    {
        var kb = files.Sum(f => (f.Data.Length + 1023) / 1024 + (f.IsDir ? 1 : 0));
        var control = $"Package: {Name}\nVersion: {Version}-{Release}\nArchitecture: all\nMaintainer: ScriptIX <root@localhost>\n" +
                      $"Installed-Size: {kb}\nSection: admin\nPriority: optional\nDescription: {Summary}\n" +
                      string.Concat(Description.Split('\n').Select(l => " " + l + "\n"));
        var md5 = string.Concat(DebFiles().Where(f => !f.IsDir).Select(f => $"{Hex(MD5.HashData(f.Data))}  {f.Path[1..]}\n"));
        var ctl = Tar(new PackageFile[]
        {
            new("/control", Utf8(control), 0b110_100_100), new("/md5sums", Utf8(md5), 0b110_100_100),
            new("/prerm", Utf8("#!/bin/sh\nset -e\nif [ \"$1\" = remove ]; then " + StopSchedule.TrimEnd('\n') + "; fi\nexit 0\n"), 0b111_101_101)
        }, false);
        using var ms = new MemoryStream();
        ms.Write("!<arch>\n"u8);
        void Member(string name, byte[] d)
        {
            var secs = new DateTimeOffset(built).ToUnixTimeSeconds();
            ms.Write(Encoding.ASCII.GetBytes($"{name,-16}{secs,-12}{0,-6}{0,-6}{"100644",-8}{d.Length,-10}`\n"));
            ms.Write(d);
            if (d.Length % 2 == 1) ms.WriteByte((byte)'\n');
        }
        Member("debian-binary", "2.0\n"u8.ToArray());
        Member("control.tar.gz", Gzip(ctl));
        Member("data.tar.gz", Gzip(Tar(DebFiles(), true)));
        return ms.ToArray();
    }

    // Debian wants compressed man pages and a copyright file
    List<PackageFile> DebFiles()
    {
        var l = files.Select(f => f.Path.EndsWith(".8", StringComparison.Ordinal) ? f with { Path = f.Path + ".gz", Data = Gzip(f.Data) } : f).ToList();
        l.Add(new("/usr/share/doc/scriptix/", Array.Empty<byte>(), 0b111_101_101));
        l.Add(new("/usr/share/doc/scriptix/copyright", Utf8("ScriptIX. The scripts in this package were made with the ScriptIX app.\n"), 0b110_100_100));
        l.Sort((a, b) => string.CompareOrdinal(a.Clean, b.Clean));
        return l;
    }

    byte[] Tar(IEnumerable<PackageFile> list, bool parents)
    {
        using var ms = new MemoryStream();
        using (var w = new TarWriter(ms, TarEntryFormat.Ustar, true))
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            void Add(string path, byte[]? data, int mode)
            {
                if (!seen.Add(path)) return;
                var e = new UstarTarEntry(data == null ? TarEntryType.Directory : TarEntryType.RegularFile, "." + path + (data == null ? "/" : ""))
                { Uid = 0, Gid = 0, UserName = "root", GroupName = "root", Mode = (UnixFileMode)mode, ModificationTime = new DateTimeOffset(built) };
                if (data != null) e.DataStream = new MemoryStream(data);
                w.WriteEntry(e);
            }
            if (parents) Add("", null, 0b111_101_101);
            foreach (var f in list)
            {
                if (parents)
                    for (int i = f.Path.IndexOf('/', 1); i > 0 && i < f.Clean.Length; i = f.Path.IndexOf('/', i + 1))
                        if (list.All(x => x.Clean != f.Path[..i])) Add(f.Path[..i], null, 0b111_101_101);
                Add(f.Clean, f.IsDir ? null : f.Data, f.Mode);
            }
        }
        return ms.ToArray();
    }

    static byte[] Gzip(byte[] d)
    {
        using var ms = new MemoryStream();
        using (var z = new GZipStream(ms, CompressionLevel.SmallestSize, true)) z.Write(d);
        return ms.ToArray();
    }
    static string Hex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();

    // ------------------------------------------------------------------ .rpm (format 3, as rpm 4.6 and newer read it)

    sealed class Header
    {
        readonly SortedDictionary<int, (int Type, int Count, byte[] Data)> tags = new();
        public void Str(int tag, string s) => tags[tag] = (6, 1, Utf8(s + "\0"));
        public void I18n(int tag, string s) => tags[tag] = (9, 1, Utf8(s + "\0"));
        public void StrArr(int tag, IEnumerable<string> s) { var l = s.ToList(); tags[tag] = (8, l.Count, Utf8(string.Concat(l.Select(x => x + "\0")))); }
        public void Bin(int tag, byte[] b) => tags[tag] = (7, b.Length, b);
        public void Int32(int tag, params int[] v) => tags[tag] = (4, v.Length, v.SelectMany(Be32).ToArray());
        public void Int16(int tag, params int[] v) => tags[tag] = (3, v.Length, v.SelectMany(x => new[] { (byte)(x >> 8), (byte)x }).ToArray());

        /// <param name="region">62 = signature, 63 = main header</param>
        public byte[] Bytes(int region)
        {
            using var store = new MemoryStream();
            using var index = new MemoryStream();
            var entries = new List<byte[]>();
            foreach (var (tag, (type, count, data)) in tags)
            {
                var align = type == 4 ? 4 : type == 3 ? 2 : 1;
                while (store.Length % align != 0) store.WriteByte(0);
                entries.Add(Be32(tag).Concat(Be32(type)).Concat(Be32((int)store.Length)).Concat(Be32(count)).ToArray());
                store.Write(data);
            }
            int n = entries.Count + 1;
            int regionAt = (int)store.Length;
            store.Write(Be32(region).Concat(Be32(7)).Concat(Be32(-n * 16)).Concat(Be32(16)).ToArray());   // region trailer
            var head = new List<byte> { 0x8e, 0xad, 0xe8, 0x01, 0, 0, 0, 0 };
            head.AddRange(Be32(n)); head.AddRange(Be32((int)store.Length));
            head.AddRange(Be32(region).Concat(Be32(7)).Concat(Be32(regionAt)).Concat(Be32(16)));
            foreach (var e in entries) head.AddRange(e);
            head.AddRange(store.ToArray());
            return head.ToArray();
        }
    }
    static byte[] Be32(int v) => new[] { (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v };

    /// <param name="aix">for AIX: its operating system name, its root group, and MD5 file digests that its older rpm can read</param>
    public byte[] Rpm(bool aix = false)
    {
        var release = Release + (aix ? AixOs : "");
        var time = (int)new DateTimeOffset(built).ToUnixTimeSeconds();
        var cpio = Cpio(time);
        var payload = Gzip(cpio);
        int size = files.Sum(f => f.IsDir ? 0 : f.Data.Length);
        var dirs = files.Select(Dir).Distinct().OrderBy(x => x, StringComparer.Ordinal).ToList();

        var h = new Header();
        h.StrArr(100, new[] { "C" });
        h.Str(1000, Name); h.Str(1001, Version); h.Str(1002, release);
        h.I18n(1004, Summary); h.I18n(1005, Description.Replace("\n", " "));
        h.Int32(1006, time); h.Str(1007, "scriptix"); h.Int32(1009, size);
        h.Str(1014, "Unspecified"); h.I18n(1016, "Applications/System");
        h.Str(1021, aix ? AixOs[1..] : "linux"); h.Str(1022, "noarch");
        h.Str(1025, "if [ \"$1\" = 0 ]; then " + StopSchedule.TrimEnd('\n') + "; fi\nexit 0\n"); h.Str(1087, "/bin/sh");
        int N = files.Count;
        h.Int32(1028, files.Select(f => f.IsDir ? 4096 : f.Data.Length).ToArray());
        h.Int16(1030, files.Select(RpmMode).ToArray());
        h.Int16(1033, new int[N]);
        h.Int32(1034, Enumerable.Repeat(time, N).ToArray());
        h.StrArr(1035, files.Select(f => f.IsDir ? "" : Hex(aix ? MD5.HashData(f.Data) : SHA256.HashData(f.Data))));
        h.StrArr(1036, files.Select(_ => ""));
        h.Int32(1037, files.Select(f => f.Path.Contains("/man/") ? 2 : 0).ToArray());   // 2 = documentation
        h.StrArr(1039, files.Select(_ => "root")); h.StrArr(1040, files.Select(_ => aix ? "system" : "root"));
        h.Str(1044, $"{Name}-{Version}-{release}.src.rpm");
        h.Int32(1045, Enumerable.Repeat(-1, N).ToArray());
        h.StrArr(1047, new[] { Name });
        var needs = new List<(int Flag, string What, string Version)> { (0x200, "/bin/sh", ""), (0x100000A, "rpmlib(CompressedFileNames)", "3.0.4-1") };
        if (!aix) needs.Add((0x100000A, "rpmlib(FileDigests)", "4.6.0-1"));
        needs.Add((0x100000A, "rpmlib(PayloadFilesHavePrefix)", "4.0-1"));
        h.Int32(1048, needs.Select(x => x.Flag).ToArray()); h.StrArr(1049, needs.Select(x => x.What)); h.StrArr(1050, needs.Select(x => x.Version));
        h.Str(1064, "4.6.0");
        h.Int32(1095, Enumerable.Repeat(1, N).ToArray());
        h.Int32(1096, Enumerable.Range(1, N).ToArray());
        h.StrArr(1097, files.Select(_ => ""));
        h.Int32(1112, 8); h.StrArr(1113, new[] { $"{Version}-{release}" });
        h.Int32(1116, files.Select(f => dirs.IndexOf(Dir(f))).ToArray());
        h.StrArr(1117, files.Select(f => f.Clean[(f.Clean.LastIndexOf('/') + 1)..]));
        h.StrArr(1118, dirs);
        h.Str(1124, "cpio"); h.Str(1125, "gzip"); h.Str(1126, "9");
        if (!aix) h.Int32(5011, 8);                                                // file digests are SHA-256 (none = MD5)
        h.Str(5062, "utf-8");
        h.StrArr(5092, new[] { Hex(SHA256.HashData(payload)) }); h.Int32(5093, 8);
        var header = h.Bytes(63);

        var s = new Header();
        s.Str(269, Hex(SHA1.HashData(header)));
        s.Str(273, Hex(SHA256.HashData(header)));
        s.Int32(1000, header.Length + payload.Length);
        s.Bin(1004, MD5.HashData(header.Concat(payload).ToArray()));
        s.Int32(1007, cpio.Length);
        var sig = s.Bytes(62);

        using var ms = new MemoryStream();
        var lead = new byte[96];
        new byte[] { 0xed, 0xab, 0xee, 0xdb, 3, 0, 0, 0, 0, 1 }.CopyTo(lead, 0);
        var nm = Encoding.ASCII.GetBytes($"{Name}-{Version}-{release}");
        Array.Copy(nm, 0, lead, 10, Math.Min(nm.Length, 65));
        lead[77] = (byte)(aix ? 5 : 1); lead[79] = 5;
        ms.Write(lead);
        ms.Write(sig);
        while (ms.Length % 8 != 0) ms.WriteByte(0);
        ms.Write(header);
        ms.Write(payload);
        return ms.ToArray();
    }

    static string Dir(PackageFile f) => f.Clean[..(f.Clean.LastIndexOf('/') + 1)];
    static int RpmMode(PackageFile f) => (f.IsDir ? 0x4000 : 0x8000) | f.Mode;

    byte[] Cpio(int time)
    {
        using var ms = new MemoryStream();
        void Pad() { while (ms.Length % 4 != 0) ms.WriteByte(0); }
        void Entry(string name, byte[] data, int mode, int ino, int nlink, int mtime)
        {
            var b = Utf8(name + "\0");
            ms.Write(Encoding.ASCII.GetBytes($"070701{ino:x8}{mode:x8}{0:x8}{0:x8}{nlink:x8}{mtime:x8}{data.Length:x8}{0:x8}{0:x8}{0:x8}{0:x8}{b.Length:x8}{0:x8}"));
            ms.Write(b); Pad();
            ms.Write(data); Pad();
        }
        int i = 0;
        foreach (var f in files) Entry("." + f.Clean, f.Data, RpmMode(f), ++i, f.IsDir ? 2 : 1, time);
        Entry("TRAILER!!!", Array.Empty<byte>(), 0, 0, 1, 0);
        return ms.ToArray();
    }

    // ------------------------------------------------------------------ AIX

    /// <summary>
    /// A .bff is an AIX "backup" archive whose header checksum is not documented, so AIX's own backup command writes it:
    /// this script holds the files and control files, and makes the .bff (or installs it) on any AIX 7.1 or newer.
    /// </summary>
    public string AixInstaller()
    {
        // on AIX everything is in the usr part; /var/lib/scriptix is made by the command itself
        var list = files.Where(f => f.Path.StartsWith("/usr/", StringComparison.Ordinal)).ToList();
        // AIX has these already; only our own folders belong to the fileset
        var blocks = list.Where(f => !f.IsDir).GroupBy(Dir).OrderBy(g => g.Key, StringComparer.Ordinal)
            .Select(g => (Dir: g.Key.TrimEnd('/'), N: g.Sum(f => Math.Max(8, (f.Data.Length + 4095) / 4096 * 8)))).ToList();   // 4 KB pieces, in 512-byte blocks
        var sizes = string.Concat(blocks.Select(b => $"{b.Dir} {b.N}\n")) + "/usr/lib/objrepos 8\n";
        var inst = 8 + (list.Count * 400 + 4095) / 4096 * 8;
        var lppName = $"4 R I {Name} {{\n{Fileset} {Vrmf} 01 N U en_US ScriptIX checks and hardening\n[\n*prereq bos.rte 7.1.0.0\n%\n{sizes}INSTWORK {inst} {inst}\n%\n%\n%\n]\n}}\n";
        var inventory = string.Concat(list.Select(f =>
            $"{f.Clean}:\n          owner = root\n          group = system\n          mode = {Convert.ToString(f.Mode, 8)}\n          type = {(f.IsDir ? "DIRECTORY" : "FILE")}\n" +
            $"          class = apply,inventory,{Fileset}\n" + (f.IsDir ? "" : "          size = VOLATILE\n          checksum = VOLATILE\n") + "\n"));
        var al = string.Concat(list.Select(f => "." + f.Clean + "\n"));

        var b = new StringBuilder(Read("ScriptIX.aix.sh")
            .Replace("{{VRMF}}", Vrmf).Replace("{{FILESET}}", Fileset).Replace("{{BFF}}", BffName).Replace("{{NAME}}", Name)
            .Replace("{{VERSION}}", $"{Version}-{Release}"));
        var payload = new StringBuilder();
        void Put(string path, byte[] data, int mode)
        {
            var text = Encoding.UTF8.GetString(data);
            if (!text.EndsWith('\n')) text += "\n";
            var end = "SCRIPTIX_END_OF_FILE";
            while (("\n" + text).Contains("\n" + end + "\n")) end += "_";
            payload.Append($"cat > '{path}' <<'{end}' || fail \"cannot write {path}\"\n{text}{end}\nchmod {Convert.ToString(mode, 8)} '{path}' || fail \"chmod {path}\"\n");
        }
        foreach (var d in list.Select(f => f.IsDir ? f.Clean : Dir(f).TrimEnd('/')).Distinct().OrderBy(x => x, StringComparer.Ordinal))
            payload.Append($"mkdir -p '.{d}' || fail \"mkdir {d}\"\n");
        foreach (var f in list) if (f.IsDir) payload.Append($"chmod {Convert.ToString(f.Mode, 8)} '.{f.Clean}'\n"); else Put("." + f.Clean, f.Data, f.Mode);
        Put("lpp_name", Utf8(lppName), 0b110_100_100);
        payload.Append("mkdir -p ./usr/lpp/" + Name + " .ctl || fail \"mkdir\"\n");
        Put($".ctl/{Fileset}.copyright", Utf8("ScriptIX. The scripts in this package were made with the ScriptIX app.\n"), 0b110_100_100);
        Put($".ctl/{Fileset}.inventory", Utf8(inventory), 0b110_100_100);
        Put($".ctl/{Fileset}.al", Utf8(al), 0b110_100_100);
        Put($".ctl/{Fileset}.size", Utf8(sizes), 0b110_100_100);
        Put($".ctl/{Fileset}.unconfig", Utf8("#!/bin/sh\n# the package is being removed: stop the scheduled scan\n" + StopSchedule + "exit 0\n"), 0b111_101_101);
        return b.Replace("{{PAYLOAD}}", payload.ToString()).ToString();
    }

    // ------------------------------------------------------------------ all together

    /// <summary>The three packages and a small script that installs the right one on the server it runs on.</summary>
    /// <param name="dailyAt">"HH:MM" to scan every day, or ""</param>
    public byte[] Bundle(string dailyAt)
    {
        if (dailyAt.Length > 0) CheckTime(dailyAt);
        var after = "scriptix version || exit 1\n" + (dailyAt.Length > 0 ? $"scriptix schedule daily {dailyAt} || exit 1\n" : "");
        var install = $$"""
            #!/bin/sh
            # installs the package that fits this server
            PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
            [ "`id -u`" = 0 ] || { echo 'Run as root.' >&2; exit 3; }
            case "`uname -s`" in
              AIX) sh ./scriptix-aix.sh --install || exit 1 ;;
              Linux)
                if [ -f /etc/debian_version ] && [ -x /usr/bin/dpkg ]; then dpkg -i ./scriptix.deb || exit 1
                elif [ -x /usr/bin/rpm ] || [ -x /bin/rpm ]; then rpm -Uvh --oldpackage --replacepkgs ./scriptix.rpm || exit 1
                else echo 'No dpkg and no rpm here. Use the .sh scripts instead.' >&2; exit 3; fi ;;
              *) echo 'There is no package for this system. Use the .sh scripts instead.' >&2; exit 3 ;;
            esac

            """.Replace("\r\n", "\n") + after;
        return Tar(new PackageFile[]
        {
            new("/install.sh", Utf8(install), 0b111_000_000), new("/scriptix-aix.sh", Utf8(AixInstaller()), 0b111_000_000),
            new("/scriptix.deb", Deb(), 0b110_000_000), new("/scriptix.rpm", Rpm(), 0b110_000_000)
        }, false);
    }

    public static void CheckTime(string t)
    {
        if (!Regex.IsMatch(t, "^([01][0-9]|2[0-3]):[0-5][0-9]$")) throw new FormatException("The time must look like 02:30.");
    }

    public static readonly string[] Kinds = { "deb", "rpm", "aixrpm", "aix" };

    /// <summary>File name -> content for the kinds asked for, plus SHA256SUMS.</summary>
    public List<(string Name, byte[] Data)> Build(IEnumerable<string> kinds)
    {
        var l = new List<(string, byte[])>();
        foreach (var k in kinds)
            l.Add(k switch { "deb" => (DebName, Deb()), "rpm" => (RpmName, Rpm()), "aixrpm" => (AixRpmName, Rpm(true)), "aix" => (AixName, Utf8(AixInstaller())),
                             _ => throw new FormatException($"Unknown package type: {k} (use deb, rpm, aixrpm or aix)") });
        l.Add(("SHA256SUMS", Utf8(string.Concat(l.Select(x => $"{Hex(SHA256.HashData(x.Item2))}  {x.Item1}\n")))));
        return l;
    }
}

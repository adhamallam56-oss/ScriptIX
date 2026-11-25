using System.Globalization;
using System.Text;
using ScriptIX;
using ScriptIX.Packaging;
using ScriptIX.Scap;

// Headless ScriptIX: the same Core as the app, for automation and CI.

static int Usage(string? error = null)
{
    if (error != null) Console.Error.WriteLine("Error: " + error);
    Console.Error.WriteLine("""
usage:
  scriptix-cli generate INPUT [--out DIR] [--profile ID] [--all] [--check | --check-only] [--timeout N] [--stop-on-fail] [--no-redact]
      INPUT: rules .csv/.json, SCAP .xml, CIS benchmark .pdf (experimental), or a command list .txt/.sh
      Rules: the ticked rules are used (--all: every rule with a fix; risky ones too, so be careful).
      --check-only: one script that checks every rule of the profile and changes nothing.
  scriptix-cli validate INPUT       report status counts, problems and portability notes
  scriptix-cli profiles FILE.xml|.pdf  list the profiles in a SCAP file or CIS PDF

 SCAP (also for generate: --tailoring FILE, --set NAME=VALUE, --benchmark ID)
  scriptix-cli info FILE.xml                                     what is in the file
  scriptix-cli check-content FILE.xml                            find broken references and duplicate ids
  scriptix-cli guide FILE.xml [--profile ID] [--out F.html]      security guide
  scriptix-cli fix FILE.xml --type bash|ansible|puppet|kubernetes|ignition|blueprint|kickstart|bootc [--profile ID] [--results F] [--out F]
  scriptix-cli tailor FILE.xml [--profile ID] [--select A,B] [--unselect C,D] [--title T] [--out F.xml]
  scriptix-cli oscap FILE.xml [--profile ID] [--out DIR]         a script that runs the server's own oscap
  scriptix-cli report RESULTS.csv|.xml [--content FILE.xml] [--profile ID] [--xccdf F] [--arf F] [--html F] [--csv F] [--json F] [--md F] [--docx F] [--xlsx F]
  scriptix-cli compare NOW BEFORE                                what changed between two runs
  scriptix-cli cvss VECTOR                                       CVSS 2.0 / 3.0 / 3.1 score

 Servers
  scriptix-cli package [SCRIPT.sh...] [--content FILE.xml] [--type deb,rpm,aixrpm,aix] [--out DIR]   packages with the scriptix command, these scripts and SCAP files
  scriptix-cli matrix RESULTS... [--out F.csv]                   several servers' results side by side
  scriptix-cli version
""");
    return 2;
}

var a = args.ToList();
if (a.Count == 0) return Usage();
string? Opt(string name)
{
    int i = a.IndexOf(name);
    if (i < 0) return null;
    if (i + 1 >= a.Count) throw new ArgumentException($"{name} needs a value");
    var v = a[i + 1]; a.RemoveRange(i, 2); return v;
}
bool Flag(string name) => a.Remove(name);

List<string> Many(string name)
{
    var l = new List<string>();
    while (Opt(name) is { } v) l.Add(v);
    return l;
}

XccdfProfile? FindProfile(XccdfDocument doc, string? name) => name == null ? null
    : doc.Profiles.FirstOrDefault(x => x.Id == name || x.Title.Equals(name, StringComparison.OrdinalIgnoreCase) || x.Id.EndsWith("_profile_" + name, StringComparison.Ordinal))
      ?? throw new ArgumentException($"profile not found: {name}");

XccdfRule FindRule(XccdfDocument doc, string name) => doc.Rules.FirstOrDefault(r => r.Id == name) ?? doc.Rules.FirstOrDefault(r => r.ShortId == name)
      ?? throw new ArgumentException($"rule not found: {name}");

// --tailoring, --set and --benchmark work for every command that reads SCAP content
ImportReport LoadScap(string file)
{
    var tailoring = Opt("--tailoring"); var bench = Opt("--benchmark"); var sets = Many("--set");
    using var st = File.OpenRead(file);
    var rep = XccdfImporter.Load(st, file, default, null, bench);
    var doc = rep.Scap!;
    if (tailoring != null) { using var t = File.OpenRead(tailoring); Tailoring.Load(doc, t); }
    foreach (var pair in sets)
    {
        var i = pair.IndexOf('=');
        if (i <= 0) throw new ArgumentException("--set needs NAME=VALUE");
        var v = doc.Values.Values.FirstOrDefault(x => x.Id == pair[..i] || x.Id.EndsWith("_value_" + pair[..i], StringComparison.Ordinal))
                ?? throw new ArgumentException($"value not found: {pair[..i]}");
        doc.Overrides[v.Id] = pair[(i + 1)..];
    }
    if (doc.Overrides.Count > 0 && doc.Prebuilt == null) { rep.Rules.Clear(); rep.Rules.AddRange(doc.ToRules(null)); }
    return rep;
}

(List<ResultRow> Rows, string Name) LoadResults(string file)
{
    if (!Path.GetExtension(file).Equals(".xml", StringComparison.OrdinalIgnoreCase)) return (ResultsParser.Parse(File.ReadAllText(file)), Path.GetFileName(file));
    using var st = File.OpenRead(file);
    var l = ScapResults.Read(st);
    return (l.Rows, ScapResults.SourceName(l, Path.GetFileName(file)));
}

void Output(string? path, string text)
{
    if (path == null) { Console.OutputEncoding = new UTF8Encoding(false); Console.Write(text); return; }
    File.WriteAllText(path, text, new UTF8Encoding(false));
    Console.Error.WriteLine("Wrote " + path);
}

try
{
    var cmd = a[0]; a.RemoveAt(0);
    switch (cmd)
    {
        case "version":
            Console.WriteLine($"{AppInfo.Name} {AppInfo.Version}");
            return 0;

        case "profiles":
        {
            if (a.Count < 1) return Usage("profiles needs one .xml or .pdf file");
            ImportReport rep;
            if (Path.GetExtension(a[0]).Equals(".pdf", StringComparison.OrdinalIgnoreCase)) { using var st = File.OpenRead(a[0]); rep = CisPdfImporter.Load(st, a[0]); }
            else rep = LoadScap(a[0]);
            foreach (var p in rep.Scap!.Profiles) Console.WriteLine($"{p.Id}\t{p.Title}\t{p.Selected.Count} rules");
            return 0;
        }

        case "cvss":
        {
            if (a.Count != 1) return Usage("cvss needs one vector");
            var c = Cvss.Score(a[0]);
            string N(double? d) => d?.ToString("0.0", CultureInfo.InvariantCulture) ?? "-";
            Console.WriteLine($"CVSS {c.Version}  base {N(c.Base)}  temporal {N(c.Temporal)}  environmental {N(c.Environmental)}  overall {N(c.Overall)} {c.Rating}");
            return 0;
        }

        case "info":
        {
            if (a.Count < 1) return Usage("info needs one file");
            var f = a[0]; a.RemoveAt(0);
            Output(Opt("--out"), ScapExport.Info(LoadScap(f).Scap!));
            return 0;
        }

        case "check-content":
        {
            if (a.Count != 1) return Usage("check-content needs one file");
            using var st = File.OpenRead(a[0]);
            var dir = Path.GetDirectoryName(Path.GetFullPath(a[0]))!;
            var bad = ScapExport.Validate(st, n => File.Exists(Path.Combine(dir, n)) ? File.OpenRead(Path.Combine(dir, n)) : null);
            foreach (var b in bad) Console.WriteLine(b);
            Console.Error.WriteLine(bad.Count == 0 ? "OK" : $"{bad.Count} problem(s)");
            return bad.Count == 0 ? 0 : 1;
        }

        case "guide":
        case "fix":
        case "tailor":
        case "oscap":
        {
            if (a.Count < 1) return Usage(cmd + " needs one SCAP file");
            var f = a[0]; a.RemoveAt(0);
            var pname = Opt("--profile"); var output = Opt("--out"); var type = Opt("--type") ?? "bash"; var results = Opt("--results");
            var on = Opt("--select"); var off = Opt("--unselect"); var title = Opt("--title");
            var tailored = a.IndexOf("--tailoring") is >= 0 and var ti && ti + 1 < a.Count ? a[ti + 1] : null;
            var doc = LoadScap(f).Scap!;
            if (a.Count > 0) return Usage("unknown option: " + a[0]);
            var p = FindProfile(doc, pname);
            var rules = new HashSet<string>(p?.Selected ?? doc.DefaultSelection(), StringComparer.Ordinal);
            if (cmd == "guide") Output(output, ScapExport.Guide(doc, p, rules, DateTime.Now));
            else if (cmd == "fix")
            {
                if (results != null)
                {
                    var failed = LoadResults(results).Rows.Where(r => r.Result == "FAIL").Select(r => r.Id).ToHashSet(StringComparer.Ordinal);
                    rules.RemoveWhere(id => !failed.Contains(ScriptBuilder.SafeId(id, 0)) && !failed.Contains(ScriptBuilder.SafeId(XccdfImporter.Short(id, "_rule_"), 0)));
                }
                Output(output, ScapExport.Fixes(doc, p, type, rules));
            }
            else if (cmd == "tailor")
            {
                foreach (var id in (on ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries)) rules.Add(FindRule(doc, id.Trim()).Id);
                foreach (var id in (off ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries)) rules.Remove(FindRule(doc, id.Trim()).Id);
                Output(output, Tailoring.Write(doc, p, title ?? (p != null ? p.Title + " (tailored)" : "Custom profile"), rules, DateTime.Now));
            }
            else
            {
                var item = ScapExport.OscapCommand(doc, p, Path.GetFileName(f), tailored == null ? null : Path.GetFileName(tailored));
                var g = ScriptBuilder.Build(new ScriptJob("scriptix_oscap.sh", "oscap", new[] { item }, true, true), new ScriptOptions("oscap", TimeoutSeconds: 7200, ReadOnly: true));
                Directory.CreateDirectory(output ?? ".");
                var path = Path.Combine(output ?? ".", g.FileName);
                new DiskFileService().WriteAllText(path, g.Content);
                Console.WriteLine(path);
            }
            return 0;
        }

        case "report":
        {
            if (a.Count < 1) return Usage("report needs one results file");
            var f = a[0]; a.RemoveAt(0);
            var content = Opt("--content"); var pname = Opt("--profile");
            var want = new[] { "--xccdf", "--arf", "--html", "--csv", "--json", "--md", "--docx", "--xlsx", "--txt" }.Select(n => (n, Opt(n))).Where(x => x.Item2 != null).ToList();
            var (rows, name) = LoadResults(f);
            var doc = content == null ? null : LoadScap(content).Scap;
            if (a.Count > 0) return Usage("unknown option: " + a[0]);
            if (doc != null && !ScapResults.Fits(rows, doc)) throw new ArgumentException("these results don't belong to this SCAP content");
            var p = doc == null ? null : FindProfile(doc, pname);
            var data = new ReportData(rows, name, DateTime.Now, new ReportDetails());
            foreach (var (n, path) in want)
            {
                if (n is "--docx" or "--xlsx") { File.WriteAllBytes(path!, n == "--docx" ? ReportExport.Docx(data) : ReportExport.Xlsx(data)); Console.Error.WriteLine("Wrote " + path); continue; }
                Output(path, n switch
                {
                    "--xccdf" => ScapResults.Xccdf(rows, doc, p, name, DateTime.Now, null),
                    "--arf" => ScapResults.Arf(rows, doc, p, name, DateTime.Now, null),
                    "--html" => HtmlReport.Build(rows, name, DateTime.Now),
                    "--csv" => ReportExport.CsvText(data),
                    "--json" => ReportExport.Json(data),
                    "--md" => ReportExport.Markdown(data, ""),
                    _ => ReportExport.Text(data)
                });
            }
            var s = ResultsParser.Summarize(rows);
            Console.WriteLine($"{s.Total} rules: {s.Passed} passed, {s.Failed} failed, {s.Skipped} skipped");
            foreach (var sc in ScapResults.Scores(rows, doc, p))
                Console.WriteLine(FormattableString.Invariant($"{sc.System}\t{sc.Score:0.######}/{sc.Maximum:0.######}"));
            return 0;
        }

        case "compare":
        {
            if (a.Count != 2) return Usage("compare needs two results files: NOW BEFORE");
            var now = LoadResults(a[0]).Rows; var before = LoadResults(a[1]).Rows;
            var (better, worse, other) = ResultsCompare.Apply(now, before);
            foreach (var r in now.Where(r => r.Changed)) Console.WriteLine($"{r.Id}\t{r.Before} -> {r.ResultText}");
            foreach (var r in before.Where(b => now.All(n => n.Id != b.Id))) Console.WriteLine($"{r.Id}\t{r.ResultText} -> (gone)");
            Console.Error.WriteLine($"{better} now pass, {worse} now fail, {other} other change(s)");
            return 0;
        }

        case "package":
        {
            var types = (Opt("--type") ?? string.Join(',', Packages.Kinds)).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var dir = Opt("--out") ?? ".";
            var content = new List<(string Name, byte[] Data)>();
            while (Opt("--content") is { } scap) content.AddRange(Packages.ContentFiles(scap, File.OpenRead, File.Exists).Where(x => content.All(c => c.Name != x.Name)));
            if (a.FirstOrDefault(x => x.StartsWith('-')) is { } badOpt) return Usage("unknown option: " + badOpt);
            var pk = new Packages(a.Select(f => (Path.GetFileName(f), File.ReadAllText(f))).ToList(), DateTime.UtcNow, content);
            Directory.CreateDirectory(dir);
            foreach (var (n, data) in pk.Build(types))
            {
                File.WriteAllBytes(Path.Combine(dir, n), data);
                Console.WriteLine(Path.Combine(dir, n));
            }
            return 0;
        }

        case "matrix":
        {
            var path = Opt("--out");
            if (a.Count < 1) return Usage("matrix needs results files");
            var sets = a.Select(f => { var (rows, _) = LoadResults(f); return new FleetResult(ResultsParser.Describe(Path.GetFileName(f)).Host is { Length: > 0 } h ? h : Path.GetFileNameWithoutExtension(f), rows); }).ToList();
            Output(path, FleetMatrix.Csv(FleetMatrix.Build(sets)));
            return 0;
        }

        case "validate":
        case "generate":
        {
            var outDir = Opt("--out") ?? ".";
            var profile = Opt("--profile");
            var timeout = int.Parse(Opt("--timeout") ?? "60", System.Globalization.CultureInfo.InvariantCulture);
            bool all = Flag("--all"), check = Flag("--check"), checkOnly = Flag("--check-only"), stop = Flag("--stop-on-fail"), noRedact = Flag("--no-redact");
            if (a.Count < 1) return Usage("give exactly one input file");
            var input = a[0]; a.RemoveAt(0);
            var ext = Path.GetExtension(input).ToLowerInvariant();

            var jobs = new List<ScriptJob>();
            if (ext is ".txt" or ".sh")
            {
                var items = ManualParser.Parse(File.ReadAllText(input));
                jobs.Add(new ScriptJob("scriptix_commands.sh", "manual", items));
            }
            else
            {
                ImportReport rep;
                if (ext == ".xml") rep = LoadScap(input);
                else if (ext == ".pdf") { using var st = File.OpenRead(input); rep = CisPdfImporter.Load(st, input); }
                else if (ext == ".json") rep = RuleImporter.FromJson(File.ReadAllText(input), input);
                else rep = RuleImporter.FromCsv(File.ReadAllText(input), input);

                var rules = rep.Rules;
                if (profile != null)
                {
                    var p = rep.Scap?.Profiles.FirstOrDefault(x => x.Id == profile || x.Title.Equals(profile, StringComparison.OrdinalIgnoreCase) || x.Id.EndsWith("_profile_" + profile, StringComparison.Ordinal))
                            ?? throw new ArgumentException($"profile not found: {profile} (run: scriptix-cli profiles {input})");
                    rules = rep.Scap!.ToRules(p);
                }
                if (a.Count > 0) return Usage("unknown option: " + a[0]);
                Console.Error.WriteLine(rep.ToText());
                if (checkOnly)
                {
                    var list = profile != null ? rules.Where(r => r.InProfile) : rules;   // like oscap xccdf eval
                    jobs.Add(new ScriptJob("scriptix_check.sh", "check", ScriptBuilder.CheckItems(list, true), false, true));
                }
                var chosen = checkOnly ? new List<RuleItem>() : all ? rules.Where(r => r.Remediation.Length > 0).ToList() : rules.Where(r => r.Selected).ToList();
                if (chosen.Count == 0 && !checkOnly) throw new ArgumentException("no rules are ticked (use --profile for SCAP files, or --all)");
                if (!checkOnly) jobs.Add(new ScriptJob("scriptix_apply.sh", "apply", ScriptBuilder.ApplyItems(chosen)));
                var checks = ScriptBuilder.CheckItems(chosen);
                if (check && checks.Count > 0) jobs.Add(new ScriptJob("scriptix_check.sh", "check", checks, false, true));
                var undo = ScriptBuilder.UndoItems(chosen);
                if (undo.Count > 0) jobs.Add(new ScriptJob("scriptix_undo_rules.sh", "undo-rules", undo));
            }

            int problems = 0;
            foreach (var j in jobs)
            {
                foreach (var b in Validator.Blocking(j.Items)) { Console.Error.WriteLine("BLOCKING " + b); problems++; }
                foreach (var w in Validator.Warnings(j.Items)) Console.Error.WriteLine("warning  " + w);
                foreach (var p in Validator.Portability(j.Items, 1000)) Console.Error.WriteLine("portable " + p);
            }
            if (problems > 0) return 1;
            if (cmd == "validate") { Console.Error.WriteLine("OK"); return 0; }

            Directory.CreateDirectory(outDir);
            foreach (var j in jobs)
            {
                var g = ScriptBuilder.Build(j, new ScriptOptions(j.Kind, stop, j.RequireRoot, timeout, !noRedact, j.ReadOnly));
                var path = Path.Combine(outDir, g.FileName);
                new DiskFileService().WriteAllText(path, g.Content);
                Console.WriteLine($"{path}\t{g.Count} commands\tsha256 {g.Sha256}");
            }
            return 0;
        }
        default:
            return Usage($"unknown command: {cmd}");
    }
}
catch (Exception ex) when (ex is ArgumentException or FormatException or IOException or UnauthorizedAccessException
                              or System.Xml.XmlException or System.Text.Json.JsonException)
{
    Console.Error.WriteLine("Error: " + ex.Message);
    return 1;
}

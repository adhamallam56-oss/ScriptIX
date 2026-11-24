using System.Globalization;
using System.Xml.Linq;
using ScriptIX.Scap;

namespace ScriptIX;

/// <summary>
/// Reads XCCDF benchmarks, SCAP data streams (ssg-*-ds.xml) and OVAL definition files.
/// DTDs and external entities are refused; only files next to the benchmark are opened.
/// </summary>
public static class XccdfImporter
{
    public static ImportReport Load(Stream stream, string source, CancellationToken ct = default, Func<string, Stream?>? sibling = null, string? benchmarkId = null)
    {
        if (sibling == null && source.Length > 0 && Path.GetDirectoryName(source) is { } dir)
            sibling = name =>
            {
                var p = Path.Combine(dir, name);
                return File.Exists(p) && new FileInfo(p).Length <= ScapSource.MaxSize ? File.OpenRead(p) : null;
            };
        var src = ScapSource.Load(stream, sibling, ct, benchmarkId);
        if (src.Benchmark != null) return LoadBenchmark(src, source, ct);
        if (src.OvalFiles.Count > 0) return LoadOval(src, source, ct);
        throw new FormatException(src.Kind switch
        {
            "XCCDF tailoring" => "This is a tailoring file. Open the benchmark first, then use SCAP > Load tailoring.",
            "XCCDF results" or "ARF results" => "This is a results file. Open it on the Results page.",
            "CPE dictionary" or "OCIL questionnaires" => $"This is a {src.Kind} file. Open the XCCDF benchmark or data stream that uses it.",
            "CVRF advisory" => "CVRF advisories hold no checks, so there is nothing to run.",
            _ => "No XCCDF rules were found. Use an XCCDF benchmark, a SCAP data stream (for example ssg-rhel9-ds.xml) or an OVAL file."
        });
    }

    static ImportReport LoadBenchmark(ScapSource src, string source, CancellationToken ct)
    {
        var b = src.Benchmark!;
        var doc = new XccdfDocument
        {
            Source = src,
            Id = b.At("id"),
            FileName = Path.GetFileName(source),
            Title = b.El("title").Text(),
            Description = Cut(b.El("description").Text(), 1500),
            Version = b.El("version").Text(),
            Status = string.Join(", ", b.Els("status").Select(s => s.Text() + (s.At("date").Length > 0 ? " " + s.At("date") : "")))
        };
        foreach (var p in b.Els("platform")) if (p.At("idref").Length > 0) doc.Platforms.Add(p.At("idref"));
        foreach (var p in b.Els("plain-text")) doc.PlainTexts[p.At("id")] = p.Value;
        Walk(b, null, doc);
        if (doc.Rules.Count == 0)
            throw new FormatException("No XCCDF rules were found in this benchmark.");
        foreach (var f in doc.Rules.SelectMany(r => r.Checks).SelectMany(c => c.DescendantsAndSelf()).Where(e => e.Name.LocalName == "check-content-ref")
                              .Select(e => e.At("href")).Distinct().ToList())
            src.Find(f);
        doc.Oval = new OvalLibrary(src.OvalFiles);
        foreach (var p in b.Els("Profile")) doc.Profiles.Add(ParseProfile(p, false));
        doc.ResolveProfiles();
        doc.Profiles.RemoveAll(p => X.IsTrue(b.Els("Profile").First(e => e.At("id") == p.Id).At("abstract")));
        doc.Target = GuessTarget(doc);

        var rep = new ImportReport { Source = source, Scap = doc };
        rep.Rules.AddRange(doc.ToRules(null, ct));
        rep.Notes.Add($"Benchmark: {(doc.Title.Length > 0 ? doc.Title : "(no title)")}, {doc.Profiles.Count} profile(s).");
        rep.Notes.Add("Nothing is ticked yet: pick a profile.");
        Summary(rep, doc);
        if (src.Benchmarks.Count > 1) rep.Notes.Add($"The file holds {src.Benchmarks.Count} benchmarks; this is {doc.Id}.");
        return rep;
    }

    static void Summary(ImportReport rep, XccdfDocument doc)
    {
        int oval = rep.Rules.Count(r => r.Mode == CompareMode.Oval), gaps = rep.Rules.Count(r => r.CheckGap.Length > 0),
            manual = rep.Rules.Count(r => r.ManualCheck.Length > 0), noFix = rep.Rules.Count(r => r.Remediation.Length == 0);
        rep.Notes.Add($"{oval} rule(s) have an automatic OVAL check, {manual} must be checked by hand.");
        if (gaps > 0)
        {
            var what = rep.Rules.Where(r => r.CheckGap.Length > 0).SelectMany(r => r.CheckGap.Split(", ")).GroupBy(g => g).OrderByDescending(g => g.Count()).Take(6);
            rep.Notes.Add($"{gaps} check(s) use OVAL tests ScriptIX can't run fully ({string.Join(", ", what.Select(g => g.Key))}); these parts end as NOT-CHECKED, never as a pass.");
        }
        if (noFix > 0) rep.Notes.Add($"{noFix} rule(s) have no shell fix.");
        var missing = doc.Source?.MissingFiles().Take(4).ToList();
        if (missing is { Count: > 0 }) rep.Notes.Add($"Not found next to the benchmark: {string.Join(", ", missing)}. Checks that need them must be done by hand.");
        if (doc.UnknownPlatforms.Count > 0) rep.Notes.Add($"Unknown platform(s), not used to skip rules: {string.Join(", ", doc.UnknownPlatforms.Take(4))}.");
    }

    static void Walk(XElement parent, XccdfGroup? group, XccdfDocument doc)
    {
        foreach (var e in parent.Elements())
            switch (e.Name.LocalName)
            {
                case "Group":
                    var g = new XccdfGroup
                    {
                        Id = e.At("id"), Title = e.El("title").Text(), Description = Cut(e.El("description").Text(), 800),
                        DefaultSelected = !X.IsFalse(e.At("selected")), Weight = Weight(e), Parent = group
                    };
                    foreach (var p in e.Els("platform")) g.Platforms.Add(p.At("idref"));
                    if (e.At("cluster-id").Length > 0) g.Clusters.Add(e.At("cluster-id"));
                    doc.Groups.Add(g);
                    Walk(e, g, doc);
                    break;
                case "Rule":
                    if (!X.IsTrue(e.At("abstract")) && !X.IsTrue(e.At("hidden"))) doc.Rules.Add(ParseRule(e, group));
                    break;
                case "Value":
                    var v = ParseValue(e);
                    doc.Values[v.Id] = v;
                    break;
            }
    }

    static double Weight(XElement e) =>
        double.TryParse(e.At("weight"), NumberStyles.Float, CultureInfo.InvariantCulture, out var w) && w >= 0 ? w : 1;

    public static string Short(string id, string marker)
    {
        int i = id.LastIndexOf(marker, StringComparison.Ordinal);
        return i >= 0 ? id[(i + marker.Length)..] : id;
    }

    static string Cut(string s, int n) => s.Length > n ? s[..n] + "..." : s;

    static XccdfRule ParseRule(XElement x, XccdfGroup? parent)
    {
        var id = x.At("id");
        var rule = new XccdfRule
        {
            Id = id,
            ShortId = Short(id, "_rule_"),
            Title = x.El("title") is { } t && t.Text().Length > 0 ? t.Text() : id,
            Severity = x.At("severity"),
            Role = x.At("role"),
            Description = Cut(x.El("description").Text(), 1500),
            Rationale = Cut(x.El("rationale").Text(), 1500),
            DefaultSelected = !X.IsFalse(x.At("selected")),
            Weight = Weight(x),
            Parent = parent
        };
        foreach (var p in x.Els("platform")) rule.Platforms.Add(p.At("idref"));
        foreach (var q in x.Els("requires")) rule.Requires.Add(q.At("idref").Split(' ', StringSplitOptions.RemoveEmptyEntries));
        foreach (var q in x.Els("conflicts")) rule.Conflicts.Add(q.At("idref"));
        if (x.At("cluster-id").Length > 0) rule.Clusters.Add(x.At("cluster-id"));
        foreach (var i in x.Els("ident")) rule.Idents.Add((i.At("system"), i.Text()));
        foreach (var r in x.Els("reference")) { var s = r.Text(); if (s.Length > 0) rule.References.Add(s); }
        foreach (var c in x.Elements().Where(c => c.Name.LocalName is "check" or "complex-check")) rule.Checks.Add(c);
        foreach (var f in x.Els("fix"))
        {
            var parts = new List<object>();
            foreach (var node in f.Nodes())
            {
                if (node is XText txt) parts.Add(txt.Value);
                else if (node is XElement { Name.LocalName: "sub" } e) parts.Add(new SubRef(e.At("idref")));
                else if (node is XElement { Name.LocalName: "instance" }) parts.Add("");
                else if (node is XElement other) parts.Add(other.Value);
            }
            rule.Fixes.Add(new XccdfFix(f.At("system"), f.At("complexity"), f.At("disruption"), f.At("reboot"), parts));
        }
        return rule;
    }

    internal static XccdfProfile ParseProfile(XElement x, bool tailored)
    {
        var id = x.At("id");
        var p = new XccdfProfile
        {
            Id = id, Tailored = tailored,
            Title = x.El("title") is { } t && t.Text().Length > 0 ? t.Text() : Short(id, "_profile_"),
            Description = Cut(x.El("description").Text(), 1500), Extends = x.At("extends")
        };
        foreach (var e in x.Elements())
            switch (e.Name.LocalName)
            {
                case "select": p.Ops.Add(new ProfileOp("select", e.At("idref"), e.At("selected").Length == 0 ? "true" : e.At("selected"))); break;
                case "set-value": p.Ops.Add(new ProfileOp("set-value", e.At("idref"), e.Value)); break;
                case "refine-value": p.Ops.Add(new ProfileOp("refine-value", e.At("idref"), e.At("selector"))); break;
                case "refine-rule": p.Ops.Add(new ProfileOp("refine-rule", e.At("idref"), e.At("severity"), e.At("selector"), e.At("weight"))); break;
            }
        return p;
    }

    static XccdfValue ParseValue(XElement x)
    {
        var v = new XccdfValue
        {
            Id = x.At("id"), Title = x.El("title").Text(), Description = Cut(x.El("description").Text(), 600),
            Type = x.At("type").Length == 0 ? "string" : x.At("type"), Operator = x.At("operator").Length == 0 ? "equals" : x.At("operator")
        };
        foreach (var e in x.Els("value"))
        {
            var sel = e.At("selector");
            if (sel.Length == 0) v.Default = e.Value; else v.BySelector[sel] = e.Value;
        }
        foreach (var e in x.Els("complex-value"))
            v.Lists[e.At("selector")] = e.Els("item").Select(i => i.Value).ToList();
        return v;
    }

    static OsTarget GuessTarget(XccdfDocument doc)
    {
        var s = (string.Join(' ', doc.Platforms) + " " + string.Join(' ', doc.Rules.SelectMany(r => r.Platforms).Distinct().Take(50))).ToLowerInvariant();
        if (s.Contains(":ibm:aix")) return OsTarget.AIX;
        if (s.Contains(":sun:") || s.Contains(":oracle:solaris")) return OsTarget.Solaris;
        if (s.Contains(":hp:hp-ux")) return OsTarget.HPUX;
        if (s.Contains("freebsd") || s.Contains("openbsd") || s.Contains("netbsd")) return OsTarget.BSD;
        if (s.Contains("linux") || s.Contains("cpe:/o:") || doc.Title.Contains("linux", StringComparison.OrdinalIgnoreCase)) return OsTarget.Linux;
        return doc.Title.Contains("AIX", StringComparison.Ordinal) ? OsTarget.AIX : OsTarget.Any;
    }

    // ---------------------------------------------------------------- OVAL files (CVE feeds, patch advisories, checks)
    static ImportReport LoadOval(ScapSource src, string source, CancellationToken ct)
    {
        var lib = new OvalLibrary(src.OvalFiles);
        var doc = new XccdfDocument { Source = src, Oval = lib, Title = Path.GetFileName(source), FileName = Path.GetFileName(source), Prebuilt = new() };
        var none = new Dictionary<string, IReadOnlyList<string>>();
        foreach (var d in lib.Definitions)
        {
            ct.ThrowIfCancellationRequested();
            var cls = d.At("class");
            if (X.IsTrue(d.At("deprecated")) || d.El("criteria") == null) continue;
            var meta = d.El("metadata");
            var refs = meta?.Els("reference").Select(r => r.At("ref_id")).Where(r => r.Length > 0).Distinct().ToList() ?? new();
            var sev = meta?.Descendants().FirstOrDefault(e => e.Name.LocalName == "severity").Text() ?? "";
            var id = d.At("id");
            var (ir, gaps) = OvalCompiler.Compile(lib, new CheckNode { Definition = id }, null, none);
            var title = meta?.El("title").Text() ?? id;
            doc.Prebuilt.Add(new RuleItem
            {
                Id = id, FullId = id, Title = title.Length > 0 ? title : id,
                Severity = sev.ToLowerInvariant() switch { "critical" or "important" or "high" => Severity.High, "low" or "negligible" => Severity.Low, _ => Severity.Medium },
                Command = "oval " + id, Mode = CompareMode.Oval, Oval = ir, CheckGap = string.Join(", ", gaps),
                Notes = Cut((cls.Length > 0 ? $"Class: {cls}. " : "") + (refs.Count > 0 ? "References: " + string.Join(", ", refs.Take(30)) + ". " : "") + (meta?.El("description").Text() ?? ""), 1500)
            });
        }
        if (doc.Prebuilt.Count == 0) throw new FormatException("This OVAL file has no definitions with criteria.");
        var rep = new ImportReport { Source = source, Scap = doc };
        rep.Rules.AddRange(doc.ToRules(null, ct));
        rep.Notes.Add($"OVAL file: {doc.Prebuilt.Count} definition(s). For vulnerability and patch definitions, FAIL means the server is affected.");
        Summary(rep, doc);
        return rep;
    }
}

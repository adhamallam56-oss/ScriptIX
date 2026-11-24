using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace ScriptIX.Scap;

public sealed record ScapScore(string System, string Name, double Score, double Maximum)
{
    public double Percent => Maximum <= 0 ? 0 : Score / Maximum * 100;
}

/// <summary>XCCDF 1.2 / ARF results: scoring, writing and reading.</summary>
public static class ScapResults
{
    static readonly XNamespace Ns = "http://checklists.nist.gov/xccdf/1.2";
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // ---------------------------------------------------------------- mapping
    public static string ToXccdf(ResultRow r) => r.Result switch
    {
        "PASS" => r.Detail == "FIXED" ? "fixed" : "pass",
        "FAIL" => r.Detail is "TIMEOUT" or "INTERRUPTED" ? "error" : "fail",
        _ => r.Detail switch
        {
            "NOT-APPLICABLE" or "OTHER-OS" => "notapplicable",
            "FILTERED" => "notselected",
            "ERROR" or "TIMEOUT" or "PREVIEW-FAILED" => "error",
            "UNKNOWN" => "unknown",
            "INFORMATIONAL" or "WAIVED" => "informational",
            _ => "notchecked"
        }
    };

    static (string Result, string Detail) FromXccdf(string x) => x switch
    {
        "pass" => ("PASS", ""),
        "fixed" => ("PASS", "FIXED"),
        "fail" => ("FAIL", ""),
        "error" => ("SKIPPED", "ERROR"),
        "unknown" => ("SKIPPED", "UNKNOWN"),
        "notapplicable" => ("SKIPPED", "NOT-APPLICABLE"),
        "informational" => ("SKIPPED", "INFORMATIONAL"),
        "notselected" => ("SKIPPED", "FILTERED"),
        _ => ("SKIPPED", "NOT-CHECKED")
    };

    static bool Counts(string x) => x is "pass" or "fixed" or "fail" or "error" or "unknown";

    // ---------------------------------------------------------------- scoring
    /// The four scores of XCCDF 1.2. Without the benchmark every rule weighs the same.
    public static List<ScapScore> Scores(IReadOnlyList<ResultRow> rows, XccdfDocument? doc, XccdfProfile? profile = null)
    {
        var results = Match(rows, doc);
        var list = results.Select(p => (p.Rule, Result: ToXccdf(p.Row))).Where(p => Counts(p.Result)).ToList();
        double W(XccdfRule? r) => r == null ? 1
            : profile != null && profile.RefineRules.TryGetValue(r.Id, out var o) && double.TryParse(o.Weight, NumberStyles.Float, Inv, out var w) ? w : r.Weight;
        bool Ok(string x) => x is "pass" or "fixed";

        double flat = list.Where(p => Ok(p.Result)).Sum(p => W(p.Rule)), flatMax = list.Sum(p => W(p.Rule));
        int n = list.Count(p => Ok(p.Result));
        double def;
        if (doc == null || list.All(p => p.Rule == null)) def = flatMax > 0 ? flat / flatMax * 100 : 0;
        else
        {
            var byRule = list.Where(p => p.Rule != null).GroupBy(p => p.Rule!.Id).ToDictionary(g => g.Key, g => g.First().Result);
            var kidsG = doc.Groups.Where(g => g.Parent != null).ToLookup(g => g.Parent!);
            var kidsR = doc.Rules.Where(r => r.Parent != null).ToLookup(r => r.Parent!);
            (double Score, bool Any) Item(IEnumerable<XccdfGroup> gs, IEnumerable<XccdfRule> rs)
            {
                double sum = 0, acc = 0; bool any = false;
                foreach (var r in rs)
                    if (byRule.TryGetValue(r.Id, out var res)) { any = true; sum += (Ok(res) ? 100 : 0) * W(r); acc += W(r); }
                foreach (var g in gs)
                {
                    var (s, has) = Item(kidsG[g], kidsR[g]);
                    if (!has) continue;
                    any = true; sum += s * g.Weight; acc += g.Weight;
                }
                return (acc > 0 ? sum / acc : 0, any);
            }
            def = Item(doc.Groups.Where(g => g.Parent == null), doc.Rules.Where(r => r.Parent == null)).Score;
        }
        return new List<ScapScore>
        {
            new("urn:xccdf:scoring:default", "Default", Math.Round(def, 6), 100),
            new("urn:xccdf:scoring:flat", "Flat", flat, flatMax),
            new("urn:xccdf:scoring:flat-unweighted", "Flat unweighted", n, list.Count),
            new("urn:xccdf:scoring:absolute", "Absolute", list.Count > 0 && n == list.Count ? 1 : 0, 1)
        };
    }

    static List<(ResultRow Row, XccdfRule? Rule)> Match(IReadOnlyList<ResultRow> rows, XccdfDocument? doc)
    {
        if (doc == null) return rows.Select(r => (r, (XccdfRule?)null)).ToList();
        var byFull = doc.Rules.GroupBy(r => ScriptBuilder.SafeId(r.Id, 0)).ToDictionary(g => g.Key, g => g.First());
        var byShort = doc.Rules.GroupBy(r => ScriptBuilder.SafeId(r.ShortId, 0)).ToDictionary(g => g.Key, g => g.First());
        return rows.Select(r => (r, byFull.TryGetValue(r.Id, out var a) ? a : byShort.TryGetValue(r.Id, out var b) ? b : null)).ToList();
    }

    /// Does this benchmark belong to these results?
    public static bool Fits(IReadOnlyList<ResultRow> rows, XccdfDocument doc) =>
        rows.Count > 0 && doc.Rules.Count > 0 && Match(rows, doc).Count(p => p.Rule != null) * 2 > rows.Count;

    // ---------------------------------------------------------------- writing
    static string Ncname(string s) => Regex.Replace(s, "[^A-Za-z0-9._-]", "_");

    public static XElement TestResult(IReadOnlyList<ResultRow> rows, XccdfDocument? doc, XccdfProfile? profile, string sourceFile, DateTime generated, ReportDetails? details)
    {
        var (host, when) = ResultsParser.Describe(sourceFile);
        var start = DateTime.TryParseExact(when, "yyyy-MM-dd HH:mm:ss", Inv, DateTimeStyles.None, out var t) ? t : generated;
        double secs = rows.Sum(r => double.TryParse(r.Seconds, NumberStyles.Float, Inv, out var d) ? d : 0);
        string Iso(DateTime d) => d.ToString("yyyy-MM-ddTHH:mm:ss", Inv);
        var tr = new XElement(Ns + "TestResult",
            new XAttribute("id", "xccdf_org.scriptix.content_testresult_" + Ncname((host.Length > 0 ? host + "_" : "") + start.ToString("yyyyMMddHHmmss", Inv))),
            new XAttribute("start-time", Iso(start)), new XAttribute("end-time", Iso(start.AddSeconds(secs))),
            new XAttribute("version", doc is { Version.Length: > 0 } ? doc.Version : "1"),
            new XAttribute("test-system", $"cpe:/a:scriptix:scriptix:{AppInfo.Version}"));
        if (doc is { Id.Length: > 0 })
            tr.Add(new XElement(Ns + "benchmark", new XAttribute("href", doc.FileName.Length > 0 ? doc.FileName : "#" + doc.Id), new XAttribute("id", doc.Id)));
        tr.Add(new XElement(Ns + "title", details is { Title.Length: > 0 } ? details.Title : "ScriptIX scan result"));
        if (details is { Notes.Length: > 0 }) tr.Add(new XElement(Ns + "remark", details.Notes));
        if (details is { Organization.Length: > 0 }) tr.Add(new XElement(Ns + "organization", details.Organization));
        if (profile != null && profile.Id.Length > 0) tr.Add(new XElement(Ns + "profile", new XAttribute("idref", profile.Id)));
        tr.Add(new XElement(Ns + "target", host.Length > 0 ? host : "unknown"));
        tr.Add(new XElement(Ns + "target-facts",
            new XElement(Ns + "fact", new XAttribute("name", "urn:xccdf:fact:scanner:name"), new XAttribute("type", "string"), AppInfo.Name),
            new XElement(Ns + "fact", new XAttribute("name", "urn:xccdf:fact:scanner:version"), new XAttribute("type", "string"), AppInfo.Version),
            new XElement(Ns + "fact", new XAttribute("name", "urn:xccdf:fact:asset:identifier:host_name"), new XAttribute("type", "string"), host.Length > 0 ? host : "unknown")));
        if (doc != null)
        {
            foreach (var p in doc.Platforms) tr.Add(new XElement(Ns + "platform", new XAttribute("idref", p)));
            foreach (var v in doc.Values.Values)
                if (doc.Value(v.Id, profile) is { } val) tr.Add(new XElement(Ns + "set-value", new XAttribute("idref", v.Id), Clean(val)));
        }
        var done = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (row, rule) in Match(rows, doc))
        {
            var id = rule?.Id ?? (Regex.IsMatch(row.Id, "^xccdf_[^_]+_rule_.+$") ? row.Id : "xccdf_org.scriptix.content_rule_" + Ncname(row.Id));
            if (!done.Add(id)) continue;
            var x = new XElement(Ns + "rule-result", new XAttribute("idref", id));
            if (rule is { Role.Length: > 0 }) x.Add(new XAttribute("role", rule.Role));
            x.Add(new XAttribute("time", Iso(start)));
            var sev = rule is { Severity.Length: > 0 } ? rule.Severity : row.Severity.ToLowerInvariant();
            x.Add(new XAttribute("severity", sev is "info" or "low" or "medium" or "high" ? sev : "unknown"));
            x.Add(new XAttribute("weight", (rule?.Weight ?? 1).ToString("0.000000", Inv)));
            x.Add(new XElement(Ns + "result", ToXccdf(row)));
            if (row.Waived)
                x.Add(new XElement(Ns + "override", new XAttribute("time", Iso(generated)), new XAttribute("authority", details is { NamesText.Length: > 0 } ? details.NamesText : AppInfo.Name),
                    new XElement(Ns + "old-result", ToXccdf(row.Original())), new XElement(Ns + "new-result", ToXccdf(row)),
                    new XElement(Ns + "remark", row.Reason.Length > 0 ? Clean(row.Reason) : "Changed by hand.")));
            if (rule != null) foreach (var (sys, ident) in rule.Idents) x.Add(new XElement(Ns + "ident", new XAttribute("system", sys), ident));
            if (row.Output.Length > 0 && ToXccdf(row) is "fail" or "error" or "unknown") x.Add(new XElement(Ns + "message", new XAttribute("severity", "info"), Clean(row.Output)));
            var rf = rule?.Checks.FirstOrDefault(c => c.Name.LocalName == "check")?.El("check-content-ref");
            if (rf != null)
                x.Add(new XElement(Ns + "check", new XAttribute("system", rf.Parent!.At("system")),
                    new XElement(Ns + "check-content-ref", rf.At("name").Length > 0 ? new XAttribute("name", rf.At("name")) : null, new XAttribute("href", rf.At("href")))));
            var def = rf != null ? "" : row.Command.StartsWith("oval ", StringComparison.Ordinal) ? row.Command[5..].Trim() : "";
            if (def.StartsWith("oval:", StringComparison.Ordinal))
                x.Add(new XElement(Ns + "check", new XAttribute("system", "http://oval.mitre.org/XMLSchema/oval-definitions-5"),
                    new XElement(Ns + "check-content-ref", new XAttribute("name", def), new XAttribute("href", "#oval"))));
            tr.Add(x);
        }
        if (doc != null)
            foreach (var r in doc.Rules.Where(r => !done.Contains(r.Id)))
                tr.Add(new XElement(Ns + "rule-result", new XAttribute("idref", r.Id), new XAttribute("time", Iso(start)),
                    new XAttribute("severity", r.Severity is "info" or "low" or "medium" or "high" ? r.Severity : "unknown"),
                    new XAttribute("weight", r.Weight.ToString("0.000000", Inv)), new XElement(Ns + "result", "notselected")));
        foreach (var s in Scores(rows, doc, profile))
            tr.Add(new XElement(Ns + "score", new XAttribute("system", s.System), new XAttribute("maximum", s.Maximum.ToString("0.000000", Inv)), s.Score.ToString("0.000000", Inv)));
        return tr;
    }

    static string Clean(string s)
    {
        var chars = s.Where(c => c is '\t' or '\n' || (c >= ' ' && c != '￾' && c != '￿' && !char.IsSurrogate(c))).ToArray();
        return new string(chars);
    }

    const string Head = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";

    /// The benchmark with the results inside (like oscap --results), or only the results when no XCCDF 1.2 benchmark is loaded.
    public static string Xccdf(IReadOnlyList<ResultRow> rows, XccdfDocument? doc, XccdfProfile? profile, string sourceFile, DateTime generated, ReportDetails? details)
    {
        var tr = TestResult(rows, doc, profile, sourceFile, generated, details);
        var bench = BenchmarkCopy(doc, profile);
        if (bench == null) return Head + tr + "\n";
        bench.Add(tr);
        return Head + bench.ToString(SaveOptions.DisableFormatting) + "\n";
    }

    static XElement? BenchmarkCopy(XccdfDocument? doc, XccdfProfile? profile)
    {
        if (doc?.Source?.Benchmark is not { } b || b.Name.Namespace != Ns) return null;
        var copy = new XElement(b);
        foreach (var old in copy.Els("TestResult").ToList()) old.Remove();
        foreach (var sig in copy.Elements().Where(e => e.Name.LocalName == "signature").ToList()) sig.Remove();
        if (profile is { Tailored: true } && copy.Els("Profile").LastOrDefault() is { } last)
        {
            var p = new XElement(Ns + "Profile", new XAttribute("id", profile.Id));
            if (profile.Extends.Length > 0) p.Add(new XAttribute("extends", profile.Extends.TrimStart('#')));
            p.Add(new XElement(Ns + "title", profile.Title));
            foreach (var o in profile.Ops)
                p.Add(o.Kind switch
                {
                    "select" => new XElement(Ns + "select", new XAttribute("idref", o.Id), new XAttribute("selected", o.Value)),
                    "set-value" => new XElement(Ns + "set-value", new XAttribute("idref", o.Id), o.Value),
                    "refine-value" => new XElement(Ns + "refine-value", new XAttribute("idref", o.Id), new XAttribute("selector", o.Value)),
                    _ => null
                });
            last.AddAfterSelf(p);
        }
        return copy;
    }

    /// Asset Reporting Format 1.1: asset + benchmark + results in one file.
    public static string Arf(IReadOnlyList<ResultRow> rows, XccdfDocument? doc, XccdfProfile? profile, string sourceFile, DateTime generated, ReportDetails? details)
    {
        XNamespace arf = "http://scap.nist.gov/schema/asset-reporting-format/1.1", core = "http://scap.nist.gov/schema/reporting-core/1.1",
                   ai = "http://scap.nist.gov/schema/asset-identification/1.1", voc = "http://scap.nist.gov/specifications/arf/vocabulary/relationships/1.0#";
        var tr = TestResult(rows, doc, profile, sourceFile, generated, details);
        var (host, _) = ResultsParser.Describe(sourceFile);
        var root = new XElement(arf + "asset-report-collection",
            new XAttribute(XNamespace.Xmlns + "arf", arf), new XAttribute(XNamespace.Xmlns + "core", core), new XAttribute(XNamespace.Xmlns + "ai", ai),
            new XElement(core + "relationships", new XAttribute(XNamespace.Xmlns + "arfvocab", voc),
                new XElement(core + "relationship", new XAttribute("type", "arfvocab:createdFor"), new XAttribute("subject", "xccdf1"), new XElement(core + "ref", "collection1")),
                new XElement(core + "relationship", new XAttribute("type", "arfvocab:isAbout"), new XAttribute("subject", "xccdf1"), new XElement(core + "ref", "asset0"))),
            new XElement(arf + "report-requests", new XElement(arf + "report-request", new XAttribute("id", "collection1"),
                new XElement(arf + "content", doc?.Source?.Root is { } r && r.Name.LocalName == "data-stream-collection" ? new XElement(r)
                    : BenchmarkCopy(doc, profile) ?? new XElement(Ns + "Benchmark", new XAttribute("id", "xccdf_org.scriptix.content_benchmark_none"),
                        new XElement(Ns + "status", "incomplete"), new XElement(Ns + "title", "Own checks"), new XElement(Ns + "version", "1"))))),
            new XElement(arf + "assets", new XElement(arf + "asset", new XAttribute("id", "asset0"),
                new XElement(ai + "computing-device", new XElement(ai + "fqdn", HostName(host)), new XElement(ai + "hostname", HostName(host))))),
            new XElement(arf + "reports", new XElement(arf + "report", new XAttribute("id", "xccdf1"), new XElement(arf + "content", tr))));
        return Head + root.ToString(SaveOptions.DisableFormatting) + "\n";
    }

    static string HostName(string h)
    {
        h = Regex.Replace(h, "[^A-Za-z0-9.-]", "-").Trim('-', '.');
        return h.Length > 0 ? h : "unknown";
    }

    // ---------------------------------------------------------------- reading
    public sealed record Loaded(List<ResultRow> Rows, string Host, string When, string ProfileId, string Tool);

    /// A results_HOST_DATE_TIME name, so reports can show the host and time.
    public static string SourceName(Loaded l, string fileName)
    {
        var d = Regex.Replace(l.When, "[^0-9]", "");
        return l.Host.Length > 0 && d.Length == 14 ? $"results_{HostName(l.Host)}_{d[..8]}_{d[8..]}.csv" : fileName;
    }

    /// Reads the results oscap and other scanners write: XCCDF results, ARF, OVAL results.
    public static Loaded Read(Stream s, CancellationToken ct = default)
    {
        var root = ScapSource.ReadXml(s, ct).Root ?? throw new FormatException("The XML file is empty.");
        var tr = root.DescendantsAndSelf().LastOrDefault(e => e.Name.LocalName == "TestResult");
        if (tr == null)
        {
            if (root.Name.LocalName == "oval_results") return ReadOval(root);
            throw new FormatException("This XML file holds no results. Expected XCCDF results, ARF or OVAL results.");
        }
        var rules = new Dictionary<string, XElement>(StringComparer.Ordinal);
        foreach (var r in root.Descendants().Where(e => e.Name.LocalName == "Rule")) rules.TryAdd(r.At("id"), r);
        var rows = new List<ResultRow>();
        foreach (var rr in tr.Els("rule-result"))
        {
            var res = rr.El("result").Text();
            if (res == "notselected") continue;
            var id = rr.At("idref");
            rules.TryGetValue(id, out var rule);
            var (result, detail) = FromXccdf(res);
            var check = rr.Descendants().FirstOrDefault(e => e.Name.LocalName == "check-content-ref")?.At("name") ?? "";
            var time = rr.At("time");
            var ovr = rr.El("override");
            rows.Add(new ResultRow
            {
                Seq = rows.Count + 1, Id = XccdfImporter.Short(id, "_rule_"), Title = rule?.El("title").Text() ?? "",
                Severity = rr.At("severity").Length > 0 ? rr.At("severity") : rule?.At("severity") ?? "",
                Time = time.Length >= 19 ? time.Substring(11, 8) : "", Result = result, Detail = detail, Mode = check.Length > 0 ? "oval" : "",
                Command = check.Length > 0 ? "oval " + check : "", Output = string.Join("\n", rr.Els("message").Select(m => m.Value.Trim())),
                Reason = ovr?.El("remark").Text() ?? ""
            });
        }
        if (rows.Count == 0) throw new FormatException("The results file holds no rule results.");
        var when = tr.At("start-time").Length > 0 ? tr.At("start-time") : tr.At("end-time");
        return new Loaded(rows, tr.El("target").Text(), when.Length >= 19 ? when[..19].Replace('T', ' ') : when, tr.El("profile")?.At("idref") ?? "", tr.At("test-system"));
    }

    static Loaded ReadOval(XElement root)
    {
        var defs = new Dictionary<string, XElement>(StringComparer.Ordinal);
        foreach (var d in root.Descendants().Where(e => e.Name.LocalName == "definition" && e.At("id").Length > 0)) defs.TryAdd(d.At("id"), d);
        var rows = new List<ResultRow>();
        foreach (var d in root.Descendants().Where(e => e.Name.LocalName == "definition" && e.At("definition_id").Length > 0))
        {
            defs.TryGetValue(d.At("definition_id"), out var def);
            bool inverted = (def?.At("class") ?? d.At("class")) is "vulnerability" or "patch";
            var (result, detail) = d.At("result") switch
            {
                "true" => (inverted ? "FAIL" : "PASS", ""),
                "false" => (inverted ? "PASS" : "FAIL", ""),
                "error" => ("SKIPPED", "ERROR"),
                "unknown" => ("SKIPPED", "UNKNOWN"),
                "not applicable" => ("SKIPPED", "NOT-APPLICABLE"),
                _ => ("SKIPPED", "NOT-CHECKED")
            };
            rows.Add(new ResultRow { Seq = rows.Count + 1, Id = d.At("definition_id"), Title = def?.El("metadata")?.El("title").Text() ?? "", Result = result, Detail = detail, Command = "oval " + d.At("definition_id"), Mode = "oval" });
        }
        if (rows.Count == 0) throw new FormatException("The OVAL results file holds no definitions.");
        var host = root.Descendants().FirstOrDefault(e => e.Name.LocalName == "primary_host_name").Text();
        var ts = root.Descendants().FirstOrDefault(e => e.Name.LocalName == "timestamp").Text();
        return new Loaded(rows, host, ts.Length >= 19 ? ts[..19].Replace('T', ' ') : ts, "", "OVAL");
    }
}

/// <summary>What changed between two runs (like oscap-diff).</summary>
public static class ResultsCompare
{
    public static (int Fixed, int Broken, int Other) Apply(IReadOnlyList<ResultRow> now, IReadOnlyList<ResultRow> before)
    {
        var old = before.GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First());
        int good = 0, bad = 0, other = 0;
        foreach (var r in now)
        {
            r.Before = old.TryGetValue(r.Id, out var o) ? o.ResultText : "(new)";
            static string Why(string d) => d == "MANUAL" ? "NOT-CHECKED" : d;
            r.Changed = o == null || o.Result != r.Result || (r.Result == "SKIPPED" && Why(o.Detail) != Why(r.Detail));
            if (!r.Changed) continue;
            if (o == null) other++;
            else if (r.Result == "PASS") good++;
            else if (r.Result == "FAIL") bad++;
            else other++;
        }
        return (good, bad, other);
    }
}

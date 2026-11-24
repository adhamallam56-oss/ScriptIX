using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace ScriptIX.Scap;

/// <summary>What `oscap info`, `oscap xccdf generate guide/fix` and `oscap ... validate` do.</summary>
public static class ScapExport
{
    // ---------------------------------------------------------------- info
    public static string Info(XccdfDocument doc)
    {
        var sb = new StringBuilder();
        var s = doc.Source;
        sb.Append($"{(s?.Kind.Length > 0 ? s.Kind : "Rules")}{(s?.Version.Length > 0 ? " " + s.Version : "")}: {doc.FileName}\n\n");
        if (doc.Title.Length > 0) sb.Append("Title: ").Append(doc.Title).Append('\n');
        if (doc.Id.Length > 0) sb.Append("Id: ").Append(doc.Id).Append('\n');
        if (doc.Version.Length > 0) sb.Append("Version: ").Append(doc.Version).Append('\n');
        if (doc.Status.Length > 0) sb.Append("Status: ").Append(doc.Status).Append('\n');
        if (doc.Platforms.Count > 0) sb.Append("Platform: ").Append(string.Join(", ", doc.Platforms)).Append('\n');
        if (s != null && s.Benchmarks.Count > 1) sb.Append("Benchmarks: ").Append(string.Join(", ", s.Benchmarks)).Append('\n');
        if (doc.Rules.Count > 0) sb.Append($"Rules: {doc.Rules.Count} in {doc.Groups.Count} groups, {doc.Values.Count} values\n");
        if (doc.Oval != null)
        {
            sb.Append($"OVAL definitions: {doc.Oval.DefinitionCount}\n");
            var tests = doc.Oval.Tests.GroupBy(t => t.Name.LocalName[..^5]).OrderByDescending(g => g.Count()).Select(g => $"{g.Key} {g.Count()}");
            sb.Append("OVAL tests: ").Append(string.Join(", ", tests)).Append('\n');
        }
        var fixes = doc.Rules.SelectMany(r => r.Fixes.Select(f => XccdfDocument.FixKind(f.System)).Distinct()).GroupBy(k => k).OrderByDescending(g => g.Count()).Select(g => $"{g.Key} {g.Count()}").ToList();
        if (fixes.Count > 0) sb.Append("Fixes: ").Append(string.Join(", ", fixes)).Append('\n');
        if (doc.Profiles.Count > 0)
        {
            sb.Append("\nProfiles:\n");
            foreach (var p in doc.Profiles) sb.Append($"  {p.Title}  ({p.Selected.Count} rules)\n    {p.Id}\n");
        }
        return sb.ToString();
    }

    // ---------------------------------------------------------------- fixes
    public static IReadOnlyList<(string Kind, string Name, string Ext)> FixKinds { get; } = new[]
    {
        ("bash", "Bash", "sh"), ("ansible", "Ansible playbook", "yml"), ("puppet", "Puppet", "pp"), ("kubernetes", "Kubernetes", "yml"),
        ("ignition", "Ignition", "yml"), ("blueprint", "OSBuild blueprint", "toml"), ("kickstart", "Kickstart", "cfg"), ("bootc", "Bootc", "txt")
    };

    public static int FixCount(XccdfDocument doc, string kind, IReadOnlySet<string> rules) =>
        doc.Rules.Count(r => rules.Contains(r.Id) && r.Fixes.Any(f => XccdfDocument.FixKind(f.System) == kind));

    /// All fixes of one kind in one file, like `oscap xccdf generate fix`.
    public static string Fixes(XccdfDocument doc, XccdfProfile? profile, string kind, IReadOnlySet<string> rules)
    {
        var picked = doc.Rules.Where(r => rules.Contains(r.Id))
                        .Select(r => (Rule: r, Fix: r.Fixes.FirstOrDefault(f => XccdfDocument.FixKind(f.System) == kind)))
                        .Where(p => p.Fix != null).ToList();
        if (picked.Count == 0) throw new FormatException($"None of these rules has a {kind} fix.");
        static string Line(string s) => Regex.Replace(s, @"[\r\n]+", " ");
        var sb = new StringBuilder();
        if (kind == "bash") sb.Append("#!/usr/bin/env bash\n");
        else if (kind == "ansible") sb.Append("---\n");
        sb.Append($"# {Line(doc.Title)}\n# Profile: {Line(profile?.Title ?? "(none)")}\n# {picked.Count} fixes, made by {AppInfo.Name} {AppInfo.Version}. Test on a spare server first.\n\n");
        if (kind == "ansible")
        {
            sb.Append("- hosts: all\n  tasks:\n");
            foreach (var (r, f) in picked)
            {
                sb.Append($"\n    # {Line(r.Title)}  ({r.Id})\n");
                foreach (var l in doc.FixText(f!, profile).Split('\n')) sb.Append(l.Trim().Length == 0 ? "\n" : "    " + l.TrimEnd() + "\n");
            }
            return sb.ToString();
        }
        int n = 0;
        foreach (var (r, f) in picked)
        {
            sb.Append($"\n###############################################################################\n# {++n}/{picked.Count}  {Line(r.Title)}\n# {r.Id}\n");
            if (kind == "bash") sb.Append($"(>&2 echo \"{n}/{picked.Count}: {Regex.Replace(r.Id, "[^A-Za-z0-9._-]", "_")}\")\n");
            sb.Append(doc.FixText(f!, profile).Replace("\r", "")).Append('\n');
        }
        return sb.ToString();
    }

    // ---------------------------------------------------------------- guide
    public static string Guide(XccdfDocument doc, XccdfProfile? profile, IReadOnlySet<string> rules, DateTime now)
    {
        static string E(string? s) => WebUtility.HtmlEncode(s ?? "");
        var sb = new StringBuilder();
        sb.Append("""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#f6f7fb;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--accent:#4f46e5;--hi:#b91c1c;--me:#b45309;--lo:#15803d;--code:#f1f5f9}
@media screen and (prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#131a2e;--text:#e2e8f0;--muted:#94a3b8;--line:#243049;--accent:#a5b4fc;--hi:#f87171;--me:#fbbf24;--lo:#4ade80;--code:#0f172a}}
*{box-sizing:border-box}body{margin:0;font:14px/1.55 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1000px;margin:0 auto;padding:28px 16px}h1{margin:0 0 4px;font-size:24px}.sub{color:var(--muted);margin:0 0 20px}
h2{font-size:17px;margin:26px 0 8px;color:var(--accent)}
.rule{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:0 0 12px;break-inside:avoid-page}
.rule h3{margin:0 0 6px;font-size:15px}.id{color:var(--muted);font:12px Consolas,monospace;overflow-wrap:anywhere}
.sev{font-size:12px;font-weight:700;margin-left:8px}.high{color:var(--hi)}.medium{color:var(--me)}.low{color:var(--lo)}
p{margin:6px 0}pre{background:var(--code);border-radius:8px;padding:10px;white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.45 Consolas,monospace;margin:8px 0 0}
details{margin-top:8px}summary{cursor:pointer;color:var(--accent);font-weight:600}.toc{columns:2;margin:0 0 20px;padding-left:18px}.toc a{color:var(--accent);text-decoration:none}
.foot{color:var(--muted);font-size:12px;margin-top:18px}
</style>
""");
        var picked = doc.Rules.Where(r => rules.Contains(r.Id)).ToList();
        sb.Append($"<title>{E(doc.Title)}</title></head><body><div class=\"wrap\"><h1>{E(doc.Title)}</h1>");
        sb.Append($"<p class=\"sub\">{(profile != null ? "Profile <strong>" + E(profile.Title) + "</strong> &middot; " : "")}{picked.Count} rules{(doc.Version.Length > 0 ? " &middot; version " + E(doc.Version) : "")}</p>");
        if (profile is { Description.Length: > 0 }) sb.Append($"<p>{E(profile.Description)}</p>");
        else if (doc.Description.Length > 0) sb.Append($"<p>{E(doc.Description)}</p>");

        var byGroup = picked.GroupBy(r => r.Parent).ToList();
        sb.Append("<ul class=\"toc\">");
        for (int i = 0; i < byGroup.Count; i++) sb.Append($"<li><a href=\"#g{i}\">{E(GroupName(byGroup[i].Key))}</a> ({byGroup[i].Count()})</li>");
        sb.Append("</ul>");
        for (int i = 0; i < byGroup.Count; i++)
        {
            sb.Append($"<h2 id=\"g{i}\">{E(GroupName(byGroup[i].Key))}</h2>");
            foreach (var r in byGroup[i])
            {
                var sev = r.Severity.ToLowerInvariant();
                sb.Append($"<div class=\"rule\"><h3>{E(r.Title)}<span class=\"sev {E(sev)}\">{E(sev)}</span></h3><div class=\"id\">{E(r.Id)}</div>");
                if (r.Description.Length > 0) sb.Append($"<p>{E(r.Description)}</p>");
                if (r.Rationale.Length > 0) sb.Append($"<p><strong>Why:</strong> {E(r.Rationale)}</p>");
                if (r.Idents.Count > 0) sb.Append($"<p class=\"id\">{E(string.Join(", ", r.Idents.Select(x => x.Id)))}</p>");
                foreach (var f in r.Fixes)
                {
                    var kind = XccdfDocument.FixKind(f.System);
                    sb.Append($"<details><summary>Fix ({E(kind)})</summary><pre>{E(doc.FixText(f, profile))}</pre></details>");
                }
                sb.Append("</div>");
            }
        }
        sb.Append($"<p class=\"foot\">Made by {AppInfo.Name} {AppInfo.Version} on {now:yyyy-MM-dd HH:mm}.</p></div></body></html>");
        return sb.ToString();
    }

    static string GroupName(XccdfGroup? g)
    {
        var names = new List<string>();
        for (; g != null && names.Count < 3; g = g.Parent) if (g.Title.Length > 0) names.Insert(0, g.Title);
        return names.Count == 0 ? "Rules" : string.Join(" › ", names);
    }

    // ---------------------------------------------------------------- validate
    /// Structure checks on SCAP content: duplicate ids and broken references. Not a schema (XSD) validation.
    public static List<string> Validate(Stream s, Func<string, Stream?>? sibling = null, CancellationToken ct = default)
    {
        var src = ScapSource.Load(s, sibling, ct);
        var p = new List<string>();
        if (src.Kind.Length == 0 || (src.Benchmark == null && src.OvalFiles.Count == 0 && src.Root!.Name.LocalName is not ("Tailoring" or "TestResult" or "asset-report-collection" or "oval_results" or "cpe-list" or "ocil")))
            p.Add($"Unknown SCAP file type: <{src.Root!.Name.LocalName}>.");
        foreach (var oval in src.OvalFiles) Oval(oval, p);
        if (src.Benchmark is { } b)
        {
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var e in b.DescendantsAndSelf().Where(e => e.Name.LocalName is "Benchmark" or "Group" or "Rule" or "Value" or "Profile"))
            {
                var id = e.At("id");
                if (id.Length == 0) p.Add($"<{e.Name.LocalName}> without an id.");
                else if (!ids.Add(id)) p.Add($"Duplicate id: {id}");
                if (b.Name.NamespaceName.EndsWith("/1.2", StringComparison.Ordinal) && id.Length > 0 && !Regex.IsMatch(id, $"^xccdf_[^_]+_{e.Name.LocalName.ToLowerInvariant()}_.+$"))
                    p.Add($"XCCDF 1.2 ids must look like xccdf_NAMESPACE_{e.Name.LocalName.ToLowerInvariant()}_NAME: {id}");
            }
            if (b.El("status") == null) p.Add("The benchmark has no <status>.");
            if (b.El("version") == null) p.Add("The benchmark has no <version>.");
            var clusters = b.Descendants().Select(e => e.At("cluster-id")).Where(c => c.Length > 0).ToHashSet();
            foreach (var pr in b.Els("Profile"))
            {
                if (pr.At("extends").Length > 0 && !ids.Contains(pr.At("extends").TrimStart('#'))) p.Add($"{pr.At("id")} extends a missing profile: {pr.At("extends")}");
                foreach (var r in pr.Elements().Where(e => e.Name.LocalName is "select" or "refine-value" or "set-value" or "refine-rule"))
                    if (!ids.Contains(r.At("idref")) && !clusters.Contains(r.At("idref"))) p.Add($"{pr.At("id")}: <{r.Name.LocalName}> refers to missing {r.At("idref")}");
            }
            var texts = b.Els("plain-text").Select(e => e.At("id")).ToHashSet();
            foreach (var r in b.Descendants().Where(e => e.Name.LocalName == "Rule"))
            {
                foreach (var ex in r.Descendants().Where(e => e.Name.LocalName == "check-export"))
                    if (!ids.Contains(ex.At("value-id"))) p.Add($"{r.At("id")}: check-export of missing value {ex.At("value-id")}");
                foreach (var sub in r.Descendants().Where(e => e.Name.LocalName == "sub"))
                    if (!ids.Contains(sub.At("idref")) && !texts.Contains(sub.At("idref"))) p.Add($"{r.At("id")}: <sub> of missing value {sub.At("idref")}");
                foreach (var c in r.Descendants().Where(e => e.Name.LocalName == "check-content-ref"))
                {
                    if (c.At("href").Contains("://", StringComparison.Ordinal)) continue;   // a remote file
                    var file = src.Find(c.At("href"));
                    if (file == null) { p.Add($"{r.At("id")}: check file not found: {c.At("href")}"); continue; }
                    if (file.Name.LocalName == "oval_definitions" && c.At("name").Length > 0 && file.Els("definitions").Elements().All(d => d.At("id") != c.At("name")))
                        p.Add($"{r.At("id")}: OVAL definition not found: {c.At("name")}");
                }
            }
        }
        return p.Distinct().ToList();
    }

    static void Oval(XElement root, List<string> p)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var e in root.Elements().Where(x => x.Name.LocalName is "definitions" or "tests" or "objects" or "states" or "variables").Elements())
        {
            var id = e.At("id");
            if (id.Length == 0) p.Add($"OVAL <{e.Name.LocalName}> without an id.");
            else if (!ids.Add(id)) p.Add($"Duplicate OVAL id: {id}");
        }
        foreach (var a in root.Descendants().Attributes().Where(a => a.Name.LocalName is "test_ref" or "definition_ref" or "object_ref" or "state_ref" or "var_ref"))
            if (!ids.Contains(a.Value)) p.Add($"OVAL {a.Name.LocalName} points to missing {a.Value}");
        foreach (var e in root.Descendants().Where(e => e.Name.LocalName is "object_reference" or "filter" && !e.HasElements))
            if (e.Value.Trim().StartsWith("oval:", StringComparison.Ordinal) && !ids.Contains(e.Value.Trim())) p.Add($"OVAL {e.Name.LocalName} points to missing {e.Value.Trim()}");
        if (ScapSource.OvalVersion(root).Length == 0) p.Add("The OVAL file does not say its schema version.");
    }

    // ---------------------------------------------------------------- run with the server's own oscap
    /// Commands for a Linux server that has openscap-scanner: scan, results, ARF and HTML report.
    public static ScriptItem OscapCommand(XccdfDocument doc, XccdfProfile? profile, string dataStream, string? tailoring = null)
    {
        string Q(string s) => ScriptBuilder.Q(s);
        var sb = new StringBuilder();
        sb.Append("command -v oscap >/dev/null 2>&1 || { echo \"oscap is not installed on this server\"; exit 127; }\n");
        sb.Append($"[ -f {Q(dataStream)} ] || {{ echo {Q(dataStream + " is missing: copy it to this folder first")}; exit 126; }}\n");
        sb.Append("oscap xccdf eval");
        if (tailoring != null) sb.Append(" --tailoring-file ").Append(Q(tailoring));
        if (profile != null) sb.Append(" --profile ").Append(Q(profile.Id));
        sb.Append(" --results oscap_results.xml --results-arf oscap_arf.xml --report oscap_report.html ").Append(Q(dataStream)).Append('\n');
        sb.Append("r=$?\necho \"oscap exit code $r (0 = all passed, 2 = some rules failed)\"\n[ \"$r\" = 0 ] || [ \"$r\" = 2 ]");
        return new ScriptItem("OSCAP-SCAN", "Scan with the server's own oscap", "medium", "Linux", "rc0", "", sb.ToString(), 7200);
    }
}

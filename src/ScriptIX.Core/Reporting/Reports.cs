using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace ScriptIX;

public static class ResultsParser
{
    /// Reads results_<host>_<time>.csv written by ScriptIX scripts (schema 1, 2 and 3).
    public static List<ResultRow> Parse(string text)
    {
        if (text.StartsWith("#scriptix ", StringComparison.Ordinal)) text = text[(text.IndexOf('\n') + 1)..];   // scriptix export --stamp
        var rows = Csv.Parse(text);
        if (rows.Count == 0) throw new FormatException("The results file is empty.");
        var h = rows[0].Select(x => x.Trim().TrimStart('﻿').ToLowerInvariant()).ToList();
        int C(string n) => h.IndexOf(n);
        if (C("seq") < 0 || C("result") < 0)
            throw new FormatException("This isn't a ScriptIX results file (expected a 'seq' and 'result' column).");
        string G(string[] r, string n)
        {
            int i = C(n);
            var v = i >= 0 && i < r.Length ? r[i] : "";
            // the script prefixes =,+,-,@ with ' so spreadsheets don't run them as formulas
            return v.Length > 1 && v[0] == '\'' && "=+-@".Contains(v[1]) ? v[1..] : v;
        }

        var list = new List<ResultRow>();
        foreach (var r in rows.Skip(1))
        {
            if (r.All(string.IsNullOrWhiteSpace)) continue;
            int.TryParse(G(r, "seq"), out var seq);
            var detail = G(r, "detail");
            list.Add(new ResultRow
            {
                Seq = seq, Id = G(r, "id"), Title = G(r, "title"), Severity = G(r, "severity"),
                Time = G(r, "time"), Result = G(r, "result").Trim().ToUpperInvariant(), Detail = detail,
                Rc = G(r, "rc"), Seconds = G(r, "seconds"), Command = G(r, "command"),
                Expected = G(r, "expected"), Output = G(r, "output"),
                // schema 3+: what is needed to run the exact same check again
                Mode = G(r, "mode"), Os = G(r, "os"), Shell = G(r, "shell"),
                Timeout = int.TryParse(G(r, "timeout"), out var tmo) ? tmo : 0
            });
        }
        return list;
    }

    public static bool LooksLikeResults(string firstLine)
    {
        var l = firstLine.ToLowerInvariant();
        return l.Contains("\"seq\"") || (l.Contains("seq") && l.Contains("result"));
    }

    /// results_<host>_<yyyymmdd>_<hhmmss>.csv -> (host, "yyyy-mm-dd hh:mm:ss")
    public static (string Host, string When) Describe(string fileName)
    {
        var m = Regex.Match(Path.GetFileNameWithoutExtension(fileName), @"^results_(.+)_(\d{8})_(\d{6})$");
        if (!m.Success) return ("", "");
        var d = m.Groups[2].Value; var t = m.Groups[3].Value;
        return (m.Groups[1].Value, $"{d[..4]}-{d[4..6]}-{d[6..]} {t[..2]}:{t[2..4]}:{t[4..]}");
    }

    public static ResultSummary Summarize(IEnumerable<ResultRow> rows)
    {
        var l = rows.ToList();
        return new ResultSummary(l.Count, l.Count(r => r.Result == "PASS"),
                                 l.Count(r => r.Result == "FAIL"), l.Count(r => r.Result == "SKIPPED"));
    }

    public static string HistoryText(IReadOnlyList<ResultRow> rows)
    {
        var s = Summarize(rows);
        var sb = new StringBuilder();
        sb.AppendLine("COMMAND HISTORY");
        sb.AppendLine($"{"#",-5} {"TIME",-9} {"RESULT",-8} {"DETAIL",-15} {"RC",-4} COMMAND");
        foreach (var r in rows)
        {
            var cmd = r.Command.Length > 80 ? r.Command[..80] : r.Command;
            sb.AppendLine($"{r.Seq,-5} {r.Time,-9} {r.Result,-8} {(r.Detail.Length == 0 ? "-" : r.Detail),-15} {r.Rc,-4} {cmd}");
        }
        sb.AppendLine();
        sb.AppendLine("SUMMARY");
        sb.AppendLine($"Total commands : {s.Total}");
        sb.AppendLine($"Passed         : {s.Passed}");
        sb.AppendLine($"Failed         : {s.Failed}");
        sb.AppendLine($"Skipped        : {s.Skipped}");
        sb.AppendLine($"Pass rate      : {s.PassRate}%");
        var failed = rows.Where(r => r.Result == "FAIL").ToList();
        if (failed.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("FAILED COMMANDS");
            foreach (var r in failed) sb.AppendLine($"#{r.Seq} {r.Id}  {r.Command}  (rc={r.Rc}{(r.Detail.Length > 0 ? ", " + r.Detail : "")})");
        }
        return sb.ToString();
    }
}

/// <summary>A single self-contained HTML file (no scripts, no external links) for sharing a run.</summary>
public static class HtmlReport
{
    static string E(string? s) => WebUtility.HtmlEncode(s ?? "");

    public static string Build(IReadOnlyList<ResultRow> rows, string sourceFile, DateTime generated, ReportDetails? details = null)
    {
        var s = ResultsParser.Summarize(rows);
        var (host, when) = ResultsParser.Describe(sourceFile);
        var d = details ?? new ReportDetails();
        var title = d.Title.Trim();
        var sb = new StringBuilder();
        sb.Append("""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>ScriptIX report</title>
<style>
:root{--bg:#f6f7fb;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--pass:#15803d;--passbg:#dcfce7;--fail:#b91c1c;--failbg:#fee2e2;--skip:#475569;--skipbg:#f1f5f9;--accent:#4f46e5}
@media screen and (prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#131a2e;--text:#e2e8f0;--muted:#94a3b8;--line:#243049;--passbg:#0f2e1c;--pass:#4ade80;--failbg:#3a1414;--fail:#f87171;--skipbg:#1e293b;--skip:#cbd5e1}}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1200px;margin:0 auto;padding:28px 16px}
h1{margin:0;font-size:24px}h1 b{color:var(--accent)}.sub{color:var(--muted);margin:4px 0 22px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:22px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.tile .n{font-size:28px;font-weight:700}.tile .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
.bar{height:10px;border-radius:6px;background:var(--failbg);overflow:hidden;margin-top:8px}.bar i{display:block;height:100%;background:var(--pass)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
code,pre{font:12px/1.45 "Cascadia Mono",Consolas,monospace;white-space:pre-wrap;word-break:break-word;margin:0}
.b{display:inline-block;padding:2px 8px;border-radius:999px;font-weight:700;font-size:12px;white-space:nowrap}
.PASS{background:var(--passbg);color:var(--pass)}.FAIL{background:var(--failbg);color:var(--fail)}.SKIPPED{background:var(--skipbg);color:var(--skip)}
.muted{color:var(--muted)}.foot{color:var(--muted);font-size:12px;margin-top:18px}
.head{display:flex;justify-content:space-between;align-items:flex-start;gap:24px;margin-bottom:22px}.head .sub{margin-bottom:0}
.logo{max-height:84px;max-width:260px;object-fit:contain;background:#fff;border-radius:8px;padding:6px}
.by{margin:8px 0 0}.by span{color:var(--muted)}
.notes{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-bottom:22px;white-space:pre-wrap;overflow-wrap:anywhere}
.pics{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px;margin-top:22px}
figure{margin:0;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px;break-inside:avoid}
figure img{display:block;max-width:100%;max-height:520px;margin:0 auto}figcaption{color:var(--muted);font-size:13px;margin-top:8px;text-align:center}
@page{size:A4 landscape;margin:12mm}
@media print{*{print-color-adjust:exact;-webkit-print-color-adjust:exact}body{background:#fff;font-size:12px}.wrap{max-width:none;padding:0}.tile,table{border-color:#ccc}table{overflow:visible}tr{break-inside:avoid}.tiles{grid-template-columns:repeat(5,1fr)}}
</style></head><body><div class="wrap">
""");
        if (title.Length > 0) sb.Replace("<title>ScriptIX report</title>", $"<title>{E(title)}</title>");
        sb.Append("<div class=\"head\"><div>");
        sb.Append(title.Length > 0 ? $"<h1>{E(title)}</h1>" : "<h1>Script<b>IX</b> run report</h1>");
        sb.Append("<p class=\"sub\">");
        if (host.Length > 0) sb.Append($"Host <strong>{E(host)}</strong> &middot; run {E(when)} &middot; ");
        sb.Append($"source {E(Path.GetFileName(sourceFile))}</p>");
        if (d.NamesText.Length > 0) sb.Append($"<p class=\"by\"><span>Prepared by</span> <strong>{E(d.NamesText)}</strong></p>");
        if (d.Organization.Trim().Length > 0) sb.Append($"<p class=\"by\"><span>Organization</span> <strong>{E(d.Organization.Trim())}</strong></p>");
        sb.Append("</div>");
        if (d.Logo?.Mime != null) sb.Append($"<img class=\"logo\" alt=\"Logo\" src=\"{DataUri(d.Logo)}\">");
        sb.Append("</div>");

        sb.Append("<div class=\"tiles\">");
        Tile(sb, "Total", s.Total.ToString());
        Tile(sb, "Passed ✓", s.Passed.ToString());
        Tile(sb, "Failed ✕", s.Failed.ToString());
        Tile(sb, "Skipped", s.Skipped.ToString());
        sb.Append($"<div class=\"tile\"><div class=\"n\">{s.PassRate}%</div><div class=\"l\">Pass rate</div><div class=\"bar\"><i style=\"width:{s.PassRate}%\"></i></div></div>");
        sb.Append("</div>");

        if (d.Notes.Trim().Length > 0) sb.Append($"<div class=\"notes\">{E(d.Notes.Trim())}</div>");

        sb.Append("<table><thead><tr><th>#</th><th>Result</th><th>ID / what it does</th><th>Command</th><th>RC</th><th>Output</th></tr></thead><tbody>");
        foreach (var r in rows)
        {
            var cls = r.Result is "PASS" or "FAIL" ? r.Result : "SKIPPED";
            var label = r.Result switch { "PASS" => "✓ PASS", "FAIL" => "✕ FAIL", _ => "– " + r.Result };
            sb.Append("<tr>")
              .Append($"<td>{r.Seq}</td>")
              .Append($"<td><span class=\"b {cls}\">{E(label)}</span>{(r.Detail.Length > 0 ? $"<div class=\"muted\">{E(r.Detail)}</div>" : "")}{(r.Note.Length > 0 ? $"<div class=\"muted\">{E(r.Note)}</div>" : "")}</td>")
              .Append($"<td><strong>{E(r.Id)}</strong><div>{E(r.Title)}</div></td>")
              .Append($"<td><code>{E(r.Command)}</code>{(r.Expected.Length > 0 ? $"<div class=\"muted\">expected: <code>{E(r.Expected)}</code></div>" : "")}</td>")
              .Append($"<td>{E(r.Rc)}</td>")
              .Append($"<td><pre>{E(r.Output)}</pre></td>")
              .Append("</tr>");
        }
        sb.Append("</tbody></table>");
        var pics = d.Pictures.Where(p => p.Mime != null).ToList();
        if (pics.Count > 0)
        {
            sb.Append("<div class=\"pics\">");
            foreach (var p in pics)
            {
                var cap = p.Caption.Trim();
                sb.Append($"<figure><img alt=\"{E(cap.Length > 0 ? cap : p.Name)}\" src=\"{DataUri(p)}\">")
                  .Append(cap.Length > 0 ? $"<figcaption>{E(cap)}</figcaption>" : "").Append("</figure>");
            }
            sb.Append("</div>");
        }
        sb.Append($"<p class=\"foot\">Generated by {AppInfo.Name} {AppInfo.Version} on {generated:yyyy-MM-dd HH:mm}. Output is cut to the first 200 characters per command; the full log is in run_*.txt next to the results file.</p>");
        sb.Append("</div></body></html>");
        return sb.ToString();
    }

    static string DataUri(ReportImage i) => $"data:{i.Mime};base64,{Convert.ToBase64String(i.Data)}";

    static void Tile(StringBuilder sb, string label, string n) =>
        sb.Append($"<div class=\"tile\"><div class=\"n\">{E(n)}</div><div class=\"l\">{E(label)}</div></div>");
}

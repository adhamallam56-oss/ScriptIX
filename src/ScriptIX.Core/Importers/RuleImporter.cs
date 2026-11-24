using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScriptIX;

public sealed class ImportReport
{
    public string Source { get; init; } = "";
    public List<RuleItem> Rules { get; } = new();
    public List<string> Problems { get; } = new();
    public List<string> Notes { get; } = new();
    public XccdfDocument? Scap { get; init; }
    public int Found => Rules.Count;
    public int Ready => Rules.Count(r => r.Status == RuleStatus.Ready);
    public int NeedsReview => Rules.Count(r => r.Status == RuleStatus.NeedsReview);
    public int Risky => Rules.Count(r => r.Status == RuleStatus.Risky);

    public string ToText()
    {
        var t = new StringBuilder($"{Found} rules found: {Ready} ready, {NeedsReview} need review, {Risky} risky.");
        foreach (var n in Notes) t.Append("\n").Append(n);
        if (Problems.Count > 0)
        {
            t.Append($"\n\n{Problems.Count} row(s) could not be used:\n- ").Append(string.Join("\n- ", Problems.Take(15)));
            if (Problems.Count > 15) t.Append($"\n- ... and {Problems.Count - 15} more");
        }
        return t.ToString();
    }
}

public static class RuleImporter
{
    public const long MaxTextFile = 100L * 1024 * 1024;

    static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    sealed record RuleFile(string Format, int Version, string Generator, IEnumerable<RuleItem> Rules);

    public static string ToJson(IEnumerable<RuleItem> rules) =>
        JsonSerializer.Serialize(new RuleFile("scriptix-rules", 1, $"{AppInfo.Name} {AppInfo.Version}", rules), WriteOptions);

    /// Reads ScriptIX rule files: a plain array of rules, or an object with a "rules" array (rule pack).
    /// Each rule may use flat fields (command, mode, expected, remediation) or pack fields
    /// (check: {command, compare, expected}, fix: {command} or "text", undo: ...).
    public static ImportReport FromJson(string text, string source = "")
    {
        using var doc = JsonDocument.Parse(text, new JsonDocumentOptions
        {
            AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip, MaxDepth = 32
        });
        var root = doc.RootElement;
        JsonElement arr;
        if (root.ValueKind == JsonValueKind.Array) arr = root;
        else if (root.ValueKind == JsonValueKind.Object && TryProp(root, "rules", out arr) && arr.ValueKind == JsonValueKind.Array) { }
        else throw new FormatException("The JSON file has no list of rules (expected an array, or an object with \"rules\").");

        var rep = new ImportReport { Source = source };
        if (root.ValueKind == JsonValueKind.Object && TryProp(root, "name", out var name) && name.ValueKind == JsonValueKind.String)
            rep.Notes.Add($"Rule pack: {name.GetString()}");

        int index = 0;
        foreach (var e in arr.EnumerateArray())
        {
            index++;
            if (e.ValueKind != JsonValueKind.Object) { rep.Problems.Add($"rule {index}: not an object"); continue; }
            var r = new RuleItem
            {
                Id = Str(e, "id"),
                Title = Str(e, "title", "name"),
                Notes = Str(e, "notes", "description", "rationale"),
                Shell = Str(e, "shell"),
                CheckShell = Str(e, "checkShell"),   // checks run with sh unless the rule says otherwise
                FullId = Str(e, "fullId"),
                Oval = Str(e, "oval"),
                CheckGap = Str(e, "checkGap"),
                ManualCheck = Str(e, "manualCheck"),
            };
            r.Target = ParseOs(Str(e, "target", "os", "platform"));
            r.Severity = ParseSeverity(Str(e, "severity"));

            if (TryProp(e, "check", out var check) && check.ValueKind == JsonValueKind.Object)
            {
                r.Command = Str(check, "command");
                r.Mode = ParseMode(Str(check, "compare", "mode"));
                r.Expected = Str(check, "expected");
            }
            else
            {
                r.Command = Str(e, "command", "check", "audit");
                r.Mode = ParseMode(Str(e, "mode", "compare"));
                r.Expected = Str(e, "expected");
            }
            r.Remediation = CommandOf(e, "remediation", "fix", "apply");
            var undo = CommandOf(e, "undo");
            r.Undo = undo.Equals("not reversible", StringComparison.OrdinalIgnoreCase) ? "" : undo;

            if (r.Id.Length == 0 && r.Title.Length == 0) { rep.Problems.Add($"rule {index}: no id or title"); continue; }
            if (r.Id.Length == 0) r.Id = $"R-{index:000}";
            if (TryProp(e, "selected", out var sel) && sel.ValueKind is JsonValueKind.True or JsonValueKind.False && r.Status != RuleStatus.Risky)
                r.Selected = sel.GetBoolean();
            else
                r.AutoSelect();
            rep.Rules.Add(r);
        }
        return rep;
    }

    /// CSV headers (any order, case-insensitive):
    /// id, title, os|target|platform, severity, check|audit|command, compare|mode, expected, fix|apply|remediation, undo, shell, notes
    public static ImportReport FromCsv(string text, string source = "")
    {
        var rows = Csv.Parse(text);
        if (rows.Count < 2) throw new FormatException("The CSV has no data rows.");
        var h = rows[0].Select(x => x.Trim().TrimStart('﻿').ToLowerInvariant()).ToList();
        int Col(params string[] names)
        {
            foreach (var n in names) { int i = h.IndexOf(n); if (i >= 0) return i; }
            return -1;
        }
        static string Get(string[] r, int i) => i >= 0 && i < r.Length ? r[i].Trim() : "";

        int cId = Col("id", "rule id", "recommendation"), cTitle = Col("title", "name"),
            cOs = Col("os", "target", "platform"), cSev = Col("severity"),
            cCmd = Col("check", "audit", "command"), cMode = Col("compare", "mode"),
            cExp = Col("expected"), cFix = Col("fix", "apply", "remediation"),
            cUndo = Col("undo"), cShell = Col("shell"), cNotes = Col("notes", "description");
        if (cId < 0 && cTitle < 0 && cFix < 0)
            throw new FormatException("No header row found. The first row must name the columns (id, title, os, severity, check, compare, expected, fix).");

        var rep = new ImportReport { Source = source };
        int line = 1;
        foreach (var r in rows.Skip(1))
        {
            line++;
            if (r.All(string.IsNullOrWhiteSpace)) continue;
            if (string.IsNullOrWhiteSpace(Get(r, cId)) && string.IsNullOrWhiteSpace(Get(r, cTitle)))
            {
                rep.Problems.Add($"line {line}: no id or title");
                continue;
            }
            var rule = new RuleItem
            {
                Id = Get(r, cId), Title = Get(r, cTitle), Target = ParseOs(Get(r, cOs)), Severity = ParseSeverity(Get(r, cSev)),
                Command = Get(r, cCmd), Mode = ParseMode(Get(r, cMode)), Expected = Get(r, cExp),
                Remediation = Get(r, cFix), Undo = Get(r, cUndo), Shell = Get(r, cShell), Notes = Get(r, cNotes)
            };
            if (rule.Id.Length == 0) rule.Id = $"R-{line:000}";
            rule.AutoSelect();
            rep.Rules.Add(rule);
        }
        return rep;
    }

    public static OsTarget ParseOs(string s) => s.Trim().ToLowerInvariant() switch
    {
        "linux" or "rhel" or "redhat" or "ubuntu" or "debian" or "suse" or "sles" => OsTarget.Linux,
        "aix" => OsTarget.AIX,
        "solaris" or "sunos" => OsTarget.Solaris,
        "hp-ux" or "hpux" => OsTarget.HPUX,
        "bsd" or "freebsd" or "openbsd" or "netbsd" or "dragonfly" => OsTarget.BSD,
        "unix" or "non-linux" => OsTarget.Unix,
        _ => OsTarget.Any
    };

    public static Severity ParseSeverity(string s) => s.Trim().ToLowerInvariant() switch
    {
        "low" or "info" or "informational" => Severity.Low,
        "high" or "critical" => Severity.High,
        _ => Severity.Medium
    };

    public static CompareMode ParseMode(string s)
    {
        var t = s.Trim().ToLowerInvariant().Replace("-", "").Replace("_", "").Replace(" ", "");
        return t switch
        {
            "rc" or "exitcode" or "rc0" => CompareMode.ExitCode,
            "contains" => CompareMode.Contains,
            "notcontains" => CompareMode.NotContains,
            "regex" or "ere" => CompareMode.Regex,
            "atleast" or "min" or ">=" => CompareMode.AtLeast,
            "atmost" or "max" or "<=" => CompareMode.AtMost,
            "oval" => CompareMode.Oval,
            "sce" => CompareMode.Sce,
            _ => CompareMode.Equals
        };
    }

    static bool TryProp(JsonElement e, string name, out JsonElement value)
    {
        foreach (var p in e.EnumerateObject())
            if (p.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) { value = p.Value; return true; }
        value = default;
        return false;
    }

    static string Str(JsonElement e, params string[] names)
    {
        foreach (var n in names)
            if (TryProp(e, n, out var v))
            {
                if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? "";
                if (v.ValueKind == JsonValueKind.Number) return v.GetRawText();
            }
        return "";
    }

    static string CommandOf(JsonElement e, params string[] names)
    {
        foreach (var n in names)
            if (TryProp(e, n, out var v))
            {
                if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? "";
                if (v.ValueKind == JsonValueKind.Object) return Str(v, "command");
            }
        return "";
    }
}

public static class Csv
{
    public static List<string[]> Parse(string text)
    {
        var rows = new List<string[]>();
        var row = new List<string>();
        var sb = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (quoted)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"') { sb.Append('"'); i++; }
                    else quoted = false;
                }
                else sb.Append(c);
            }
            else if (c == '"') quoted = true;
            else if (c == ',') { row.Add(sb.ToString()); sb.Clear(); }
            else if (c == '\n') { row.Add(sb.ToString()); sb.Clear(); rows.Add(row.ToArray()); row.Clear(); }
            else if (c != '\r') sb.Append(c);
        }
        if (sb.Length > 0 || row.Count > 0) { row.Add(sb.ToString()); rows.Add(row.ToArray()); }
        return rows;
    }

    /// RFC 4180 field, with spreadsheet formula injection neutralised.
    public static string Field(string? s)
    {
        s ??= "";
        if (s.Length > 0 && "=+-@".Contains(s[0])) s = "'" + s;
        return "\"" + s.Replace("\"", "\"\"") + "\"";
    }
}

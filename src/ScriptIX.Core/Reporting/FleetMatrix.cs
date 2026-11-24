using System.Text;

namespace ScriptIX;

public sealed record FleetResult(string Server, IReadOnlyList<ResultRow> Rows);

public sealed record FleetRow(string Id, string Title, string Severity, IReadOnlyList<string> Results)
{
    public bool Failed => Results.Contains("FAIL");
    public bool Differs => Results.Distinct().Count() > 1;
}

public sealed record FleetTable(IReadOnlyList<string> Servers, IReadOnlyList<FleetRow> Rows);

/// <summary>Several servers' results side by side: one row per rule, one column per server.</summary>
public static class FleetMatrix
{
    public const string None = "-";   // the rule was not in this server's results

    public static FleetTable Build(IReadOnlyList<FleetResult> sets)
    {
        var names = new List<string>();
        foreach (var s in sets)   // the same name twice (two runs of one server): number them
        {
            var n = s.Server;
            for (int i = 2; names.Contains(n, StringComparer.OrdinalIgnoreCase); i++) n = $"{s.Server} ({i})";
            names.Add(n);
        }
        var order = new List<(string Id, string Title, string Severity)>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var r in sets.SelectMany(s => s.Rows))
            if (seen.Add(r.Id)) order.Add((r.Id, r.Title, r.Severity));
        var maps = sets.Select(s => s.Rows.GroupBy(r => r.Id, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Last().Result, StringComparer.Ordinal)).ToList();
        return new(names, order.Select(o => new FleetRow(o.Id, o.Title, o.Severity, maps.Select(m => m.GetValueOrDefault(o.Id, None)).ToList())).ToList());
    }

    public static string Csv(FleetTable t)
    {
        // a ' in front keeps spreadsheets from running text as a formula
        static string Q(string s) => "\"" + (s.Length > 1 && "=+-@\t\r".Contains(s[0]) ? "'" + s : s).Replace("\"", "\"\"") + "\"";
        var sb = new StringBuilder();
        sb.Append(string.Join(",", new[] { "id", "title", "severity" }.Concat(t.Servers).Select(Q))).Append("\r\n");
        foreach (var r in t.Rows) sb.Append(string.Join(",", new[] { r.Id, r.Title, r.Severity }.Concat(r.Results).Select(Q))).Append("\r\n");
        return sb.ToString();
    }
}

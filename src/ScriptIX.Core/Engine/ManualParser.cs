using System.Text;
using System.Text.RegularExpressions;

namespace ScriptIX;

/// <summary>
/// Own-commands format: one command per line. "# text" titles the next command.
/// A trailing backslash continues the line. Markers at the end of a line (any number, any order):
///   ## expect: x | ## expect-exact: x | ## expect-regex: x | ## expect-not: x | ## expect-rc: N
///   ## timeout: SECONDS | ## os: linux|aix|any | ## id: NAME | ## shell: bash
/// </summary>
public static class ManualParser
{
    static readonly Regex Marker = new(
        @"\s##\s*(expect-regex|expect-exact|expect-not|expect-rc|expect|timeout|os|id|shell)\s*:",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static List<ScriptItem> Parse(string? text)
    {
        var items = new List<ScriptItem>();
        string? title = null;
        int n = 1;
        var lines = (text ?? "").Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var t = lines[i].Trim();
            if (t.Length == 0 || t.StartsWith("#!", StringComparison.Ordinal)) continue;
            if (t.StartsWith('#')) { title = t.TrimStart('#').Trim(); continue; }

            var sb = new StringBuilder(t);
            while (sb[^1] == '\\' && i + 1 < lines.Length)
                sb.Append('\n').Append(lines[++i].Trim());

            var cmd = sb.ToString();
            string mode = "rc0", expected = "", os = "any", shell = "sh";
            string? id = null;
            int timeout = 0;

            var ms = Marker.Matches(cmd);
            if (ms.Count > 0)
            {
                var head = cmd[..ms[0].Index].TrimEnd();
                for (int k = 0; k < ms.Count; k++)
                {
                    int start = ms[k].Index + ms[k].Length;
                    int end = k + 1 < ms.Count ? ms[k + 1].Index : cmd.Length;
                    var value = cmd[start..end].Trim();
                    switch (ms[k].Groups[1].Value.ToLowerInvariant())
                    {
                        case "expect": mode = "contains"; expected = value; break;
                        case "expect-exact": mode = "equals"; expected = value; break;
                        case "expect-regex": mode = "regex"; expected = value; break;
                        case "expect-not": mode = "notcontains"; expected = value; break;
                        case "expect-rc": mode = "rc"; expected = value; break;
                        case "timeout": int.TryParse(value, out timeout); break;
                        case "os": os = value; break;
                        case "id": id = value; break;
                        case "shell": shell = value.Equals("bash", StringComparison.OrdinalIgnoreCase) ? "bash" : "sh"; break;
                    }
                }
                cmd = head;
            }
            if (cmd.Length == 0) continue;
            items.Add(new ScriptItem(id ?? $"M-{n:000}", title ?? Short(cmd), "medium", os, mode, expected, cmd, timeout, shell));
            n++;
            title = null;
        }
        return items;
    }

    static string Short(string cmd)
    {
        var first = cmd.Split('\n')[0];
        return first.Length > 60 ? first[..60] + "..." : first;
    }
}

/// <summary>Checks before a script is created.</summary>
public static class Validator
{
    /// Problems that stop the script from being created.
    public static List<string> Blocking(IReadOnlyCollection<ScriptItem> items)
    {
        var list = new List<string>();
        foreach (var i in items)
        {
            if (string.IsNullOrWhiteSpace(i.Command)) list.Add($"{i.Id}: the command is empty.");
            if ((i.Id + i.Title + i.Expected + i.Command).Contains('\0')) list.Add($"{i.Id}: contains a NUL character. Remove it and try again.");
        }
        return list;
    }

    /// Things worth a look; the user can still continue.
    public static List<string> Warnings(IReadOnlyCollection<ScriptItem> items)
    {
        var list = new List<string>();
        foreach (var g in items.GroupBy(i => i.Id).Where(g => g.Count() > 1))
            list.Add($"Duplicate ID {g.Key} ({g.Count()}x): the script will number them {g.Key}_2, {g.Key}_3...");
        foreach (var i in items)
        {
            if (!QuotesClosed(i.Command))
                list.Add($"{i.Id}: quotes look unbalanced: {Trim(i.Command)}");
            if (i.Mode is "atleast" or "atmost" or "rc" && !long.TryParse(i.Expected, out _))
                list.Add($"{i.Id}: expects a number but the expected value is \"{Trim(i.Expected)}\".");
            if (i.Mode is "regex" && !IsValidRegex(i.Expected))
                list.Add($"{i.Id}: the expected regex looks malformed: {Trim(i.Expected)}");
        }
        return list;
    }

    /// <summary>Scans like sh does: '...' is literal, "..." honours \", a backslash outside quotes escapes one char.</summary>
    public static bool QuotesClosed(string s)
    {
        char q = '\0';
        for (int k = 0; k < s.Length; k++)
        {
            char c = s[k];
            if (q == '\'') { if (c == '\'') q = '\0'; }
            else if (q == '"') { if (c == '\\') k++; else if (c == '"') q = '\0'; }
            else if (c == '\\') k++;
            else if (c is '\'' or '"') q = c;
            else if (c == '#' && (k == 0 || char.IsWhiteSpace(s[k - 1]))) break;   // comment
        }
        return q == '\0';
    }

    static readonly (Regex Pattern, string Message, bool GnuOnly)[] Lint =
    {
        (new(@"(^|[\s;&|!])\[\[\s"), "uses [[ ]], which plain sh doesn't have", false),
        (new(@"\becho\s+-[en]\b"), "uses echo -e/-n, which differs between systems (use printf)", false),
        (new(@"(^|[;&|]\s*)source\s"), "uses source (use . instead)", false),
        (new(@"\$'"), "uses $'...' quoting, which isn't POSIX", false),
        (new(@"\$\{\w+(//|:[0-9])"), "uses ${var//x/y} or ${var:n}, which plain sh doesn't have", false),
        (new(@"(^|\s)function\s+\w+"), "uses the function keyword (write name() { ... })", false),
        (new(@"<\("), "uses process substitution <( ), which plain sh doesn't have", false),
        (new(@"(^|[;&|]\s*)local\s"), "uses local, which AIX ksh88 doesn't have", false),
        (new(@"\[\s[^\]]*\s==\s"), "uses == inside [ ] (use =)", false),
        (new(@"\bsed\s+(-[a-zA-Z]+\s+)*-[a-zA-Z]*i"), "uses sed -i, which AIX sed doesn't have (use setcfg/line_del)", true),
        (new(@"\breadlink\s+-f"), "uses readlink -f, which AIX doesn't have", true),
        (new(@"\bgrep\s+(-[a-zA-Z]+\s+)*-[a-zA-Z]*P"), "uses grep -P, which only GNU grep has", true),
        (new(@"\bstat\s+(-[a-zA-Z]+\s+)*-c"), "uses stat -c, which AIX doesn't have (use ls -ld)", true),
        (new(@"\bdate\s+(-[a-zA-Z]+\s+)*-d\b"), "uses date -d, which only GNU date has", true),
        (new(@"\bxargs\s+(-[a-zA-Z]+\s+)*-[a-zA-Z]*r"), "uses xargs -r, which only GNU xargs has", true),
        (new(@"(^|[;&|]\s*)timeout\s+\d"), "uses timeout, which AIX doesn't have (use ## timeout: N)", true),
        (new(@"\bsystemctl\b"), "uses systemctl, which AIX doesn't have", true),
    };

    /// Portability notes for commands that run on AIX (or "any" OS).
    public static List<string> Portability(IReadOnlyCollection<ScriptItem> items, int max = 40)
    {
        var list = new List<string>();
        foreach (var i in items)
        {
            if (i.Shell == "bash") continue;
            bool mayRunOnAix = RuleImporter.ParseOs(i.Target) != OsTarget.Linux;
            foreach (var (p, msg, gnu) in Lint)
                if ((!gnu || mayRunOnAix) && p.IsMatch(i.Command))
                    list.Add($"{i.Id}: {msg}.");
            if (list.Count >= max) break;
        }
        return list;
    }

    static bool IsValidRegex(string s)
    {
        try { _ = new Regex(s); return true; }
        catch (ArgumentException) { return false; }
    }

    static string Trim(string s) => s.Length > 60 ? s[..60] + "..." : s;
}

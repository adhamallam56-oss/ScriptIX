using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ScriptIX;

/// <summary>
/// Turns script items into one POSIX sh script. Every user value goes into the script only as a
/// single-quoted literal, so no input can change the script's structure. Output is deterministic:
/// the same input always gives the same bytes (timestamps are computed when the script runs).
/// </summary>
public static class ScriptBuilder
{
    public const string BodyMarker = "#__SCRIPTIX_BODY__";
    static readonly Regex BadIdChars = new(@"[^A-Za-z0-9._:-]", RegexOptions.Compiled);
    static readonly Regex Control = new(@"[\x00-\x1F\x7F]", RegexOptions.Compiled);
    static readonly Lazy<string> Runtime = new(() => Resource("ScriptIX.runtime.sh"));
    static readonly Lazy<string> OvalEngine = new(() => Resource("ScriptIX.oval.awk"));

    /// Single-quote a value for sh: 'it'\''s' . The only transformation is this escaping.
    public static string Q(string s) => "'" + s.Replace("'", "'\\''") + "'";

    public static string SafeId(string? id, int n)
    {
        var s = BadIdChars.Replace((id ?? "").Trim(), "_");
        if (s.Length > 100) s = s[..100];
        return s.Length == 0 ? $"ITEM-{n:000}" : s;
    }

    public static string SafeTitle(string? title)
    {
        var s = Control.Replace(title ?? "", " ").Trim();
        return s.Length > 200 ? s[..200] : s;
    }

    public static GeneratedScript Build(ScriptJob job, ScriptOptions opt)
    {
        if (job.Items.Count == 0) throw new ArgumentException("A script needs at least one command.");
        foreach (var i in job.Items)
            if ((i.Id + i.Title + i.Expected + i.Command + i.Data).Contains('\0'))
                throw new FormatException($"{i.Id}: contains a NUL character, which a shell script can't hold.");

        // Unique, safe IDs (they are used with --only/--skip and in file names).
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var items = new List<ScriptItem>(job.Items.Count);
        int n = 0;
        foreach (var i in job.Items)
        {
            n++;
            var id = SafeId(i.Id, n);
            var unique = id;
            for (int k = 2; !seen.Add(unique); k++) unique = $"{id}_{k}";
            items.Add(i with
            {
                Id = unique,
                Title = SafeTitle(i.Title),
                Command = i.Command.Replace("\r\n", "\n").Trim(),
                Expected = i.Expected.Replace("\r\n", "\n"),
                Timeout = Math.Clamp(i.Timeout, 0, 86400),
                Shell = i.Shell == "bash" ? "bash" : "sh"
            });
        }

        // a check-only script changes nothing, so a check that merely mentions root login is not risky
        int risky = opt.ReadOnly ? 0 : items.Count(i => Risk.IsRisky(i.Command));
        var lines = new StringBuilder();
        foreach (var i in items)
        {
            var flags = (Helpers.IsHelperOnly(i.Command) && i.Shell == "sh" ? "h" : "") + (i.Shell == "bash" ? "b" : "") + ModeFlag(i);
            lines.Append("run_item ")
                 .Append(Q(i.Id)).Append(' ')
                 .Append(Q(i.Title)).Append(' ')
                 .Append(Q(Sev(i.Severity))).Append(' ')
                 .Append(Q(Target(i.Target))).Append(' ')
                 .Append(Q(Mode(i.Mode))).Append(' ')
                 .Append(Q(i.Expected)).Append(' ')
                 .Append(Q(i.Timeout.ToString(System.Globalization.CultureInfo.InvariantCulture))).Append(' ')
                 .Append(Q(flags)).Append(' ')
                 .Append(Q(i.Command)).Append('\n');
        }

        var kind = Regex.Replace(opt.Kind.ToLowerInvariant(), "[^a-z0-9-]", "");
        var body = Runtime.Value
            .Replace("{{KIND}}", kind)
            .Replace("{{VERSION}}", AppInfo.Version)
            .Replace("{{TOTAL}}", items.Count.ToString(System.Globalization.CultureInfo.InvariantCulture))
            .Replace("{{RISKY}}", risky.ToString(System.Globalization.CultureInfo.InvariantCulture))
            .Replace("{{STOP}}", opt.StopOnFail ? "1" : "0")
            .Replace("{{NEEDROOT}}", opt.RequireRoot ? "1" : "0")
            .Replace("{{TIMEOUT}}", Math.Clamp(opt.TimeoutSeconds, 0, 86400).ToString(System.Globalization.CultureInfo.InvariantCulture))
            .Replace("{{REDACT}}", opt.Redact ? "1" : "0")
            .Replace("{{READONLY}}", opt.ReadOnly ? "1" : "0");
        if (!body.EndsWith('\n')) body += "\n";
        // these two go in by position, so user text is never treated as a placeholder
        var part = body.Split("{{ITEMS}}\n");
        var rest = part[1].Split("{{OVAL}}\n");
        var oval = OvalData(items);
        body = part[0] + lines + rest[0] + oval + rest[1];

        var sha = Hex(SHA256.HashData(Encoding.UTF8.GetBytes(body)));
        var input = Hex(SHA256.HashData(Encoding.UTF8.GetBytes(lines + oval + "|" + opt))).Substring(0, 16);

        var header = new StringBuilder()
            .Append("#!/bin/sh\n")
            .Append($"# {AppInfo.Name} {AppInfo.Version} - {kind} script for Linux and AIX (POSIX sh)\n")
            .Append($"# Commands: {items.Count}   Flagged risky: {risky}   Input hash: {input}\n")
            .Append("# Help: sh THIS_FILE --help    Preview: --dry-run    Integrity: --verify\n")
            .Append("# Do not edit anything below the BODY marker, or --verify will report a change.\n")
            .Append("# Solaris: use the POSIX shell when /bin/sh is the old Bourne shell.\n")
            .Append("if [ -z \"${SX_REEXEC:-}\" ] && [ -x /usr/xpg4/bin/sh ] && [ \"`uname -s`\" = SunOS ]; then\n")
            .Append("  SX_REEXEC=1; export SX_REEXEC; exec /usr/xpg4/bin/sh \"$0\" \"$@\"\n")
            .Append("fi\n")
            .Append($"SX_SHA256='{sha}'\n")
            .Append(BodyMarker).Append('\n');

        var content = header + body;
        return new GeneratedScript
        {
            FileName = job.FileName,
            Kind = kind,
            Purpose = job.Purpose,
            Content = content,
            Sha256 = sha,
            Count = items.Count,
            RiskyCount = risky,
            LineCount = content.Count(c => c == '\n')
        };
    }

    static string Hex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();

    static string Sev(string s) => s.ToLowerInvariant() switch { "low" => "low", "high" => "high", _ => "medium" };

    // Values understood by os_match in the runtime: any, Linux, AIX, SunOS, HP-UX, BSD, Unix.
    static string Target(string t) => TargetText(RuleImporter.ParseOs(t));

    static string ModeFlag(ScriptItem i) => Mode(i.Mode) switch { "oval" => "o", "sce" => "s", "manual" => "m", _ => "" };

    /// The OVAL engine and the compiled checks, only when some item needs them.
    static string OvalData(List<ScriptItem> items)
    {
        if (!items.Any(i => i.Data.Length > 0)) return "";
        var sb = new StringBuilder("mkdir \"$WORK/ir\" \"$WORK/c\" || { err \"Cannot create $WORK/ir\"; exit 3; }\n");
        sb.Append("cat > \"$WORK/oval.awk\" <<'SX_END_OF_ENGINE'\n").Append(OvalEngine.Value);
        if (sb[^1] != '\n') sb.Append('\n');
        sb.Append("SX_END_OF_ENGINE\ncat > \"$WORK/oval.ir\" <<'SX_END_OF_CHECKS'\n");
        foreach (var i in items.Where(i => i.Data.Length > 0))
            sb.Append("#ID\t").Append(i.Id).Append('\n').Append(i.Data.Replace("\r", "").TrimEnd('\n')).Append('\n');
        return sb.Append("SX_END_OF_CHECKS\n")
                 .Append("awk -v D=\"$WORK/ir\" '/^#ID\\t/ { if (f != \"\") close(f); f = D \"/\" substr($0, 5); next } { print > f }' \"$WORK/oval.ir\"\n")
                 .ToString();
    }

    static string Mode(string m) => m.Trim().ToLowerInvariant() switch
    {
        "oval" => "oval",
        "sce" => "sce",
        "manual" => "manual",
        "rc" or "exitcode" => "rc",
        "exact" or "equals" => "equals",
        "contains" => "contains",
        "notcontains" => "notcontains",
        "regex" => "regex",
        "atleast" => "atleast",
        "atmost" => "atmost",
        _ => "rc0"
    };

    static string TargetText(OsTarget t) => t switch
    {
        OsTarget.Linux => "Linux",
        OsTarget.AIX => "AIX",
        OsTarget.Solaris => "SunOS",
        OsTarget.HPUX => "HP-UX",
        OsTarget.BSD => "BSD",
        OsTarget.Unix => "Unix",
        _ => "any"
    };

    static string ModeText(CompareMode m) => m == CompareMode.ExitCode ? "rc" : m.ToString().ToLowerInvariant();

    internal static string Resource(string name)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
                      ?? throw new InvalidOperationException($"The {name} resource is missing from ScriptIX.Core.");
        using var r = new StreamReader(s, Encoding.UTF8);
        return r.ReadToEnd().Replace("\r\n", "\n");
    }

    // ---------- items from rules ----------

    /// Fix commands of the given rules: each passes when it exits 0.
    public static List<ScriptItem> ApplyItems(IEnumerable<RuleItem> rules) =>
        rules.Where(r => !string.IsNullOrWhiteSpace(r.Remediation))
             .Select(r => new ScriptItem(r.Id, r.Title, r.Severity.ToString(), TargetText(r.Target),
                                         "rc0", "", r.Remediation.Trim(), 0, r.Shell))
             .ToList();

    /// Check commands of the given rules, compared with the expected value.
    public static List<ScriptItem> CheckItems(IEnumerable<RuleItem> rules, bool manualToo = false)
    {
        var list = new List<ScriptItem>();
        foreach (var r in rules)
        {
            var cmd = r.Command.Trim();
            var os = TargetText(r.Target);
            if (cmd.Length == 0)
            {
                if (manualToo && r.ManualCheck.Length > 0)
                    list.Add(new ScriptItem(r.Id, r.Title, r.Severity.ToString(), os, "manual", "", r.ManualCheck, OvalTimeout, "sh", r.Oval));
            }
            else if (r.Mode == CompareMode.Oval && r.Oval.Length > 0 && cmd.StartsWith("oval ", StringComparison.Ordinal))
                list.Add(new ScriptItem(r.Id, r.Title, r.Severity.ToString(), "any", "oval", "", cmd, OvalTimeout, "sh", r.Oval));   // OVAL decides itself where it applies
            else
                list.Add(new ScriptItem(r.Id, r.Title, r.Severity.ToString(), os, r.Mode == CompareMode.Oval ? "rc0" : ModeText(r.Mode), r.Expected, cmd, 0, r.CheckShell));
        }
        return list;
    }

    /// A check that walks the whole disk needs longer than the usual time limit.
    public const int OvalTimeout = 900;

    /// The rules' own undo commands, in reverse order.
    public static List<ScriptItem> UndoItems(IEnumerable<RuleItem> rules) =>
        rules.Where(r => !string.IsNullOrWhiteSpace(r.Undo))
             .Reverse()
             .Select(r => new ScriptItem(r.Id, "Undo: " + r.Title, r.Severity.ToString(), TargetText(r.Target),
                                         "rc0", "", r.Undo.Trim(), 0, r.Shell))
             .ToList();
}

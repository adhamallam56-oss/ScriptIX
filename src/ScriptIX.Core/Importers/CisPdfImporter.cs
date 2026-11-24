using System.Text;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;

namespace ScriptIX;

/// <summary>One line of text from a PDF page. Code = printed in a monospace font (CIS command boxes).</summary>
public sealed record PdfLine(string Text, bool Code, int Page);

/// <summary>
/// Imports CIS Benchmark PDFs (Experimental). CIS PDFs share one layout per recommendation:
/// "1.2.3 Title (Automated|Manual)", Profile Applicability, Description, Rationale, Audit, Remediation...
/// Commands are the monospace lines. Nothing is invented: a remediation without a command line
/// stays empty (Needs review), and "Manual" recommendations always need review.
/// The benchmark file is the user's own copy; nothing from it is shipped with ScriptIX.
/// </summary>
public static class CisPdfImporter
{
    public const long MaxPdf = 200L * 1024 * 1024;

    public static ImportReport Load(Stream stream, string source, CancellationToken ct = default)
    {
        List<PdfLine> lines;
        try
        {
            lines = ReadLines(stream, ct);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) when (ex is not FormatException)
        {
            throw new FormatException("This PDF could not be read (damaged, encrypted or not a PDF). " + ex.Message, ex);
        }
        if (lines.Count == 0)
            throw new FormatException("No text was found in this PDF. It may be a scanned image; ScriptIX needs a text PDF.");
        return Parse(lines, source, ct);
    }

    // ---------------------------------------------------------------- PDF -> lines
    static readonly Regex Mono = new("courier|mono|consol|menlo|code|typewriter|fixed", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    static List<PdfLine> ReadLines(Stream stream, CancellationToken ct)
    {
        var result = new List<PdfLine>();
        using var doc = PdfDocument.Open(stream);
        foreach (var page in doc.GetPages())
        {
            ct.ThrowIfCancellationRequested();
            double h = page.Height;
            var letters = page.Letters.Where(l => l.Value.Length > 0).ToList();
            // group into lines by baseline (top of page first)
            var clusters = new List<List<Letter>>();
            foreach (var l in letters.OrderByDescending(l => Math.Round(l.StartBaseLine.Y, 1)).ThenBy(l => l.StartBaseLine.X))
            {
                var y = l.StartBaseLine.Y;
                var c = clusters.Count > 0 && Math.Abs(clusters[^1][0].StartBaseLine.Y - y) < 2.0 ? clusters[^1] : null;
                if (c == null) clusters.Add(c = new List<Letter>());
                c.Add(l);
            }
            foreach (var c in clusters)
            {
                double y = c[0].StartBaseLine.Y;
                if (y > h * 0.955 || y < h * 0.045) continue;   // running header / footer
                var ordered = c.OrderBy(l => l.StartBaseLine.X).ToList();
                int mono = ordered.Count(l => !string.IsNullOrWhiteSpace(l.Value) && Mono.IsMatch(l.FontName ?? ""));
                int visible = ordered.Count(l => !string.IsNullOrWhiteSpace(l.Value));
                bool code = visible > 0 && mono * 2 > visible;
                var text = Join(ordered, code);
                if (text.Trim().Length == 0) continue;
                result.Add(new PdfLine(code ? text.TrimEnd() : Regex.Replace(text, @"\s+", " ").Trim(), code, page.Number));
            }
        }
        return result;
    }

    /// Rebuilds a line from letters: spaces come from explicit space glyphs or from gaps.
    /// In monospace lines the number of spaces follows the gap, so indentation and "a  b" survive.
    static string Join(List<Letter> ls, bool code)
    {
        var sb = new StringBuilder();
        double right = double.NaN, cw = 0;
        if (code)
        {
            var w = ls.Where(l => l.Value.Trim().Length > 0).Select(l => l.Width).Where(x => x > 0).ToList();
            cw = w.Count > 0 ? w.Average() : 0;
        }
        foreach (var l in ls)
        {
            if (l.Value == " " || l.Value == " ") { sb.Append(' '); right = l.EndBaseLine.X; continue; }
            if (!double.IsNaN(right))
            {
                double gap = l.StartBaseLine.X - right;
                double unit = code && cw > 0 ? cw : Math.Max(l.PointSize * 0.25, 1);
                if (gap > unit * 0.6 && (sb.Length == 0 || sb[^1] != ' '))
                    sb.Append(' ', code && cw > 0 ? Math.Max(1, (int)Math.Round(gap / cw)) : 1);
            }
            sb.Append(Normalize(l.Value));
            right = l.EndBaseLine.X;
        }
        return sb.ToString();
    }

    // PDF typography that would break a shell command
    static string Normalize(string s) => s
        .Replace('‘', '\'').Replace('’', '\'').Replace('“', '"').Replace('”', '"')
        .Replace('–', '-').Replace('—', '-').Replace('−', '-').Replace(" ", " ")
        .Replace("ﬁ", "fi").Replace("ﬂ", "fl");

    // ---------------------------------------------------------------- lines -> rules
    static readonly Regex Heading = new(@"^(\d{1,2}(?:\.\d{1,3}){1,6})\s+(.+?)\s*\((Automated|Manual|Scored|Not Scored)\)\s*$", RegexOptions.Compiled);
    static readonly Regex HeadingStart = new(@"^(\d{1,2}(?:\.\d{1,3}){1,6})\s+\S", RegexOptions.Compiled);
    static readonly string[] Labels =
    {
        "Profile Applicability:", "Description:", "Rationale:", "Impact:", "Audit:", "Remediation:",
        "Default Value:", "References:", "Additional Information:", "CIS Controls:", "MITRE ATT&CK Mappings:", "Note:"
    };

    sealed class Rec
    {
        public string Number = "", Title = "", Kind = "";
        public readonly List<string> Profiles = new();
        public readonly Dictionary<string, List<PdfLine>> Sections = new();
    }

    /// <summary>Turns extracted lines into rules. Public so it can be checked without a PDF.</summary>
    public static ImportReport Parse(IReadOnlyList<PdfLine> lines, string source, CancellationToken ct = default)
    {
        var target = DetectOs(lines);
        var recs = new List<Rec>();
        Rec? cur = null;
        string? section = null;

        for (int i = 0; i < lines.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var ln = lines[i];
            if (!ln.Code && TryHeading(lines, i, out var rec, out var used))
            {
                recs.Add(cur = rec);
                section = null;
                i += used - 1;
                continue;
            }
            if (cur == null) continue;
            if (!ln.Code)
            {
                var label = Labels.FirstOrDefault(l => ln.Text.Equals(l, StringComparison.OrdinalIgnoreCase) ||
                                                       ln.Text.StartsWith(l + " ", StringComparison.OrdinalIgnoreCase));
                if (label != null)
                {
                    section = label.TrimEnd(':');
                    var rest = ln.Text[label.Length..].Trim();
                    if (!cur.Sections.ContainsKey(section)) cur.Sections[section] = new List<PdfLine>();
                    if (rest.Length > 0) cur.Sections[section].Add(ln with { Text = rest });
                    continue;
                }
            }
            if (section == null) continue;
            if (section == "Profile Applicability" && !ln.Code)
            {
                var p = ln.Text.TrimStart('•', '•', '-', '*', ' ').Trim();
                if (p.StartsWith("Level", StringComparison.OrdinalIgnoreCase)) cur.Profiles.Add(p);
                continue;
            }
            cur.Sections[section].Add(ln);
        }

        var rep = new ImportReport { Source = source, Scap = new XccdfDocument() };
        var doc = rep.Scap;
        doc.Title = lines.Take(40).FirstOrDefault(l => l.Text.Contains("Benchmark", StringComparison.OrdinalIgnoreCase))?.Text ?? Path.GetFileName(source);
        var profiles = new Dictionary<string, XccdfProfile>(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int withCheck = 0, withFix = 0, manual = 0;

        foreach (var r in recs)
        {
            if (!seen.Add(r.Number)) { rep.Problems.Add($"{r.Number}: appears twice, the second one was skipped."); continue; }
            var audit = r.Sections.GetValueOrDefault("Audit") ?? new();
            var remed = r.Sections.GetValueOrDefault("Remediation") ?? new();
            if (audit.Count == 0 && remed.Count == 0)
            {
                rep.Problems.Add($"{r.Number} {Short(r.Title)}: no Audit or Remediation section found.");
                continue;
            }

            var check = Commands(audit, out var checkScript, out var outputs);
            var fix = Commands(remed, out var fixScript, out _);
            bool isManual = r.Kind is "Manual" or "Not Scored";
            var rule = new RuleItem
            {
                Id = r.Number,
                Title = r.Title,
                Target = target,
                Severity = Severity.Medium,
                Shell = target == OsTarget.Linux || BashShebang(audit) || BashShebang(remed) ? "bash" : "sh",
                CheckShell = BashShebang(audit) ? "bash" : "sh",
                Notes = NotesFor(r, audit, remed),
                Mode = CompareMode.ExitCode,
                Expected = "0",
            };
            if (check.Length > 0)
            {
                withCheck++;
                rule.Command = check;
                if (checkScript && check.Contains("** PASS **", StringComparison.Ordinal)) { rule.Mode = CompareMode.Contains; rule.Expected = "** PASS **"; }
                else if (!checkScript && outputs.Count > 0 && !outputs.Any(o => o.Contains('<')))
                { rule.Mode = CompareMode.Equals; rule.Expected = string.Join("\n", outputs); }
            }
            if (fix.Length > 0) { withFix++; rule.Remediation = fix; }
            if (isManual) { manual++; rule.ReviewReason = "CIS marks this recommendation Manual: read it and adapt the fix before using it."; }
            rule.InProfile = true;
            doc.Rules.Add(new XccdfRule { Id = r.Number, ShortId = r.Number, Title = r.Title });
            (doc.Prebuilt ??= new()).Add(rule);

            foreach (var p in r.Profiles)
            {
                if (!profiles.TryGetValue(p, out var prof)) profiles[p] = prof = new XccdfProfile { Id = p, Title = p };
                prof.Selected.Add(r.Number);
            }
        }

        if (doc.Prebuilt == null || doc.Prebuilt.Count == 0)
            throw new FormatException("No CIS recommendations were found in this PDF. ScriptIX expects the CIS Benchmark layout (\"1.2.3 Title (Automated)\", Audit:, Remediation:).");

        // "Level 2" builds on "Level 1": include its rules, like CIS does
        foreach (var p in profiles.Values)
        {
            var m = Regex.Match(p.Title, @"^Level\s*2\b(.*)$", RegexOptions.IgnoreCase);
            if (m.Success && profiles.TryGetValue("Level 1" + m.Groups[1].Value, out var l1)) p.Selected.UnionWith(l1.Selected);
        }
        doc.Profiles.AddRange(profiles.Values.OrderBy(p => p.Title, StringComparer.OrdinalIgnoreCase));

        rep.Rules.AddRange(doc.ToRules(null));
        rep.Notes.Add($"CIS PDF import (Experimental): {doc.Title}");
        rep.Notes.Add($"Target OS: {(target == OsTarget.Any ? "not detected (any)" : target.ToString())}. {recs.Count} recommendations, {withCheck} with an audit command, {withFix} with fix commands.");
        if (manual > 0) rep.Notes.Add(manual == 1 ? "1 is marked Manual by CIS and always needs review." : $"{manual} are marked Manual by CIS and always need review.");
        rep.Notes.Add("Fixes written as prose (\"edit the file and set...\") have no command and need review. Nothing is guessed.");
        if (doc.Profiles.Count > 0) rep.Notes.Add($"Pick a profile ({string.Join(", ", doc.Profiles.Select(p => p.Title))}) to tick its ready rules.");
        rep.Notes.Add("Always check a few rules against the PDF: text extraction from PDFs is never perfect.");
        return rep;
    }

    static bool TryHeading(IReadOnlyList<PdfLine> lines, int i, out Rec rec, out int used)
    {
        rec = new Rec(); used = 0;
        if (!HeadingStart.IsMatch(lines[i].Text)) return false;
        // the title may wrap over up to 3 lines before "(Automated)"
        var text = lines[i].Text;
        for (int n = 1; n <= 3; n++)
        {
            var m = Heading.Match(text);
            if (m.Success)
            {
                // a real recommendation (not the table of contents) is followed by "Profile Applicability:"
                bool real = false;
                for (int k = i + n; k < Math.Min(lines.Count, i + n + 6); k++)
                    if (lines[k].Text.StartsWith("Profile Applicability", StringComparison.OrdinalIgnoreCase)) { real = true; break; }
                if (!real) return false;
                rec.Number = m.Groups[1].Value;
                rec.Title = m.Groups[2].Value.Trim();
                rec.Kind = m.Groups[3].Value;
                used = n;
                return true;
            }
            if (i + n >= lines.Count || lines[i + n].Code || HeadingStart.IsMatch(lines[i + n].Text)) return false;
            text += " " + lines[i + n].Text;
        }
        return false;
    }

    /// <summary>
    /// Commands in a section: a "#!" block is one script; otherwise lines that start with a root prompt
    /// ("# " or "$ ") are commands (a trailing "\" joins the next line) and the monospace lines right
    /// after a command are its expected output. If no line has a prompt, the monospace lines of an
    /// Audit section are taken as commands only when they look like commands, never in a Remediation
    /// (there they are usually file content to type into a file).
    /// </summary>
    static string Commands(List<PdfLine> sec, out bool script, out List<string> outputs)
    {
        script = false;
        outputs = new List<string>();
        var code = sec.Where(l => l.Code).Select(l => l.Text).ToList();
        if (code.Count == 0) return "";

        int shebang = code.FindIndex(l => l.TrimStart().StartsWith("#!", StringComparison.Ordinal));
        if (shebang >= 0)
        {
            script = true;
            // the script runs to the end of its monospace block
            var block = new List<string>();
            int start = sec.FindIndex(l => l.Code && l.Text.TrimStart().StartsWith("#!", StringComparison.Ordinal));
            for (int k = start + 1; k < sec.Count && sec[k].Code; k++) block.Add(sec[k].Text);
            return string.Join("\n", block).Trim('\n');
        }

        var cmds = new List<string>();
        bool afterCmd = false;
        for (int k = 0; k < code.Count; k++)
        {
            var t = code[k].TrimStart();
            if (t.StartsWith("# ", StringComparison.Ordinal) || t.StartsWith("$ ", StringComparison.Ordinal))
            {
                var c = t[2..].Trim();
                while (c.EndsWith('\\') && k + 1 < code.Count) c = c + "\n" + code[++k].Trim();
                if (c.Length > 0) cmds.Add(c);
                afterCmd = true;
            }
            else if (afterCmd && cmds.Count == 1 && t.Length > 0) outputs.Add(code[k].TrimEnd());
        }
        if (cmds.Count != 1) outputs.Clear();
        return string.Join("\n", cmds);
    }

    static bool BashShebang(List<PdfLine> sec) =>
        sec.Any(l => l.Code && l.Text.TrimStart().StartsWith("#!", StringComparison.Ordinal) && l.Text.Contains("bash", StringComparison.Ordinal));

    static string NotesFor(Rec r, List<PdfLine> audit, List<PdfLine> remed)
    {
        string Prose(IEnumerable<PdfLine> l, int max)
        {
            var s = string.Join(" ", l.Select(x => x.Text.Trim()));
            return s.Length > max ? s[..max] + "..." : s;
        }
        var sb = new StringBuilder($"CIS {r.Number} ({r.Kind})");
        if (r.Profiles.Count > 0) sb.Append(" - ").Append(string.Join(", ", r.Profiles));
        if (r.Sections.TryGetValue("Description", out var d)) sb.Append("\n\n").Append(Prose(d, 700));
        if (audit.Count > 0) sb.Append("\n\nAudit (from the PDF): ").Append(Prose(audit, 900));
        if (remed.Count > 0) sb.Append("\n\nRemediation (from the PDF): ").Append(Prose(remed, 900));
        return sb.ToString();
    }

    static OsTarget DetectOs(IReadOnlyList<PdfLine> lines)
    {
        var head = string.Join(" ", lines.Take(60).Select(l => l.Text));
        if (Regex.IsMatch(head, @"\bAIX\b")) return OsTarget.AIX;
        if (Regex.IsMatch(head, @"Solaris", RegexOptions.IgnoreCase)) return OsTarget.Solaris;
        if (Regex.IsMatch(head, @"HP-UX", RegexOptions.IgnoreCase)) return OsTarget.HPUX;
        if (Regex.IsMatch(head, @"FreeBSD|OpenBSD|NetBSD", RegexOptions.IgnoreCase)) return OsTarget.BSD;
        if (Regex.IsMatch(head, @"Linux|Ubuntu|Debian|Red Hat|RHEL|SUSE|Rocky|AlmaLinux|CentOS|Fedora", RegexOptions.IgnoreCase)) return OsTarget.Linux;
        return OsTarget.Any;
    }

    static string Short(string s) => s.Length > 60 ? s[..60] + "..." : s;
}

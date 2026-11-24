using System.Text;

namespace ScriptIX;

/// <summary>
/// Builds an unsent e-mail (.eml, "X-Unsent: 1") with the scripts attached. Outlook, Thunderbird and
/// Windows Mail open it as a draft the user reviews and sends. ScriptIX never sends mail and never sees
/// a password. Attachments are base64, so LF line endings and the SHA-256 survive the trip.
/// </summary>
public static class EmailDraft
{
    public static string AutoSubject(IReadOnlyList<GeneratedScript> scripts)
    {
        if (scripts.Count == 0) return "ScriptIX script";
        var cmds = scripts.Sum(s => s.Count);
        return scripts.Count == 1
            ? $"ScriptIX: {scripts[0].FileName} ({scripts[0].CountText})"
            : $"ScriptIX: {scripts.Count} scripts ({cmds} commands) - {string.Join(", ", scripts.Select(s => s.FileName))}";
    }

    public static string AutoBody(IReadOnlyList<GeneratedScript> scripts, bool asTxt)
    {
        var b = new StringBuilder();
        b.Append("Hello,\n\nAttached ").Append(scripts.Count == 1 ? "is a script" : "are scripts")
         .Append($" made with {AppInfo.Name} {AppInfo.Version}. They are plain POSIX sh and run on AIX 7.1+, Linux and other Unix.\n\n");
        foreach (var s in scripts)
        {
            b.Append($"- {s.FileName}: {s.Purpose}. {s.CountText}.\n");
            b.Append($"  SHA-256: {s.Sha256}\n");
        }
        b.Append("\nHow to run (as root, or with sudo):\n");
        if (asTxt) b.Append("  0. Rename each attachment: drop the .txt at the end (mail filters block .sh files).\n");
        var first = scripts.FirstOrDefault(s => s.Kind != "check") ?? scripts.FirstOrDefault();
        var f = first?.FileName ?? "SCRIPT.sh";
        b.Append($"  1. Copy it to the server, then check nothing changed on the way:  sh {f} --verify\n");
        b.Append($"     (it must print the same SHA-256 as above)\n");
        b.Append($"  2. Preview, changes nothing:  sh {f} --dry-run\n");
        b.Append($"  3. Run it (it asks before changing anything; keep a second session open):  sh {f}\n");
        b.Append($"  4. Undo if needed:  sh {f} --undo <folder>/changes_*.manifest\n");
        if (scripts.Any(s => s.Kind == "check"))
            b.Append($"  Check-only script, changes nothing:  sh {scripts.First(s => s.Kind == "check").FileName} -y\n");
        b.Append("\nPlease send back the results_*.csv file from the output folder.\n\nThanks\n");
        return b.ToString();
    }

    /// <summary>The .eml text. Lines use CRLF as mail requires; attachment bytes are untouched.</summary>
    public static string Build(string to, string subject, string body, IReadOnlyList<GeneratedScript> attach, bool asTxt)
    {
        var boundary = "=_ScriptIX_" + Guid.NewGuid().ToString("N");
        var m = new StringBuilder();
        void L(string s) => m.Append(s).Append("\r\n");

        if (!string.IsNullOrWhiteSpace(to)) L("To: " + Clean(to));
        L("Subject: " + Header(subject));
        L("X-Unsent: 1");
        L("MIME-Version: 1.0");
        L($"Content-Type: multipart/mixed; boundary=\"{boundary}\"");
        L("");
        L("--" + boundary);
        L("Content-Type: text/plain; charset=utf-8");
        L("Content-Transfer-Encoding: base64");
        L("");
        Base64(Encoding.UTF8.GetBytes(body.Replace("\r\n", "\n").Replace("\n", "\r\n")));
        foreach (var s in attach)
        {
            var name = asTxt ? s.FileName + ".txt" : s.FileName;
            L("--" + boundary);
            L($"Content-Type: {(asTxt ? "text/plain" : "application/x-sh")}; charset=utf-8; name=\"{name}\"");
            L("Content-Transfer-Encoding: base64");
            L($"Content-Disposition: attachment; filename=\"{name}\"");
            L("");
            Base64(new UTF8Encoding(false).GetBytes(s.Content));
        }
        L("--" + boundary + "--");
        return m.ToString();

        void Base64(byte[] data)
        {
            var t = Convert.ToBase64String(data);
            for (int i = 0; i < t.Length; i += 76) L(t.Substring(i, Math.Min(76, t.Length - i)));
        }
    }

    /// <summary>mailto: link without attachment, for mail apps that can't open .eml drafts.</summary>
    public static string MailTo(string to, string subject, string body)
    {
        const int Max = 1800;   // many mail apps cut longer links
        if (body.Length > Max) body = body[..Max] + "\n...";
        return $"mailto:{Uri.EscapeDataString(Clean(to)).Replace("%40", "@").Replace("%2C", ",")}" +
               $"?subject={Uri.EscapeDataString(Clean(subject))}&body={Uri.EscapeDataString(body.Replace("\r\n", "\n").Replace("\n", "\r\n"))}";
    }

    static string Clean(string s) => s.Replace("\r", " ").Replace("\n", " ").Trim();

    static string Header(string s)
    {
        s = Clean(s);
        return s.All(c => c >= 32 && c < 127) ? s : "=?utf-8?B?" + Convert.ToBase64String(Encoding.UTF8.GetBytes(s)) + "?=";
    }
}

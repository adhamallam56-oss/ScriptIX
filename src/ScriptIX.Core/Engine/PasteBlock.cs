namespace ScriptIX;

/// <summary>
/// One block to paste into an SSH session: writes the script with a quoted here-document
/// (nothing inside is expanded), checks its SHA-256 with --verify and, for scripts that
/// change things, previews them with --dry-run. Works in ksh88, ksh93, bash, dash and mksh.
/// </summary>
public static class PasteBlock
{
    /// <summary>Lines longer than this can be cut by the terminal's line buffer (4095 on Linux).</summary>
    public const int SafeLineLength = 3000;

    public static string Build(GeneratedScript g)
    {
        var lines = g.Content.Replace("\r\n", "\n").Split('\n');
        var eof = "SCRIPTIX_EOF_" + (g.Sha256.Length >= 8 ? g.Sha256[..8].ToUpperInvariant() : "END");
        while (lines.Any(l => l == eof)) eof += "_X";

        var f = g.FileName;
        var sb = new System.Text.StringBuilder();
        // bash expands "!" in pasted lines (even inside here-documents) when history expansion is on
        sb.Append("SX_H=; case $- in *H*) SX_H=1; set +H ;; esac\n");
        sb.Append($"(umask 077; cat > {f}) <<'{eof}'\n");   // subshell: the session keeps its own umask
        sb.Append(g.Content.Replace("\r\n", "\n"));
        if (!g.Content.EndsWith('\n')) sb.Append('\n');
        sb.Append(eof).Append('\n');
        sb.Append("[ -z \"$SX_H\" ] || set -H; unset SX_H\n");
        sb.Append($"chmod 700 {f}\n");
        sb.Append(g.Kind == "check"
            ? $"sh {f} --verify && echo 'Ready. Run: sh {f} -y'\n"
            : $"sh {f} --verify && sh {f} --dry-run && echo 'Preview done. To apply: sh {f}'\n");
        return sb.ToString();
    }

    /// <summary>Reasons the paste may arrive damaged; --verify would catch it, but say so up front.</summary>
    public static IReadOnlyList<string> Warnings(GeneratedScript g)
    {
        var w = new List<string>();
        if (g.Content.Contains('\t')) w.Add("it contains TAB characters, which some shells turn into completion when pasted");
        var longest = g.Content.Split('\n').Max(l => l.Length);
        if (longest > SafeLineLength) w.Add($"one line is {longest} characters long, which some terminals cut");
        return w;
    }
}

using System.Text;
using System.Text.RegularExpressions;

namespace ScriptIX;

public sealed record SshTarget(string Hosts, string User, int Port, string KeyFile, bool Sudo);

/// <summary>What to run on every server of one batch. The parts may have no quotes, % or line breaks.</summary>
/// <param name="Payload">a file next to the batch file that is copied to the server, or ""</param>
/// <param name="Prepare">must work, or nothing else runs; or ""</param>
/// <param name="Run">the work. {sudo} stands for "sudo " or nothing</param>
/// <param name="Results">what prints the results file, whatever Run's exit code was; or ""</param>
/// <param name="Cleanup">remove the folder on the server afterwards</param>
/// <param name="Questions">Run asks something, so it needs the keyboard</param>
public sealed record SshJob(string Payload, string Prepare, string Run, string Results, bool Cleanup, bool Questions = false);

/// <summary>
/// Builds a console batch file that works on servers with Windows' own ssh. ssh itself asks for the
/// password in that window: ScriptIX never sees it, and nothing is stored.
/// </summary>
public static class SshRun
{
    static readonly Regex HostOk = new(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$", RegexOptions.Compiled);
    static readonly Regex UserOk = new(@"^[A-Za-z_][A-Za-z0-9._-]{0,63}$", RegexOptions.Compiled);

    public static List<string> Hosts(string text) =>
        text.Split(new[] { ',', ';', ' ', '\n', '\r', '\t' }, StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    /// Throws FormatException with a message for the user when something can't be used safely on a command line.
    public static void Check(SshTarget t)
    {
        var hosts = Hosts(t.Hosts);
        if (hosts.Count == 0) throw new FormatException("Type the server name or IP address.");
        if (hosts.FirstOrDefault(h => !HostOk.IsMatch(h)) is { } bad) throw new FormatException($"\"{bad}\" isn't a server name or IPv4 address.");
        if (!UserOk.IsMatch(t.User)) throw new FormatException("Type the user name to log in with (letters, digits, . _ -).");
        if (t.Port is < 1 or > 65535) throw new FormatException("The port must be between 1 and 65535.");
        if (t.KeyFile.Length > 0 && (t.KeyFile.IndexOfAny(new[] { '"', '%', '!', '^', '&', '<', '>', '|', '\r', '\n' }) >= 0))
            throw new FormatException("The key file's path has characters that can't be used here. Copy the key to a simpler folder.");
    }

    // ---------- the jobs ----------

    /// <param name="check">check scripts run without questions; others show their own "Apply? [y/N]" question</param>
    public static SshJob Script(string script, bool check) =>
        new(script, $"sh {script} --verify 1>&2", $"{{sudo}}sh {script}{(check ? " -y" : "")} 1>&2", "cat scriptix_*/results_*.csv", false, !check);

    public const string BundleName = "scriptix_packages.tar";
    public static SshJob Install() => new(BundleName, $"tar -xf {BundleName}", "{sudo}sh ./install.sh 1>&2", "", true);

    public const int NotInstalled = 97;
    const string Installed = "(test -x /usr/bin/scriptix || exit 97)";
    public static SshJob ScanInstalled() => new("", Installed, "{sudo}/usr/bin/scriptix scan 1>&2; {sudo}/usr/bin/scriptix export --stamp > out.csv", "cat out.csv", true);
    public static SshJob Collect() => new("", Installed, "{sudo}/usr/bin/scriptix export --stamp > out.csv", "cat out.csv", true);

    /// <param name="time">HH:MM, or "" for off</param>
    public static SshJob Schedule(string time) => new("", Installed, $"{{sudo}}/usr/bin/scriptix schedule {(time.Length == 0 ? "off" : "daily " + time)} 1>&2", "", true);

    public const string RemoveName = "remove.sh";
    public static SshJob Remove() => new(RemoveName, "", $"{{sudo}}sh ./{RemoveName} 1>&2", "", true);
    public static string RemoveScript => """
        #!/bin/sh
        # removes the scriptix package; the results in /var/lib/scriptix stay
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        case "`uname -s`" in
          AIX) installp -u scriptix.rte ;;
          *) if [ -f /etc/debian_version ] && [ -x /usr/bin/dpkg ]; then dpkg -r scriptix; else rpm -e scriptix; fi ;;
        esac

        """.Replace("\r\n", "\n");

    /// <summary>The results file of server number k (1, 2, ...) and its exit code, as the batch file writes them.</summary>
    public static string CsvName(string host, string stamp) => $"results_{host}_{stamp}.csv";
    public static string StatusName(int k) => $"status_{k}.txt";
    public const string DoneName = "done.txt";

    // ---------- the batch file ----------

    public static string Batch(SshTarget t, string script, bool check, string stamp)
    {
        Check(t);
        return Batch(Hosts(t.Hosts).Select(h => t with { Hosts = h }).ToList(), Script(script, check), stamp,
                     "Finished. Go back to ScriptIX and press Open the results.");
    }

    /// <param name="servers">one host in each</param>
    public static string Batch(IReadOnlyList<SshTarget> servers, SshJob job, string stamp, string goodbye)
    {
        foreach (var s in servers) { Check(s); if (Hosts(s.Hosts).Count != 1) throw new FormatException("One server per row."); }
        if (!Regex.IsMatch(job.Payload, "^[A-Za-z0-9._-]*$") || !Regex.IsMatch(stamp, "^[A-Za-z0-9_]+$")) throw new FormatException("Bad script name.");
        if ((job.Prepare + job.Run + job.Results).IndexOfAny(new[] { '"', '\'', '%', '\r', '\n', '!', '^', '$', '`', '\\' }) >= 0) throw new FormatException("Bad command.");
        var ssh = "\"%SystemRoot%\\System32\\OpenSSH\\ssh.exe\"";
        var scp = "\"%SystemRoot%\\System32\\OpenSSH\\scp.exe\"";
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append("\r\n");
        L("@echo off");
        L("chcp 65001 >nul");
        L("cd /d \"%~dp0\"");
        L("title ScriptIX over SSH");
        L($"if not exist {ssh} (echo Windows OpenSSH is not installed: Settings, Optional features, OpenSSH Client.& pause & exit /b 1)");
        for (int k = 1; k <= servers.Count; k++)
        {
            var t = servers[k - 1];
            var h = Hosts(t.Hosts)[0];
            var key = (t.KeyFile.Length > 0 ? $" -i \"{t.KeyFile}\"" : "") + " -o ConnectTimeout=15 -o ServerAliveInterval=30";
            var dest = $"{t.User}@{h}";
            var dir = $"scriptix_{stamp}_{k}";   // its own folder: several servers may share one home
            var csv = CsvName(h, stamp);
            var run = job.Run.Replace("{sudo}", t.Sudo ? "sudo " : "");
            var prep = job.Prepare.Length > 0 ? " && " + job.Prepare : "";
            var clean = $"; r=$?; cd; rm -rf {dir}; exit $r";
            var p = job.Payload;
            var mk = $"umask 077; mkdir {dir} && cd {dir}";
            L("echo.");
            L($"echo ==== {h} ====" + (servers.Count > 1 ? $"  ({k} of {servers.Count})" : ""));
            L("echo ssh asks for the password or key phrase here. ScriptIX does not see or keep it.");
            L("set rc=255");
            if (!t.Sudo && !job.Questions)
            {
                // one login: the payload goes in on stdin, the log comes back on stderr, the results on stdout
                var all = mk + (p.Length > 0 ? $" && cat > {p}" : "") + prep + $" && {{ {run}{(job.Results.Length > 0 ? "; " + job.Results : "")}; }}" + (job.Cleanup ? clean : "");
                L($"{ssh} -p {t.Port}{key} {dest} \"sh -c '{all}'\"" + (p.Length > 0 ? $" < {p}" : " < nul") + (job.Results.Length > 0 ? $" > {csv}" : ""));
                L("set rc=%errorlevel%");
            }
            else
            {
                int n = 0, steps = (p.Length > 0 ? 1 : 0) + 1 + (job.Results.Length > 0 ? 1 : 0);
                if (p.Length > 0)
                {
                    L($"echo Step {++n} of {steps}: copy the file");
                    L($"{scp} -P {t.Port}{key} {p} {dest}:{dir}.tmp");
                    L($"if errorlevel 1 (echo Copy failed.& goto next_{k})");
                }
                if (steps > 1) L($"echo Step {++n} of {steps}: run it");
                var own = t.Sudo && job.Results.StartsWith("cat scriptix_", StringComparison.Ordinal) ? $"; sudo chown -R {t.User} scriptix_*" : "";
                var mv = p.Length > 0 ? $" && mv ../{dir}.tmp {p}" : "";
                L($"{ssh} -t -p {t.Port}{key} {dest} \"sh -c '{mk}{mv}{prep} && {{ {run.Replace(" 1>&2", "")}{own}; }}{(job.Cleanup && job.Results.Length == 0 ? clean : "")}'\"");
                L("set rc=%errorlevel%");
                L($"if %rc% equ 255 (echo The connection failed.& goto next_{k})");
                if (job.Results.Length > 0)
                {
                    L($"echo Step {++n} of {steps}: bring the results back");
                    L($"{ssh} -p {t.Port}{key} {dest} \"sh -c 'cd {dir} && {job.Results}{(job.Cleanup ? $"; cd; rm -rf {dir}" : "")}'\" < nul > {csv}");
                }
            }
            L(":next_" + k);
            if (job.Results.Length > 0)
            {
                L($"if exist {csv} for %%F in ({csv}) do if %%~zF equ 0 del {csv}");
                L($"if exist {csv} echo Results: %CD%\\{csv}");
                L($"if not exist {csv} echo No results from {h}.");
                if (!job.Cleanup) L($"if exist {csv} echo The full log stays on {h} in ~/{dir}");
            }
            else L($"if %rc% equ 0 (echo {h}: done.) else (echo {h}: failed, exit code %rc%.)");
            L($">{StatusName(k)}.tmp echo %rc%");
            L($"move /y {StatusName(k)}.tmp {StatusName(k)} >nul");
        }
        L("echo.");
        L($">{DoneName} echo done");
        L($"echo {goodbye}");
        L("pause");
        return sb.ToString();
    }
}

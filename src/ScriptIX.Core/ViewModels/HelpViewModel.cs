using ScriptIX.Mvvm;

namespace ScriptIX.ViewModels;

public sealed record HelpRow(string Code, string Text);

/// <param name="Wide">the code goes on its own line above the text</param>
public sealed record HelpTopic(string Title, IReadOnlyList<HelpRow> Rows, bool Wide = false);

/// <summary>The Help page: a list of topics, one shown at a time; the search looks through all of them.</summary>
public sealed class HelpViewModel : ObservableObject
{
    string search = "";
    HelpTopic topic;

    static HelpTopic T(string title, params (string Code, string Text)[] rows) => new(title, rows.Select(r => new HelpRow(r.Code, r.Text)).ToList());

    public IReadOnlyList<HelpTopic> Topics { get; } = new[]
    {
        T("Start here",
            ("1  Rules", "Open a CIS PDF, SCAP .xml or rule file and tick rules. Or type your own commands."),
            ("2  Script", "Create script to fix. Check only to scan; it changes nothing."),
            ("3  Servers", "Run it on one server or many. It asks before it changes anything."),
            ("4  Results", "See what failed, export a report, or fix only what failed."),
            ("Ctrl+O  Ctrl+R", "Open rules, open results."),
            ("Ctrl+S  F1", "Save the script, this page.")),
        T("Safety",
            ("First", "Run --dry-run, on a test server."),
            ("SSH and PAM", "Keep a second root session open while you change them."),
            ("Passwords", "Never saved. ssh asks in its own window. Secrets are hidden in logs."),
            ("One at a time", "Only one ScriptIX run per server.")),
        T("Servers",
            ("Add servers", "Saved once, with a group."),
            ("Run on ticked", "Runs the script on every ticked server and brings the results back."),
            ("Side by side", "The last results, rule by rule."),
            ("Package", "Installs the scriptix command with your scripts inside. Or save the files."),
            ("Daily scan", "Every server scans itself. Get last results brings them here.")),
        T("Packages",
            ("_all.deb", "Debian, Ubuntu:  dpkg -i FILE"),
            (".noarch.rpm", "RHEL, Rocky, Alma, Oracle, SUSE:  rpm -Uvh FILE"),
            (".aix6.1.noarch.rpm", "AIX with rpm:  rpm -Uvh FILE"),
            ("-aix.sh", "AIX without rpm:  sh FILE --install"),
            (".bff", "Run  sh FILE-aix.sh  on AIX. It makes the .bff for installp, smit or NIM."),
            ("On AIX", "Use the .rpm or the .bff, not both."),
            ("Inside", "A SCAP scanner, and your scripts (without a check script: the basic checks)."),
            ("SCAP file", "The one that is open can go in too. ScriptIX asks."),
            ("Two ways", "Scan from this app, or on the server with the package. Same checks, same results.")),
        T("Scan on the server",
            ("scriptix content", "The SCAP files on the server."),
            ("scriptix info FILE", "What is inside, with the profiles."),
            ("scriptix eval --profile P FILE", "Scan. No FILE: the one made for that system."),
            ("--report F.html", "Write a web page. Also: --results F.xml, --results-arf F.xml, --csv F."),
            ("--remediate", "Fix what failed, then scan again. It asks first. No undo, so take a backup."),
            ("--tailoring-file F", "Use a tailoring. Also: --set NAME=VALUE, --rule ID, --skip-rule ID."),
            ("scriptix report NAME", "A web page of the last run."),
            ("scriptix guide / fix / tailor", "Security guide, fixes (bash, ansible...), your own profile."),
            ("scriptix add FILE.xml --profile P", "Keep it as a check script, for scan, schedule and ssh."),
            ("scriptix ssh -c FILE --profile P HOST", "Scan another server with it. --out DIR: a report of each."),
            ("scriptix xccdf eval ...", "The same, under the names oscap uses."),
            ("Needs", "sh and awk. Reading a SCAP file also needs perl; AIX and most Linux have it.")),
        T("scriptix command",
            ("scriptix scan", "Run the check scripts."),
            ("scriptix status", "Last result of every script."),
            ("scriptix results", "What failed."),
            ("scriptix diff", "What changed since the scan before."),
            ("scriptix ssh USER@HOST", "Run the check scripts on another server. Nothing is installed there."),
            ("scriptix ssh -f FILE", "Many servers, one per line. Also: -i KEY, -p PORT, --sudo, --apply NAME."),
            ("scriptix servers", "Last result of every server. results, diff and export take --host HOST."),
            ("scriptix preview NAME", "What a script would change."),
            ("scriptix apply NAME", "Run it. It asks first."),
            ("scriptix undo", "Put it back."),
            ("scriptix schedule daily 02:30", "Scan every day. Also: weekly DAY HH:MM, off."),
            ("scriptix add FILE.sh", "Add a script. Also: list, remove, verify, export.")),
        T("Script options",
            ("--selftest", "Check the server has every tool needed. Run it first on a new system."),
            ("--verify", "Check the script was not changed."),
            ("--dry-run", "Show what would change."),
            ("-y", "Don't ask."),
            ("--only ID,ID", "Run only these."),
            ("--skip ID,ID", "Leave these out."),
            ("--stop-on-fail", "Stop at the first failure."),
            ("--timeout SEC", "Time limit per command. 0 = none."),
            ("--list", "List the commands."),
            ("--undo MANIFEST", "Put back what the helpers changed.")),
        T("Your own commands",
            ("(no marker)", "Passes when the exit code is 0."),
            ("## expect: text", "The output contains the text."),
            ("## expect-exact: text", "The output is exactly the text."),
            ("## expect-regex: re", "The output matches."),
            ("## expect-not: text", "The output does not contain the text."),
            ("## expect-rc: 1", "The exit code must be this."),
            ("## timeout: 120", "Time limit in seconds."),
            ("## os: aix", "Only there. linux, aix, unix, solaris, hpux, bsd."),
            ("## id: SSH-01", "Your own ID."),
            ("## shell: bash", "Run with bash."),
            ("\\ at the line end", "Goes on in the next line.")),
        T("Works on AIX too",
            ("printf '%s\\n' x", "not  echo -e, echo -n"),
            ("[ \"$a\" = \"$b\" ]", "not  [[ ]], local, arrays"),
            ("grep -E", "not  grep -P, grep -o"),
            ("setcfg, line_del", "not  sed -i"),
            ("## timeout: N", "not  timeout")),
        new HelpTopic("Helpers", Helpers.Reference.Select(h => new HelpRow(h.Usage, h.What)).ToList(), true),
        T("SCAP",
            ("Open", "SCAP data streams, XCCDF, OVAL and CVE files. The server needs no oscap."),
            ("Check only", "Scans every rule of the profile."),
            ("SCAP menu", "Values, tailoring, guide, fixes, content check, CVSS."),
            ("Tailoring", "Tick IN PROFILE, change values, Save tailoring."),
            ("MANUAL", "Check it yourself, then set Your answer on the Results page."),
            ("NOT-CHECKED", "Can't be tested here. Never counted as a pass."),
            ("Results", "oscap results open too. Compare shows what changed.")),
        T("Files and exit codes",
            ("results_*.csv", "Open this on the Results page."),
            ("run_*.txt", "The full log."),
            ("history_*.txt", "One line per command."),
            ("changes_*.manifest", "For --undo."),
            ("backup/", "Every changed file, as it was."),
            ("exit code 0", "Everything passed."),
            ("exit code 1", "Something failed."),
            ("exit code 2", "Wrong option."),
            ("exit code 3", "Could not start: not root, or another run."),
            ("exit code 4", "Interrupted.")),
        T("Supported systems",
            ("AIX", "7.1, 7.2, 7.3"),
            ("Linux", "RHEL, Rocky, Alma, Oracle 6+, Debian, Ubuntu, SUSE, Alpine"),
            ("Solaris", "10, 11"),
            ("Others", "HP-UX, FreeBSD, OpenBSD"),
            ("Not sure?", "Run  sh SCRIPT --selftest  there.")),
    };

    public HelpViewModel() => topic = Topics[0];

    /// <summary>The topic chosen in the list; none while searching.</summary>
    public HelpTopic? Topic
    {
        get => search.Trim().Length > 0 ? null : topic;
        set
        {
            if (value == null || value == Topic) return;
            topic = value;
            search = "";
            foreach (var n in new[] { nameof(Search), nameof(Topic), nameof(Shown) }) OnPropertyChanged(n);
        }
    }

    public string Search
    {
        get => search;
        set { if (Set(ref search, value ?? "")) { OnPropertyChanged(nameof(Topic)); OnPropertyChanged(nameof(Shown)); } }
    }

    /// <summary>The chosen topic, or what the search found.</summary>
    public IReadOnlyList<HelpTopic> Shown
    {
        get
        {
            var q = search.Trim();
            if (q.Length == 0) return new[] { topic };
            bool Has(string s) => s.Contains(q, StringComparison.OrdinalIgnoreCase);
            var found = Topics.Select(t => Has(t.Title) ? t : t with { Rows = t.Rows.Where(r => Has(r.Code) || Has(r.Text)).ToList() })
                              .Where(t => t.Rows.Count > 0).ToList();
            return found.Count > 0 ? found : new[] { new HelpTopic("Nothing found", Array.Empty<HelpRow>()) };
        }
    }
}

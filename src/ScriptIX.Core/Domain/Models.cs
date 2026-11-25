using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using ScriptIX.Mvvm;

namespace ScriptIX;

public static class AppInfo
{
    public const string Name = "ScriptIX";
    public const string Version = "2.6.1";
    public const string Tagline = "Hardening scripts for Linux & AIX";
}

public enum CompareMode { Equals, Contains, NotContains, Regex, ExitCode, AtLeast, AtMost, Oval, Sce }
/// <summary>Where a rule runs. Any = every OS; Unix = every OS except Linux.</summary>
public enum OsTarget { Any, Linux, AIX, Solaris, HPUX, BSD, Unix }
public enum Severity { Low, Medium, High }
public enum RuleStatus { Ready, NeedsReview, Risky }

/// <summary>One command the generated script will run. Every text field is opaque: it only gets quoted.</summary>
/// <param name="Mode">rc0, rc, equals, contains, notcontains, regex, atleast, atmost, oval, sce, manual</param>
/// <param name="Target">any, Linux, AIX, SunOS, HP-UX, BSD or Unix (compared with uname -s)</param>
/// <param name="Timeout">seconds, 0 = script default</param>
/// <param name="Shell">sh or bash</param>
/// <param name="Data">the compiled OVAL check, for mode oval</param>
public sealed record ScriptItem(string Id, string Title, string Severity, string Target, string Mode,
                                string Expected, string Command, int Timeout = 0, string Shell = "sh", string Data = "");

public sealed record ScriptOptions(string Kind, bool StopOnFail = false, bool RequireRoot = true,
                                   int TimeoutSeconds = 60, bool Redact = true, bool ReadOnly = false);

/// <summary>What to generate: the app keeps these so the script can be rebuilt when options change.</summary>
public sealed record ScriptJob(string FileName, string Kind, IReadOnlyList<ScriptItem> Items,
                               bool RequireRoot = true, bool ReadOnly = false, string Purpose = "");

public sealed class GeneratedScript : ObservableObject
{
    bool saved;
    public string FileName { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Purpose { get; init; } = "";
    public string Content { get; init; } = "";
    public string Sha256 { get; init; } = "";
    public int Count { get; init; }
    public int RiskyCount { get; init; }
    public int LineCount { get; init; }
    public bool Saved { get => saved; set => Set(ref saved, value); }
    public string CountText => $"{Count} command{(Count == 1 ? "" : "s")}" + (RiskyCount > 0 ? $" · {RiskyCount} risky" : "");
    public override string ToString() => FileName;
}

public sealed class ResultRow
{
    public int Seq { get; set; }
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string Severity { get; set; } = "";
    public string Time { get; set; } = "";
    public string Result { get; set; } = "";   // PASS / FAIL / SKIPPED
    public string Detail { get; set; } = "";   // TIMEOUT, DRY-RUN, OTHER-OS, ...
    public string Rc { get; set; } = "";
    public string Seconds { get; set; } = "";
    public string Command { get; set; } = "";
    public string Expected { get; set; } = "";
    public string Output { get; set; } = "";
    public string Mode { get; set; } = "";     // schema 3: rc0, equals, contains, ...
    public string Os { get; set; } = "";
    public string Shell { get; set; } = "";
    public int Timeout { get; set; }

    // a result changed by hand keeps what the script said
    string? oldResult, oldDetail;
    public string Reason { get; set; } = "";
    public bool Waived => oldResult != null;
    public string OverrideText { get; private set; } = "";
    public ResultRow Original() => oldResult == null ? this
        : new ResultRow { Id = Id, Result = oldResult, Detail = oldDetail ?? "" };
    /// <param name="to">PASS, FAIL, NOT-APPLICABLE, WAIVED, or "" to go back to the script's result</param>
    public void Override(string to)
    {
        if (to.Length == 0)
        {
            if (oldResult != null) { Result = oldResult; Detail = oldDetail ?? ""; oldResult = oldDetail = null; }
            OverrideText = "";
            return;
        }
        if (oldResult == null) { oldResult = Result; oldDetail = Detail; }
        OverrideText = to;
        (Result, Detail) = to switch { "PASS" => ("PASS", "BY-HAND"), "FAIL" => ("FAIL", "BY-HAND"), "WAIVED" => ("SKIPPED", "WAIVED"), _ => ("SKIPPED", "NOT-APPLICABLE") };
    }

    // set when two runs are compared
    public string Before { get; set; } = "";
    public bool Changed { get; set; }

    /// <summary>For reports: what was changed by hand and why, and the older result.</summary>
    public string Note => string.Join(". ", new[]
    {
        Waived ? $"Changed by hand (the script said {(oldDetail is { Length: > 0 } ? oldDetail : oldResult)})" : "",
        Reason, Before.Length > 0 && Changed ? $"Before: {Before}" : ""
    }.Where(x => x.Length > 0));

    public string DetailNote => Note.Length == 0 ? Detail : Detail.Length == 0 ? Note : $"{Detail}. {Note}";
    public string RunText => (Rc.Length > 0 ? $"   exit code {Rc}" : "") + (Seconds.Length > 0 ? $"   {Seconds} s" : "");
    public string ResultText => string.IsNullOrEmpty(Detail) ? Result : $"{Result} · {Detail}";
}

public sealed record ResultSummary(int Total, int Passed, int Failed, int Skipped)
{
    public int PassRate => Passed + Failed == 0 ? 0 : (int)(100.0 * Passed / (Passed + Failed));
}

public sealed class RuleItem : ObservableObject
{
    // <user>, <SET var_name>, xccdf_value... : the fix still needs a real value.
    static readonly Regex Placeholder = new(@"<[A-Za-z_][A-Za-z0-9_.:-]*( [A-Za-z0-9_.:-]+)*>|xccdf_value", RegexOptions.Compiled);

    bool selected, inProfile = true;
    string id = "", title = "", command = "", expected = "", remediation = "", undo = "", shell = "sh", notes = "";
    OsTarget target = OsTarget.Any;
    Severity severity = Severity.Medium;
    CompareMode mode = CompareMode.Equals;
    RuleStatus status = RuleStatus.NeedsReview;
    string riskText = "", reversibleText = "";

    public bool Selected { get => selected; set => Set(ref selected, value); }
    public string Id { get => id; set { if (Set(ref id, value ?? "")) Refresh(); } }
    public string Title { get => title; set { if (Set(ref title, value ?? "")) Refresh(); } }
    public OsTarget Target { get => target; set => Set(ref target, value); }
    public Severity Severity { get => severity; set => Set(ref severity, value); }
    public string Command { get => command; set => Set(ref command, value ?? ""); }
    public CompareMode Mode { get => mode; set => Set(ref mode, value); }
    public string Expected { get => expected; set => Set(ref expected, value ?? ""); }
    public string Remediation { get => remediation; set { if (Set(ref remediation, value ?? "")) Refresh(); } }
    public string Undo { get => undo; set { if (Set(ref undo, value ?? "")) Refresh(); } }
    public string Shell { get => shell; set => Set(ref shell, value == "bash" ? "bash" : "sh"); }
    public string Notes { get => notes; set => Set(ref notes, value ?? ""); }
    /// <summary>When set, the rule always needs review (e.g. CIS marks it "Manual"), whatever its fix looks like.</summary>
    public string ReviewReason { get => reviewReason; set { if (Set(ref reviewReason, value ?? "")) Refresh(); } }
    string reviewReason = "";

    /// <summary>The benchmark's own rule id (the ID column shows the short one).</summary>
    public string FullId { get; set; } = "";
    /// <summary>The compiled OVAL check the engine runs (see OvalCompiler).</summary>
    public string Oval { get; set; } = "";
    /// <summary>OVAL tests of this check that can't run here: they end as NOT-CHECKED.</summary>
    public string CheckGap { get; set; } = "";
    /// <summary>The question to answer by hand, when there is no automatic check.</summary>
    public string ManualCheck { get; set; } = "";
    string checkShell = "sh";
    public string CheckShell { get => checkShell; set => Set(ref checkShell, value == "bash" ? "bash" : "sh"); }

    /// <summary>A detached copy (used when a profile rebuilds the list).</summary>
    public RuleItem Clone() => new()
    {
        Id = id, Title = title, Target = target, Severity = severity, Command = command, Mode = mode, Expected = expected,
        Remediation = remediation, Undo = undo, Shell = shell, Notes = notes, ReviewReason = reviewReason,
        FullId = FullId, Oval = Oval, CheckGap = CheckGap, ManualCheck = ManualCheck, CheckShell = checkShell
    };

    [JsonIgnore] public bool InProfile { get => inProfile; set => Set(ref inProfile, value); }
    [JsonIgnore] public RuleStatus Status { get => status; private set { if (Set(ref status, value)) OnPropertyChanged(nameof(StatusText)); } }
    [JsonIgnore] public string StatusText => status switch
    {
        RuleStatus.Ready => "Ready",
        RuleStatus.NeedsReview => "Needs review",
        _ => "Risky"
    };
    [JsonIgnore] public string RiskText { get => riskText; private set => Set(ref riskText, value); }
    [JsonIgnore] public string ReversibleText { get => reversibleText; private set => Set(ref reversibleText, value); }
    [JsonIgnore] public bool HasCheck => !string.IsNullOrWhiteSpace(command);

    public void AutoSelect() => Selected = Status == RuleStatus.Ready;

    void Refresh()
    {
        if (reviewReason.Length > 0 && !string.IsNullOrWhiteSpace(remediation))
        {
            Status = RuleStatus.NeedsReview;
            RiskText = reviewReason;
        }
        else if (string.IsNullOrWhiteSpace(remediation))
        {
            Status = RuleStatus.NeedsReview;
            RiskText = "No fix command yet. Add one to use this rule.";
        }
        else if (Placeholder.IsMatch(remediation))
        {
            Status = RuleStatus.NeedsReview;
            RiskText = "The fix contains a placeholder (like <user>) that needs a real value.";
        }
        else
        {
            var reasons = Risk.Reasons(title + " " + remediation).ToList();
            Status = reasons.Count > 0 ? RuleStatus.Risky : RuleStatus.Ready;
            RiskText = reasons.Count > 0 ? "Risky: " + string.Join(", ", reasons) + "." : "No risky patterns found.";
        }

        ReversibleText = !string.IsNullOrWhiteSpace(undo) ? "Yes: this rule has its own undo command."
            : Helpers.IsHelperOnly(remediation) ? "Yes: ScriptIX backs up first and --undo restores it."
            : string.IsNullOrWhiteSpace(remediation) ? ""
            : Risk.IsIrreversible(remediation) ? "No: this change can't be undone automatically."
            : "No automatic undo. Add an undo command, or use a ScriptIX helper.";
    }
}

public sealed record HelperDoc(string Usage, string What);

/// <summary>The shell helper functions every generated script contains.</summary>
public static class Helpers
{
    public static readonly string[] Names =
        { "setcfg", "sysctl_set", "fperm", "fowner", "line_add", "line_del", "svc_disable", "aix_chsec", "aix_chuser", "aix_no" };

    // A plain helper call with literal arguments: safe to run in --dry-run (it only previews).
    static readonly Regex HelperOnly = new(
        @"^\s*(setcfg|sysctl_set|fperm|fowner|line_add|line_del|svc_disable|aix_chsec|aix_chuser|aix_no)\s[^;&|<>`$\n\r\\]*$",
        RegexOptions.Compiled);

    public static bool IsHelperOnly(string? command) => !string.IsNullOrWhiteSpace(command) && HelperOnly.IsMatch(command);

    public static readonly HelperDoc[] Reference =
    {
        new("setcfg FILE KEY VALUE [SEP]", "Set \"KEY VALUE\" in a config file (sshd_config, login.defs...). Skips sshd Match blocks; tests sshd_config with sshd -t before saving."),
        new("sysctl_set KEY VALUE", "Linux and BSD: apply a kernel parameter now and persist it (/etc/sysctl.d/99-scriptix.conf, or /etc/sysctl.conf on BSD)."),
        new("fperm MODE FILE", "Set an octal file mode, e.g. fperm 0600 /etc/crontab."),
        new("fowner OWNER[:GROUP] FILE", "Set the owner of a file."),
        new("line_add FILE LINE", "Add an exact line if it is missing."),
        new("line_del FILE REGEX", "Remove the lines that match an extended regex."),
        new("svc_disable NAME", "Stop and disable a service: systemd/SysV on Linux, SRC + rc.tcpip on AIX, SMF on Solaris, rc.conf on FreeBSD, rcctl on OpenBSD."),
        new("aix_chsec FILE STANZA ATTR VALUE", "AIX: set a stanza attribute, e.g. aix_chsec /etc/security/user default minlen 8."),
        new("aix_chuser ATTR=VALUE USER", "AIX: set a user attribute, e.g. aix_chuser rlogin=false root."),
        new("aix_no OPTION VALUE", "AIX: set a network tunable now and after reboot (no -p), e.g. aix_no ipsrcrouteforward 0."),
    };
}

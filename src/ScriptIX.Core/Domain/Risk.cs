using System.Text.RegularExpressions;

namespace ScriptIX;

/// <summary>Spots commands that can lock you out, break a server, or can't be undone.</summary>
public static class Risk
{
    const RegexOptions O = RegexOptions.Compiled;
    const RegexOptions OI = RegexOptions.Compiled | RegexOptions.IgnoreCase;

    static readonly (Regex Pattern, string Label)[] Patterns =
    {
        (new(@"\brm\s+-[a-zA-Z]*[rR]", O), "removes files recursively"),
        (new(@"\bmkfs|\bdd\s+if=|\bwipefs\b|\bfdisk\b|\bparted\b", O), "can overwrite disks"),
        (new(@"\bshutdown\b|\breboot\b|\bhalt\b|\binit\s+[06]\b|\bpoweroff\b", O), "shuts down or reboots"),
        (new(@"\buserdel\b|\busermod\b|\bpasswd\b|\bchpasswd\b|\brmuser\b|\bpwdadm\b", O), "changes user accounts or passwords"),
        (new(@"\biptables\b|\bip6tables\b|\bnft\b|firewall-cmd|\bufw\b|\bgenfilt\b|\bmkfilt\b", O), "changes the firewall"),
        (new(@"sshd_config|PermitRootLogin|\bAllowUsers\b|\bAllowGroups\b", OI), "changes SSH login settings"),
        (new(@"pam\.d|\bpam_|faillock|/etc/security/login\.cfg", OI), "changes PAM / login rules"),
        (new(@"fstab|\bmount\b|remount|/etc/filesystems", O), "changes mounts"),
        (new(@"grub|bootlist|\bbosboot\b", OI), "changes the boot loader"),
        (new(@"\b(chmod|chown|chgrp)\s+-R\s+/", O), "changes permissions on a whole tree"),
        (new(@"\b(yum|dnf|zypper)\s+(-y\s+)?(remove|erase)|\bapt(-get)?\s+(-y\s+)?(remove|purge)|\brpm\s+-e|\binstallp\s+-u", O), "removes packages"),
        (new(@"systemctl\s+(disable|mask|stop)|\bstopsrc\b|chsubserver\s+-d|\bsvc_disable\b|\bchrctcp\b", O), "stops or disables a service"),
        (new(@"\bcurl\b|\bwget\b|\bftp\b|\bscp\b|\btftp\b", O), "downloads or sends data over the network"),
        (new(@"\bchmod\s+(-[a-zA-Z]+\s+)*0?777\b", O), "makes files writable by everyone"),
        (new(@"\bselinux\b|\bsetenforce\b", OI), "changes SELinux"),
    };

    static readonly Regex Irreversible = new(
        @"\b(yum|dnf|zypper)\s+(-y\s+)?(remove|erase)|\bapt(-get)?\s+(-y\s+)?(remove|purge)|\brpm\s+-e|\binstallp\s+-u|" +
        @"\buserdel\b|\brmuser\b|\bmkfs|\bdd\s+if=|\brm\s+-|\bsysctl\s+-w\b|\bsystemctl\s+(stop|mask)|\bstopsrc\b|\bchpasswd\b|\bpasswd\b",
        O);

    public static bool IsRisky(string text) => Patterns.Any(p => p.Pattern.IsMatch(text));

    public static IEnumerable<string> Reasons(string text) =>
        Patterns.Where(p => p.Pattern.IsMatch(text)).Select(p => p.Label);

    public static bool IsIrreversible(string text) => Irreversible.IsMatch(text);

    public static List<string> WarningsFor(IEnumerable<ScriptItem> items, int max = 50)
    {
        var list = new List<string>();
        foreach (var i in items)
        {
            var reasons = Reasons(i.Command).ToList();
            if (reasons.Count > 0) list.Add($"{i.Id}: {string.Join(", ", reasons)}");
            if (list.Count >= max) break;
        }
        return list;
    }
}

/// <summary>Original example rules (not taken from any benchmark document).</summary>
public static class Samples
{
    static RuleItem R(string id, string title, OsTarget os, Severity sev, string check,
                      CompareMode mode, string expected, string fix, string notes)
    {
        var r = new RuleItem
        {
            Id = id, Title = title, Target = os, Severity = sev, Command = check,
            Mode = mode, Expected = expected, Remediation = fix, Notes = notes
        };
        r.AutoSelect();
        return r;
    }

    public static List<RuleItem> Load() => new()
    {
        R("EX-SSH-01", "SSH: root can't log in directly", OsTarget.Any, Severity.High,
          "grep -i '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config", CompareMode.Regex,
          "[Pp]ermit[Rr]oot[Ll]ogin[[:space:]]+no", "setcfg /etc/ssh/sshd_config PermitRootLogin no",
          "Admins log in with their own account and use sudo/su. Reload sshd after the change."),
        R("EX-SSH-02", "SSH: at most 4 login attempts per connection", OsTarget.Any, Severity.Medium,
          "grep -i '^[[:space:]]*MaxAuthTries' /etc/ssh/sshd_config", CompareMode.Regex,
          "[Mm]ax[Aa]uth[Tt]ries[[:space:]]+[1-4]$", "setcfg /etc/ssh/sshd_config MaxAuthTries 4",
          "Slows down password guessing."),
        R("EX-LNX-01", "/etc/shadow is not readable by others", OsTarget.Linux, Severity.High,
          "ls -ld /etc/shadow | cut -c8-10", CompareMode.Equals, "---", "chmod o-rwx /etc/shadow",
          "The shadow file holds password hashes."),
        R("EX-LNX-02", "Passwords expire after at most 90 days", OsTarget.Linux, Severity.Medium,
          "awk '$1 == \"PASS_MAX_DAYS\" { print $2 }' /etc/login.defs", CompareMode.AtMost, "90",
          "setcfg /etc/login.defs PASS_MAX_DAYS 90", "Applies to new accounts. Existing accounts need chage."),
        R("EX-LNX-03", "Address space randomisation fully on", OsTarget.Linux, Severity.Medium,
          "sysctl -n kernel.randomize_va_space", CompareMode.Equals, "2", "sysctl_set kernel.randomize_va_space 2",
          "Makes memory corruption exploits harder."),
        R("EX-LNX-04", "Ignore ICMP redirects", OsTarget.Linux, Severity.Medium,
          "sysctl -n net.ipv4.conf.all.accept_redirects", CompareMode.Equals, "0",
          "sysctl_set net.ipv4.conf.all.accept_redirects 0", "Stops other hosts from changing this host's routes."),
        R("EX-LNX-05", "Core dumps disabled for all users", OsTarget.Linux, Severity.Low,
          "cat /etc/security/limits.conf /etc/security/limits.d/*.conf 2>/dev/null | grep -E '^[*][[:space:]]+hard[[:space:]]+core[[:space:]]+0'",
          CompareMode.ExitCode, "0", "line_add /etc/security/limits.d/99-scriptix.conf '* hard core 0'",
          "Core dumps can contain passwords and keys."),
        R("EX-LNX-06", "Cron table only writable by root", OsTarget.Linux, Severity.Medium,
          "ls -ld /etc/crontab | cut -c1-10", CompareMode.Regex, "^-rw-------$", "fperm 0600 /etc/crontab",
          "Ordinary users should not read or edit system cron jobs."),
        R("EX-AIX-01", "AIX: root can't log in remotely", OsTarget.AIX, Severity.High,
          "lsuser -a rlogin root", CompareMode.Equals, "root rlogin=false", "aix_chuser rlogin=false root",
          "Admins log in with their own account, then su."),
        R("EX-AIX-02", "AIX: passwords have at least 8 characters", OsTarget.AIX, Severity.Medium,
          "lssec -f /etc/security/user -s default -a minlen", CompareMode.Regex, "minlen=([89]|[1-9][0-9])$",
          "aix_chsec /etc/security/user default minlen 8", "Default stanza: applies to users without their own value."),
        R("EX-AIX-03", "AIX: lock accounts after 5 failed logins", OsTarget.AIX, Severity.Medium,
          "lssec -f /etc/security/user -s default -a loginretries", CompareMode.Regex, "loginretries=[1-5]$",
          "aix_chsec /etc/security/user default loginretries 5", "Make sure you have a second admin account first."),
    };

    public const string ManualExample = """
# Kernel address space randomisation is on
sysctl -n kernel.randomize_va_space ## expect: 2 ## os: linux
# Nothing listens on the telnet port
netstat -an | grep -c '[.:]23 .*LISTEN' ## expect-exact: 0
# SSH root login is off
grep -i '^PermitRootLogin' /etc/ssh/sshd_config ## expect-regex: [Nn][Oo]$
# AIX: root can't log in remotely
lsuser -a rlogin root ## expect: rlogin=false ## os: aix
# Lines without a marker pass when the exit code is 0
id -un
""";
}

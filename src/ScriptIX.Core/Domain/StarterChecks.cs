namespace ScriptIX;

/// <summary>
/// A small set of our own checks (not taken from any benchmark), put into packages that have no check script.
/// They only read. Exit codes: 0 pass, 1 fail, 105 does not apply here, 107 can't be told here.
/// </summary>
public static class StarterChecks
{
    public const string FileName = "scriptix_basic.sh";

    public static GeneratedScript Script() =>
        ScriptBuilder.Build(new ScriptJob(FileName, "check", Items(), RequireRoot: false, ReadOnly: true, Purpose: "Basic checks; changes nothing"),
                            new ScriptOptions("check", RequireRoot: false, ReadOnly: true));

    static ScriptItem I(string id, string title, string severity, string os, string command) =>
        new(id, title, severity, os, "sce", "", command.Replace("\r\n", "\n"));

    const string Root = "[ \"$(id -u)\" = 0 ] || { echo 'needs root'; exit 107; }\n";

    /// <param name="columns">for cut: which letters of "-rwxrwxrwx" must be dashes</param>
    static string Mode(string path, string columns) =>
        $"[ -f {path} ] || exit 105\nl=$(ls -ldL {path}) || exit 107\nprintf '%s\\n' \"$l\"\n" +
        $"case \"$(printf '%s\\n' \"$l\" | cut -c{columns})\" in *[!-]*) exit 1 ;; esac\nexit 0";

    // sshd says itself what it uses; when it can't (not root, no host keys), the file is read
    static string Sshd(string key, string bad, string unset) => $$"""
        f=/etc/ssh/sshd_config
        [ -f $f ] || exit 105
        v=$(sshd -T 2>/dev/null | awk 'tolower($1) == "{{key}}" { print tolower($2); exit }')
        if [ -z "$v" ]; then
          [ -r $f ] || { echo "cannot read $f"; exit 107; }
          grep -i '^[[:space:]]*include[[:space:]]' $f && exit 107
          v=$(awk 'tolower($1) == "match" { exit } tolower($1) == "{{key}}" { print tolower($2); exit }' $f)
        fi
        echo "{{key}} ${v:-(not set)}"
        case "$v" in {{bad}}) exit 1 ;; '') exit {{unset}} ;; esac
        exit 0
        """;

    // the local address is the 4th column of netstat -an (Linux, AIX) and of ss -ltn
    static string Port(string ports) => $$"""
        l=$(netstat -an 2>/dev/null)
        [ -n "$l" ] || l=$(ss -ltn 2>/dev/null)
        [ -n "$l" ] || { echo 'no netstat and no ss'; exit 107; }
        printf '%s\n' "$l" | awk '/LISTEN/ && $4 ~ /[.:]({{ports}})$/ { print; n = 1 } END { exit n + 0 }'
        """;

    static string Sysctl(string key, string good)
    {
        var f = "/proc/sys/" + key.Replace('.', '/');
        return $"[ -r {f} ] || exit 105\nv=$(cat {f})\necho \"{key} = $v\"\ncase \"$v\" in {good}) exit 0 ;; esac\nexit 1";
    }

    static string Running(string pattern) =>
        $"l=$(ps -ef 2>/dev/null) || l=$(ps 2>/dev/null)\n[ -n \"$l\" ] || exit 107\nprintf '%s\\n' \"$l\" | grep -E '{pattern}'";

    // AIX: one attribute out of lssec
    static string Lssec(string file, string stanza, string attribute, string test) =>
        Root + $"l=$(lssec -f {file} -s {stanza} -a {attribute}) || exit 107\necho \"$l\"\nv=${{l##*=}}\n{test}";

    public static List<ScriptItem> Items() => new()
    {
        I("BASIC-ACC-01", "Only root has user ID 0", "high", "any",
            "awk -F: '$3 == \"0\" && $1 != \"root\" { print $1; n = 1 } END { exit n + 0 }' /etc/passwd"),
        I("BASIC-ACC-02", "No account has an empty password", "high", "Linux",
            "[ -f /etc/shadow ] || exit 105\n[ -r /etc/shadow ] || { echo 'needs root'; exit 107; }\n" +
            "awk -F: 'NF > 1 && $2 == \"\" { print $1; n = 1 } END { exit n + 0 }' /etc/shadow"),
        I("BASIC-ACC-03", "No account has an empty password", "high", "AIX",
            Root + "a=$(awk -F: 'NF > 1 && $2 == \"\" { print $1 }' /etc/passwd)\n" +
            "b=$(awk '/^[^ \\t*].*:/ { u = $1 } $1 == \"password\" && $2 == \"=\" && $3 == \"\" { print u }' /etc/security/passwd)\n" +
            "[ -z \"$a$b\" ] && exit 0\nprintf '%s\\n' \"$a\" \"$b\"\nexit 1"),
        I("BASIC-ACC-04", "No hosts are trusted without a password (hosts.equiv, .rhosts)", "high", "any",
            "n=0\nfor f in /etc/hosts.equiv /.rhosts /root/.rhosts; do\n  [ -f $f ] || continue\n" +
            "  grep -v '^[[:space:]]*#' $f | grep . && { echo \"in $f\"; n=1; }\ndone\nexit $n"),

        I("BASIC-FIL-01", "Only root can write /etc/passwd", "high", "any", Mode("/etc/passwd", "6,9")),
        I("BASIC-FIL-02", "Only root can write /etc/group", "high", "any", Mode("/etc/group", "6,9")),
        I("BASIC-FIL-03", "Others have no access to /etc/shadow", "high", "Linux", Mode("/etc/shadow", "6,8-10")),
        I("BASIC-FIL-04", "Others have no access to /etc/security/passwd", "high", "AIX", Root + Mode("/etc/security/passwd", "5-10")),
        I("BASIC-FIL-05", "Only root can write /etc/ssh/sshd_config", "high", "any", Mode("/etc/ssh/sshd_config", "6,9")),
        I("BASIC-FIL-06", "Only root can write /etc/crontab", "medium", "any", Mode("/etc/crontab", "6,9")),
        I("BASIC-FIL-07", "Others have no access to /etc/sudoers", "high", "any", Mode("/etc/sudoers", "6,8-10")),
        I("BASIC-FIL-08", "No file in /etc can be written by everyone", "high", "any",
            "l=$(find /etc -xdev -type f -perm -0002 -print 2>/dev/null | head -n 20)\n[ -z \"$l\" ] && exit 0\nprintf '%s\\n' \"$l\"\nexit 1"),
        I("BASIC-FIL-09", "/tmp has the sticky bit", "medium", "any",
            "l=$(ls -ldL /tmp) || exit 107\nprintf '%s\\n' \"$l\"\ncase \"$(printf '%s\\n' \"$l\" | cut -c10)\" in t|T) exit 0 ;; esac\nexit 1"),
        I("BASIC-FIL-10", "Only root can write in root's home folder", "high", "any",
            "h=$(awk -F: '$1 == \"root\" { print $6; exit }' /etc/passwd)\n[ -d \"$h\" ] || exit 105\nl=$(ls -ldL \"$h\") || exit 107\nprintf '%s\\n' \"$l\"\n" +
            "case \"$(printf '%s\\n' \"$l\" | cut -c6,9)\" in *[!-]*) exit 1 ;; esac\nexit 0"),

        I("BASIC-SSH-01", "sshd: root can't log in with a password", "high", "any", Sshd("permitrootlogin", "yes", "107")),
        I("BASIC-SSH-02", "sshd: no empty passwords", "high", "any", Sshd("permitemptypasswords", "yes", "0")),
        I("BASIC-SSH-03", "sshd: no host-based login", "medium", "any", Sshd("hostbasedauthentication", "yes", "0")),

        I("BASIC-NET-01", "Nothing listens on the telnet port", "high", "Linux", Port("23")),
        I("BASIC-NET-02", "Nothing listens on the FTP port", "medium", "Linux", Port("21")),
        I("BASIC-NET-03", "Nothing listens on the rexec and rlogin ports", "high", "Linux", Port("512|513")),
        I("BASIC-NET-04", "Nothing listens on the telnet port", "high", "AIX", Port("23")),
        I("BASIC-NET-05", "Nothing listens on the FTP port", "medium", "AIX", Port("21")),
        I("BASIC-NET-06", "Nothing listens on the rexec and rlogin ports", "high", "AIX", Port("512|513")),

        I("BASIC-KRN-01", "Memory addresses are randomised", "medium", "Linux", Sysctl("kernel.randomize_va_space", "2")),
        I("BASIC-KRN-02", "SYN cookies are on", "medium", "Linux", Sysctl("net.ipv4.tcp_syncookies", "1|2")),
        I("BASIC-KRN-03", "ICMP redirects are ignored", "medium", "Linux", Sysctl("net.ipv4.conf.all.accept_redirects", "0")),
        I("BASIC-KRN-04", "Source-routed packets are dropped", "medium", "Linux", Sysctl("net.ipv4.conf.all.accept_source_route", "0")),
        I("BASIC-KRN-05", "Links in shared folders are protected", "medium", "Linux", Sysctl("fs.protected_symlinks", "1")),

        I("BASIC-SVC-01", "The clock is kept right (chrony, ntp)", "low", "any", Running("[n]tpd|[c]hronyd|[t]imesyncd|[t]imemaster")),
        I("BASIC-SVC-02", "A system log is kept", "medium", "any", Running("[s]yslogd|[s]yslog-ng|[j]ournald")),

        I("BASIC-AIX-01", "root can't log in remotely", "high", "AIX",
            "l=$(lsuser -a rlogin root) || exit 107\necho \"$l\"\ncase \"$l\" in *rlogin=false*) exit 0 ;; esac\nexit 1"),
        I("BASIC-AIX-02", "Passwords have at least 8 characters", "medium", "AIX",
            Lssec("/etc/security/user", "default", "minlen", "[ \"$v\" -ge 8 ] 2>/dev/null && exit 0\nexit 1")),
        I("BASIC-AIX-03", "Accounts lock after at most 10 failed logins", "medium", "AIX",
            Lssec("/etc/security/user", "default", "loginretries", "[ \"$v\" -ge 1 ] 2>/dev/null && [ \"$v\" -le 10 ] && exit 0\nexit 1")),
        I("BASIC-AIX-04", "Passwords are not stored with the old crypt", "high", "AIX",
            Lssec("/etc/security/login.cfg", "usw", "pwd_algorithm", "case \"$v\" in ''|crypt) exit 1 ;; esac\nexit 0")),
        I("BASIC-AIX-05", "ICMP redirects are ignored", "medium", "AIX",
            "l=$(no -o ipignoreredirects) || exit 107\necho \"$l\"\ncase \"$l\" in *'= 1') exit 0 ;; esac\nexit 1"),
        I("BASIC-AIX-06", "Source-routed packets are not accepted", "medium", "AIX",
            "l=$(no -o ipsrcrouterecv) || exit 107\necho \"$l\"\ncase \"$l\" in *'= 0') exit 0 ;; esac\nexit 1"),
    };
}

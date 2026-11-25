# ScriptIX

**Hardening scripts for Linux, AIX and every other Unix.**

ScriptIX is a Windows app (and a command line tool) that turns a benchmark (CIS, STIG, SCAP) or your own list of
commands into **one plain POSIX `sh` script**. You copy that script to the server and run it there. It checks or
hardens the server, backs up every file its helpers change, logs every command with its output and exit code,
and writes a CSV you bring back to the app for a report. The scripts run on the server, not on your PC.

## Build and start

| File        | What it does |
|-------------|--------------|
| `build.bat` | Builds everything (needs the .NET 8 SDK or newer). Output: `dist\ScriptIX.exe` and `dist\scriptix-cli.exe` (command line). |
| `run.bat`   | Builds if needed, then starts the app. |
| `clean.bat` | Removes `bin`, `obj`, `dist` and the build log. |

Each `.bat` ends with `pause`, so the window never closes before you can read it.

## Use it

On first start a short intro walks through the pages (replay it any time from *Help*).

1. **Pick**: *Rules* → import a CIS benchmark PDF, a rule file (`.csv`, `.json`) or SCAP/XCCDF `.xml`
   (see `samples\sample_rules.csv`), choose a profile (Level 1 / Level 2) and tick rules. Or *My own commands* → type one command per line (see `samples\sample_commands.txt`).
2. **Create script**: you get an *apply* script, a *check-only* script and, when rules have undo commands, an *undo* script.
3. **On the server**: either press **Copy ready to paste** and paste the block into your SSH session (it writes the
   script, checks its SHA-256 and runs `--dry-run`; no scp needed), or save the `.sh`, copy it over and run:
   ```sh
   sh scriptix_apply.sh --verify      # not changed on the way (SHA-256)
   sh scriptix_apply.sh --selftest    # first time on this OS/shell: every tool present and behaving?
   sh scriptix_apply.sh --dry-run     # preview, changes nothing
   sh scriptix_apply.sh               # explains, asks "Apply? [y/N]", then runs
   sh scriptix_apply.sh --undo scriptix_apply_*/changes_*.manifest   # put it all back
   ```
   Or press **Run over SSH…**: Windows' own `ssh` runs the script on one or more servers in a console window and brings
   the results back. Check scripts just run; other scripts still ask before they change anything.
   To hand it to someone else, press **Email…**: ScriptIX opens a draft in your own mail app (Outlook, Thunderbird,
   Mail) with the script(s) attached, a subject and a message that lists each SHA-256 and how to run it. Type your own
   subject and text, or press *Fill in for me*. You press Send; ScriptIX never sends mail or asks for a password.
4. **Review**: copy `results_*.csv` back, open it in *Results* (or drop it on the window). *Report details* adds a title, names, organization, notes, a logo and pictures
   (PNG, JPG, GIF, BMP). *Export* saves PDF, Word, Excel, HTML, Markdown, text, CSV or JSON, or all of them at once
   (PDF uses the Edge or Chrome on this PC; CSV holds the rows only, JSON has no pictures),
   or press *Fix failed* to build a script for just the rules that failed.

## Many servers

*Servers* keeps a list of your servers (name, group, user, port, key file, sudo; never a password). Tick some and:

- **Run on ticked** runs a script on all of them over SSH, one after the other, and brings the results back.
- **Side by side** shows the last results rule by rule, one column per server. Save it as CSV.
- **Package…** installs, updates or removes the `scriptix` package, sets a daily scan, scans with the installed
  scripts, or only fetches their last results.

## Two ways to scan, you choose

| | From Windows | On the server |
|---|---|---|
| What you need | the ScriptIX app, nothing on the server | the `scriptix` package, no Windows |
| SCAP scan | *Rules* > *Check only*, then *Run over SSH* or copy the script | `scriptix eval --profile P FILE` |
| Reports | *Results > Export* (PDF, Word, Excel, HTML, XCCDF, ARF, CSV, JSON...) | HTML, XCCDF, ARF, CSV |
| Guide, fixes, tailoring, content check | *SCAP* menu | `scriptix guide`, `fix`, `tailor`, `validate` |
| Other servers | *Servers* | `scriptix ssh` |
| Every day | *Servers > Package…* | `scriptix schedule` |

Both make the same check scripts, byte for byte, so the results are the same. PDF, Word, Excel and CVSS are only in the app.

## The scriptix package

Ready-made packages are in `packages`. They have 36 basic checks inside (`basic`: accounts, files, sshd, network,
kernel, AIX password rules; a small set of our own, not a benchmark). To put your scripts inside instead, *Script > Packages…* (or
*Servers > Package… > Save the files…*, or `scriptix-cli package`) makes:

| File | For | Install by hand |
|---|---|---|
| `scriptix_..._all.deb` | Debian, Ubuntu | `dpkg -i FILE` |
| `scriptix-...noarch.rpm` | RHEL, Rocky, Alma, Oracle, SUSE, Fedora | `rpm -Uvh FILE` |
| `scriptix-...aix6.1.noarch.rpm` | AIX 7.1, 7.2, 7.3 with rpm | `rpm -Uvh FILE` |
| `scriptix-...-aix.sh` | AIX 7.1, 7.2, 7.3 | `sh FILE --install` |

The `-aix.sh` file holds everything and makes a real `scriptix.rte...bff` on AIX with AIX's own `backup` and `ar`
(`sh FILE`, for installp, smit or NIM), or installs it at once (`--install`). It needs no download. Use the AIX `.rpm` or the fileset, not both.

Packages made in the app have the scripts from the Script page inside and, if you say yes, the SCAP file that is open
(`scriptix-cli package --content FILE.xml`). Each one puts a `scriptix` command on the server. Scanning needs only `sh` and
the system's own tools; reading a SCAP file also needs `perl` (AIX, Debian, Ubuntu and SUSE have it; on a minimal Red Hat:
`dnf install perl-interpreter`). Installing runs nothing; the packages are not signed (compare `SHA256SUMS`).

Scan with a SCAP file (data stream, XCCDF or OVAL), as with oscap:

```sh
scriptix content                                   # the SCAP files here (SCAP Security Guide, or from the package)
scriptix info FILE.xml                             # what is inside, with the profiles
scriptix eval --profile cis_level1_server FILE.xml --report r.html --results r.xml --results-arf arf.xml
scriptix eval --profile cis_level1_server          # no file: the one made for this system
scriptix eval --profile P --remediate FILE.xml     # fix what failed (asks first), scan again; no undo, have a backup
scriptix report NAME                               # web page of the last run
scriptix guide --profile P FILE.xml --out g.html
scriptix fix --profile P --type ansible --results NAME FILE.xml   # bash, ansible, puppet...; script = a ScriptIX script of them
scriptix tailor --profile P --unselect RULE --set NAME=VALUE --out t.xml FILE.xml
scriptix eval --profile P --tailoring-file t.xml FILE.xml
scriptix add FILE.xml --profile P --name cis       # keep it as a check script: scan, schedule, status, ssh
scriptix ssh -c FILE.xml --profile P --out reports root@web1 root@aix1
scriptix xccdf eval --profile P --report r.html FILE.xml          # oscap's names and exit codes (0, 2, 1)
```

The other commands:

```sh
scriptix list                    # the scripts
scriptix scan                    # run the check scripts, keep the results (the last 30 scans)
scriptix status                  # last result of each script, and the schedule
scriptix results                 # what failed        (--all: every rule)
scriptix diff                    # what changed since the scan before
scriptix preview apply           # what the apply script would change
scriptix apply apply             # run it (asks first);  scriptix undo  puts it back
scriptix ssh root@web1 admin@db1:2222     # run the check scripts on other servers
scriptix ssh --sudo -i KEY -f servers.txt # many servers, with a key and sudo
scriptix ssh --apply apply root@web1      # run the apply script there (asks first)
scriptix servers                 # last result of every server; results, diff and export take --host HOST
scriptix schedule daily 02:30    # or: weekly sun 02:30, off   (cron.d, systemd timer or root's crontab)
scriptix add FILE.sh             # one more ScriptIX script;  remove, verify, export, selftest, help
```

`scriptix ssh` works like `oscap-ssh`, but the other server needs only `sh` and `sshd`, no ScriptIX and no oscap. The
script is sent, its hash is checked there, it runs, the results come back, and it is removed again. `ssh` asks for
passwords itself, once per server; they never pass through ScriptIX. New host keys are never accepted without asking.

A script that was changed after it was made is never run. Results stay in `/var/lib/scriptix` when the package is removed.

Tested: the `.deb` with dpkg and the `.rpm` with rpm 4.18 on Ubuntu 24.04, the command on dash, bash, ksh93, mksh, yash and
posh, and the SSH jobs with Windows' ssh as root and with sudo. The AIX `.rpm` was installed with Linux' rpm and
the AIX installer run with stand-in AIX commands only, **never on a real AIX**.
`scriptix eval` gave the same result as oscap 1.3.9 for every rule of the Ubuntu 22.04 CIS Level 1 Server profile, and its check
scripts were compared byte for byte with the app's for 44 profiles of the Ubuntu SCAP Security Guide.

Drag and drop works anywhere in the window: rules, SCAP files, command lists and results are recognised automatically.

## SCAP (what OpenSCAP does)

Open a SCAP data stream (`ssg-*-ds.xml`), an XCCDF benchmark or an OVAL/CVE file, pick a profile and press **Check only**.
The OVAL checks are compiled into the script and run by a small engine written in plain `awk`, so the server needs
neither oscap nor bash.

| OpenSCAP | ScriptIX |
|---|---|
| `oscap xccdf eval`, `oscap oval eval` | *Check only*, then run the script; on the server `scriptix eval` |
| `oscap info` | *SCAP > Info*, `scriptix info` |
| profiles, `--tailoring-file`, SCAP Workbench | *SCAP > Values*, the IN PROFILE column, *Load/Save tailoring* |
| `--results`, `--results-arf`, scores | *Results > Export > XCCDF / ARF*, the SCORE tile (default, flat, flat-unweighted, absolute) |
| `generate report` / `guide` / `fix` | *Export*, *SCAP > Security guide*, *SCAP > Export fixes* (Bash, Ansible, Puppet, Kubernetes, Ignition, blueprint, Kickstart, Bootc) |
| `--remediate` | *Fix failed*, `scriptix eval --remediate`. Both ask first. Undo covers only ScriptIX's own helpers, not the shell fixes of a SCAP file |
| `oscap-ssh` | *Run over SSH* on Windows, `scriptix ssh` on Linux and AIX (`ssh` asks for the password; it is never seen or stored) |
| `oscap-diff` | *Results > Compare* |
| SCE scripts, OCIL questions | run in the script / answered with *Your answer* on the Results page |
| `oscap cvss` | *SCAP > CVSS score* |
| `oscap ... validate` | *SCAP > Check this content*: ids and references (not a full schema validation) |

OVAL tests that run: textfilecontent54, file, filehash58, symlink, password, shadow, environmentvariable(58), variable,
family, uname, partition, sysctl, dpkginfo, rpminfo, systemdunitproperty, systemdunitdependency, interface,
inetlisteningservers, process58, runlevel, selinuxboolean, selinuxsecuritycontext, and on AIX fileset, oslevel, no and
interim_fix. Anything else ends as **NOT-CHECKED**, never as a pass. A tool that fails ends as **ERROR**.

Not included: image, VM and container scanning (`oscap-vm`, `oscap-podman`; run the script inside them instead), Windows,
LDAP, SQL and xmlfilecontent tests, rpmverify, schema (XSD) and Schematron validation, signature checks, CVSS 4, and
downloading content from the internet.

Checked against oscap 1.3.9 with the SSG content for Ubuntu 16.04-22.04 (about 2000 rules, dash and mawk): the same
result for every selected rule. The 22.04 content was also run on bash, mksh, ksh93, yash and busybox sh, with gawk,
gawk --posix and busybox awk, and on a hardened copy of the system. The AIX tests were
checked with stand-in commands only, not on a real AIX server.

## CIS benchmark PDFs (experimental)

Drop a CIS benchmark PDF on the window. ScriptIX reads each recommendation (`1.2.3 Title (Automated)`): its
profiles, the audit command and its expected output, and the remediation command. It does not need the CIS-CAT tool.

- Rules with a plain audit command and fix command are **Ready**.
- *Manual* recommendations, fixes written only as prose, and commands with placeholders such as `<user>` are
  marked **Needs review**. Fill them in on the rule's details panel before you tick them.
- The CIS audit scripts (`#!/usr/bin/env bash` blocks) are kept as one check that passes on `** PASS **`.

PDF layouts vary between benchmarks. Look at what was imported before you create the script.

## Where it runs

The generated script uses only POSIX `sh` features and POSIX tool options. It does **not** need bash, GNU tools,
`timeout`, `mktemp`, `sed -i`, `tee`, `[[ ]]`, `local` or `echo -e`.

| System | Shell used | Status |
|---|---|---|
| AIX 7.1, 7.2, 7.3 | `/usr/bin/sh` (ksh88), ksh93 | Full: engine + `aix_chsec`, `aix_chuser`, `aix_no`, `svc_disable` (SRC + rc.tcpip), file helpers |
| RHEL / CentOS / Rocky / Alma 6+, Oracle Linux | bash as sh | Full: engine + `sysctl_set`, `svc_disable` (systemd or SysV), file helpers |
| Debian / Ubuntu | dash | Full |
| SUSE / SLES | bash as sh | Full |
| Alpine / busybox | busybox ash | Full engine and file helpers |
| Solaris 10 / 11 | re-runs under `/usr/xpg4/bin/sh` | Engine, file helpers, `svc_disable` (SMF) |
| FreeBSD, OpenBSD | sh | Engine, file helpers, `sysctl_set`, `svc_disable` (rc.conf / rcctl) |
| HP-UX 11i | sh (POSIX) | Engine and file helpers |

A helper that does not apply to the OS returns *SKIPPED (not supported)*, never a false FAIL. Rules can be limited
to one OS (`## os: aix`, or the OS column in a rule file); they are SKIPPED elsewhere.

**Not sure about a server?** Run `sh SCRIPT --selftest` on it. It checks every tool and shell feature the script uses
(including a real timeout of a hung command) and prints one line per check and a final
`SELFTEST ... result=PASS|FAIL`. It changes nothing and does not need root.

## Script options

| Option | Meaning |
|---|---|
| `--selftest` | Check this server has everything the script needs. No root, changes nothing. |
| `--verify` | Check the script matches the SHA-256 shown in the app (uses sha256sum, shasum, openssl, digest, sha256 or csum). |
| `--dry-run` | Change nothing. Helpers print what they would change. |
| `-y`, `--yes` | Do not ask for confirmation. |
| `--stop-on-fail` | Stop at the first failure; the rest are SKIPPED. |
| `--only ID,ID` / `--skip ID,ID` | Run only / leave out these IDs. |
| `--timeout SEC` | Time limit per command, 0 = none. A hung command is stopped and marked FAIL (TIMEOUT). |
| `--list` | List the commands. |
| `--undo MANIFEST` | Restore everything the helpers recorded, newest first. |

Exit codes: `0` all passed · `1` at least one failed · `2` usage error · `3` precondition failed (not root, lock held, no SHA tool) · `4` interrupted.

Output folder `./scriptix_<kind>_<host>_<time>/` (mode 0700): `run_*.txt` full log, `history_*.txt`, `results_*.csv`,
`changes_*.manifest` and `backup/`.

## Helpers

Use them in fix commands. Each one is idempotent (does nothing when already right), backs up first, records undo
data, and only previews in `--dry-run`.

| Helper | What it does |
|---|---|
| `setcfg FILE KEY VALUE [SEP]` | Set `KEY VALUE` in a config file. Skips sshd `Match` blocks, tests sshd_config with `sshd -t` before saving. |
| `sysctl_set KEY VALUE` | Linux/BSD kernel parameter, now and after reboot. |
| `fperm MODE FILE` / `fowner OWNER[:GROUP] FILE` | File mode / owner. |
| `line_add FILE LINE` / `line_del FILE REGEX` | Add a missing line / remove matching lines (no `sed -i`). |
| `svc_disable NAME` | Stop and disable a service: systemd, SysV, AIX SRC + rc.tcpip, Solaris SMF, FreeBSD rc.conf, OpenBSD rcctl. |
| `aix_chsec FILE STANZA ATTR VALUE` | AIX stanza attribute (`/etc/security/user`, `login.cfg`...). |
| `aix_chuser ATTR=VALUE USER` | AIX user attribute. |
| `aix_no OPTION VALUE` | AIX network tunable, now and after reboot (`no -p`). |

## Markers for your own commands

Put them at the end of a line: `## expect: text`, `## expect-exact: text`, `## expect-regex: re`,
`## expect-not: text`, `## expect-rc: N`, `## timeout: N`, `## os: linux|aix|solaris|hpux|bsd|unix`, `## id: X`,
`## shell: bash`. A line starting with `#` names the next command. End a line with `\` to continue it.

## Command line

```
scriptix-cli generate INPUT [--out DIR] [--profile ID] [--all] [--check | --check-only] [--timeout N] [--stop-on-fail] [--no-redact]
scriptix-cli validate INPUT
scriptix-cli profiles FILE.xml
scriptix-cli info FILE.xml
scriptix-cli check-content FILE.xml
scriptix-cli guide FILE.xml [--profile ID] [--out F.html]
scriptix-cli fix FILE.xml --type bash|ansible|puppet|... [--profile ID] [--results F] [--out F]
scriptix-cli tailor FILE.xml [--profile ID] [--select A,B] [--unselect C,D] [--set NAME=VALUE] [--title T] [--out F.xml]
scriptix-cli oscap FILE.xml [--profile ID] [--out DIR]
scriptix-cli report RESULTS [--content FILE.xml] [--profile ID] [--xccdf F] [--arf F] [--html F] [--csv F] [--json F] [--md F] [--docx F] [--xlsx F]
scriptix-cli compare NOW BEFORE
scriptix-cli cvss VECTOR
scriptix-cli package [SCRIPT.sh...] [--content FILE.xml] [--type deb,rpm,aixrpm,aix] [--out DIR]
scriptix-cli matrix RESULTS... [--out F.csv]
scriptix-cli version
```

Commands that read SCAP content also take `--tailoring FILE`, `--set NAME=VALUE` and `--benchmark ID`.

## Safety

* Every value you type is single-quoted in the script, so nothing is expanded by accident.
* Only one ScriptIX run at a time per server (lock in `/var/run` or `/tmp`, stale locks are detected).
* Passwords, tokens and secrets are masked in logs and CSV (can be turned off).
* CSV cells that start with `= + - @` are neutralised so a spreadsheet cannot run them.
* Always run `--dry-run` first, on a test server first, and keep a second root session open while changing SSH or PAM.

## Project layout

```
src/ScriptIX.Core   engine, importers, reports, view-models (no WPF), runtime.sh, oval.awk and the packages' scripts, scap.pl included (embedded)
src/ScriptIX.App    WPF views (MVVM, no logic in code-behind)
src/ScriptIX.Cli    scriptix-cli.exe
samples/            sample_rules.csv, sample_commands.txt
```

## License

All rights reserved. You may read the code, but not use, copy, change or sell it without permission. See `LICENSE`.

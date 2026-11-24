# ============================================================================
# ScriptIX runtime. Strict POSIX sh: dash, bash, ksh93, AIX ksh88, busybox ash.
# Everything below the BODY marker is covered by SX_SHA256 (see --verify).
# ============================================================================

# ---- safe environment -------------------------------------------------------
set -f
sx_oldpath=$PATH
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ -d /usr/xpg4/bin ] && PATH=/usr/xpg4/bin:$PATH
IFS=:
for sx_d in $sx_oldpath /opt/freeware/bin; do
  case "$sx_d" in
    /*) case ":$PATH:" in *":$sx_d:"*) ;; *) PATH="$PATH:$sx_d" ;; esac ;;
  esac
done
set +f
export PATH
IFS=$(printf ' \t\n.'); IFS=${IFS%.}; SX_IFS=$IFS
LC_ALL=C; LANG=C; export LC_ALL LANG
umask 077
TAB=$(printf '\t')
SX_SELF=$0   # $0 inside functions is not reliable on old ksh88

# ---- settings baked in by the app ------------------------------------------
SX_KIND='{{KIND}}'
SX_VERSION='{{VERSION}}'
SX_TOTAL={{TOTAL}}
SX_RISKY={{RISKY}}
SX_SCHEMA=3
STOP={{STOP}}
NEEDROOT={{NEEDROOT}}
TIMEOUT={{TIMEOUT}}
REDACT={{REDACT}}
READONLY={{READONLY}}

# ---- state ------------------------------------------------------------------
DRY=0; YES=0; ONLY=''; SKIP=''; UNDO=''; ACTION=run
STOPPED=0; INTERRUPTED=0; FINISHED=0; LOCKED=0; INITEM=0
CPID=''; WPID=''; N=0; NPASS=0; NFAIL=0; NSKIP=0
OS=$(uname -s 2>/dev/null)
HOST=$( (hostname || uname -n) 2>/dev/null | tr -c 'A-Za-z0-9._\012-' '_')
[ -n "$HOST" ] || HOST=unknown
STAMP=$(date +%Y%m%d_%H%M%S)

# have CMD : is CMD available? (command -v can be missing in old ksh88, so scan PATH too)
have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  hv_ifs=$IFS; IFS=:
  for hv_d in $PATH; do
    if [ -f "$hv_d/$1" ] && [ -x "$hv_d/$1" ]; then IFS=$hv_ifs; return 0; fi
  done
  IFS=$hv_ifs
  return 1
}
# exists PATH : file, directory, link or device (avoids [ -e ], which old shells lack)
exists() { [ -f "$1" ] || [ -d "$1" ] || [ -h "$1" ] || [ -c "$1" ] || [ -b "$1" ] || [ -p "$1" ]; }
# is_bsd : FreeBSD, OpenBSD, NetBSD, DragonFly
is_bsd() { case "$OS" in *BSD|DragonFly) return 0 ;; esac; return 1; }
# os_match TARGET : any, Linux, AIX, SunOS, HP-UX, BSD, Unix (= not Linux)
os_match() {
  case "$1" in
    any) return 0 ;;
    BSD) is_bsd; return $? ;;
    Unix) [ "$OS" != Linux ]; return $? ;;
  esac
  [ "$1" = "$OS" ]
}
msg() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$1" >&2; }
die_usage() { err "Error: $1"; err "Run: sh $SX_SELF --help"; exit 2; }

usage() {
  cat <<'EOF'
ScriptIX script: checks and hardens AIX, Linux and other Unix servers,
and logs everything. Plain POSIX sh: AIX 7.1+ ksh88, bash, dash, ksh93,
busybox ash, Solaris (re-runs under /usr/xpg4/bin/sh), HP-UX, BSD.

Usage: sh SCRIPT [options]
  --selftest         check that this server has every tool the script needs
                     (run this first on a new OS; changes nothing, no root needed)
  (no options)       explain what will happen, then ask "Apply? [y/N]"
  --dry-run          change nothing; ScriptIX helpers show what they would change
  -y, --yes          do not ask for confirmation
  --stop-on-fail     stop at the first failed command (the rest are SKIPPED)
  --only ID[,ID]     run only these IDs
  --skip ID[,ID]     skip these IDs
  --timeout SEC      time limit per command in seconds (0 = no limit)
  --list             list the commands in this script and exit
  --verify           check the script was not changed after it was generated
  --undo MANIFEST    restore files and settings recorded in a changes manifest
  --help, --version

Exit codes: 0 all passed, 1 at least one failed, 2 usage error,
            3 precondition failed (not root, lock held, no SHA-256 tool),
            4 interrupted.
Output goes to ./scriptix_<kind>_<host>_<time>/ (folder mode 0700):
  run_*.txt (full log), history_*.txt, results_*.csv,
  changes_*.manifest and backup/ (only when something was changed).
EOF
}

# ---- arguments ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    --stop-on-fail) STOP=1 ;;
    --only) [ $# -ge 2 ] || die_usage "--only needs a list of IDs"; ONLY=$2; shift ;;
    --only=*) ONLY=${1#--only=} ;;
    --skip) [ $# -ge 2 ] || die_usage "--skip needs a list of IDs"; SKIP=$2; shift ;;
    --skip=*) SKIP=${1#--skip=} ;;
    --timeout) [ $# -ge 2 ] || die_usage "--timeout needs a number of seconds"; TIMEOUT=$2; shift ;;
    --timeout=*) TIMEOUT=${1#--timeout=} ;;
    --list) ACTION=list ;;
    --selftest) ACTION=selftest ;;
    --verify) ACTION=verify ;;
    --undo) [ $# -ge 2 ] || die_usage "--undo needs the path of a changes manifest"; ACTION=undo; UNDO=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) printf 'ScriptIX %s (%s script)\n' "$SX_VERSION" "$SX_KIND"; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
  shift
done
case "$TIMEOUT" in ''|*[!0-9]*) die_usage "--timeout needs a whole number of seconds" ;; esac

# ---- output files -----------------------------------------------------------------
OUT="$(pwd)/scriptix_${SX_KIND}_${HOST}_${STAMP}"
[ "$ACTION" = undo ] && OUT="$(pwd)/scriptix_undo_${HOST}_${STAMP}"
LOG="$OUT/run_${HOST}_${STAMP}.txt"
HIST="$OUT/history_${HOST}_${STAMP}.txt"
CSV="$OUT/results_${HOST}_${STAMP}.csv"
MAN="$OUT/changes_${HOST}_${STAMP}.manifest"
BAK="$OUT/backup"
WORK="$OUT/.work"
OF="$WORK/out"
HTMP="$WORK/history"

# ---- text helpers ------------------------------------------------------------------
redact() {
  if [ "$REDACT" = 1 ]; then
    sed -e 's/\([Pp][Aa][Ss][Ss][Ww][Oo]*[Rr]*[Dd][[:space:]]*[=:][[:space:]]*\)[^[:space:]]*/\1*****/g' \
        -e 's/\([Tt][Oo][Kk][Ee][Nn][[:space:]]*[=:][[:space:]]*\)[^[:space:]]*/\1*****/g' \
        -e 's/\([Ss][Ee][Cc][Rr][Ee][Tt][[:space:]]*[=:][[:space:]]*\)[^[:space:]]*/\1*****/g'
  else
    cat
  fi
}
say() {
  if [ "$REDACT" = 1 ]; then sx_l=$(printf '%s\n' "$1" | redact); else sx_l=$1; fi
  printf '%s\n' "$sx_l"
  printf '%s\n' "$sx_l" >> "$LOG"
}
csvq() { printf '%s' "$1" | tr '\012\015\011' '   ' | redact | sed -e 's/"/""/g' -e 's/^\([=+@-]\)/'"'"'\1/' | cut -c1-"${2:-300}"; }
short() { printf '%s' "$1" | tr '\012\015\011' '   ' | redact | cut -c1-80; }
now_s() { date '+%H %M %S' | awk '{ print $1 * 3600 + $2 * 60 + $3 }'; }
show_output() {
  [ -s "$1" ] || return 0
  redact < "$1" | awk '{ print "   | " $0 }' >> "$LOG"
  so_n=$(wc -l < "$1" | tr -d ' ')
  redact < "$1" | awk 'NR <= 15 { print "   | " $0 }'
  [ "${so_n:-0}" -gt 15 ] && printf '   | ... %s more line(s) in the log\n' "$((so_n - 15))"
  return 0
}
in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }

# ---- process control (portable timeout: AIX has no timeout command) ----------------
# ps_list : "PID PPID" for every process (the ps options differ per OS)
ps_list() {
  case "$OS" in
    *BSD|DragonFly|Darwin) ps -ax -o pid= -o ppid= 2>/dev/null ;;
    HP-UX) UNIX95=1 ps -e -o pid= -o ppid= 2>/dev/null ;;
    *) ps -e -o pid= -o ppid= 2>/dev/null || ps -ef 2>/dev/null | awk '{ print $2, $3 }' ;;
  esac | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1, $2 }'
}
kill_tree() {
  for kt_c in $(ps_list | awk -v p="$1" '$2 == p { print $1 }'); do
    kill_tree "$kt_c" "$2"
  done
  kill -"$2" "$1" 2>/dev/null
}
watchdog() {
  wd_i=0
  while [ "$wd_i" -lt "$2" ]; do
    sleep 1 2>/dev/null || exit 0   # no sleep: no timeout, rather than a false one
    kill -0 "$1" 2>/dev/null || exit 0
    wd_i=$((wd_i + 1))
  done
  : > "$WORK/timedout"
  kill_tree "$1" TERM
  sleep 2
  kill_tree "$1" KILL
  exit 0
}
# run_cmd SHELL TIMEOUT COMMAND : output in $OF, exit code in $rc, TIMEDOUT=1 on timeout
run_cmd() {
  rm -f "$WORK/timedout"
  if [ "$1" = bash ]; then
    bash -c "$3" > "$OF" 2>&1 < /dev/null &
  else
    ( eval "$3" ) > "$OF" 2>&1 < /dev/null &
  fi
  CPID=$!
  WPID=''
  if [ "$2" -gt 0 ]; then watchdog "$CPID" "$2" > /dev/null 2>&1 & WPID=$!; fi
  wait "$CPID"; rc=$?
  # -9: ksh-like shells act on TERM only after the watchdog's sleep, one second per command
  if [ -n "$WPID" ]; then kill -9 "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
  CPID=''; WPID=''
  TIMEDOUT=0
  [ -f "$WORK/timedout" ] && TIMEDOUT=1
  return 0
}

# ---- change tracking: backups + manifest (used by the helpers) ----------------------
man_add() { printf '%s\n' "$1" >> "$MAN"; }
# backup_file PATH : keeps the original once per run (mode, owner and times preserved)
backup_file() {
  bf_f=$1
  [ "$DRY" = 1 ] && return 0
  if exists "$bf_f"; then
    grep -F "FILE${TAB}${bf_f}${TAB}" "$MAN" >/dev/null 2>&1 && return 0
    bf_b="$BAK$bf_f"
    mkdir -p "$(dirname "$bf_b")" && cp -p "$bf_f" "$bf_b" || { msg "cannot back up $bf_f, nothing changed"; return 1; }
    man_add "FILE${TAB}${bf_f}${TAB}${bf_b}"
  else
    grep -x -F "NEWFILE${TAB}${bf_f}" "$MAN" >/dev/null 2>&1 || man_add "NEWFILE${TAB}${bf_f}"
  fi
  return 0
}
# replace_file TARGET NEWCONTENT : write in place, keeping inode, owner and mode
replace_file() { cat "$2" > "$1" && rm -f "$2"; }
fmode() {
  ls -ld "$1" 2>/dev/null | awk '{
    s = substr($1, 2, 9); o = ""; sp = 0
    for (i = 0; i < 3; i++) {
      c = substr(s, i * 3 + 1, 3); d = 0
      if (substr(c, 1, 1) == "r") d += 4
      if (substr(c, 2, 1) == "w") d += 2
      x = substr(c, 3, 1)
      if (x == "x" || x == "s" || x == "t") d += 1
      if ((x == "s" || x == "S") && i == 0) sp += 4
      if ((x == "s" || x == "S") && i == 1) sp += 2
      if ((x == "t" || x == "T") && i == 2) sp += 1
      o = o d
    }
    print sp o }'
}
fowner_of() { ls -ld "$1" 2>/dev/null | awk '{ print $3 ":" $4 }'; }

# ============================================================================
# Helpers. Each one: idempotent, backs up before changing, records undo info,
# previews in --dry-run, returns 254 = "not supported on this OS" (SKIPPED).
# ============================================================================

# setcfg FILE KEY VALUE [SEP] : set "KEY<SEP>VALUE" (sshd_config, login.defs, ...)
# Keys match case-insensitively. Lines inside sshd "Match" blocks are left alone;
# a new line goes before the first Match block. sshd_config is tested with sshd -t.
setcfg() {
  sc_f=$1; sc_k=$2; sc_v=$3; sc_sep=${4:- }
  if [ -z "$sc_f" ] || [ -z "$sc_k" ]; then msg "usage: setcfg FILE KEY VALUE [SEP]"; return 2; fi
  sc_new="$WORK/setcfg.new"
  if [ -f "$sc_f" ]; then
    SX_K=$sc_k SX_L="$sc_k$sc_sep$sc_v" awk '
      BEGIN { k = tolower(ENVIRON["SX_K"]); line = ENVIRON["SX_L"]; done = 0; inmatch = 0 }
      {
        t = $0; sub(/^[ \t]+/, "", t)
        if (tolower(substr(t, 1, 6)) == "match " || tolower(substr(t, 1, 6)) == "match\t") {
          if (!done) { print line; done = 1 }
          inmatch = 1
        }
        if (!inmatch && tolower(substr(t, 1, length(k))) == k) {
          nx = substr(t, length(k) + 1, 1)
          if (nx == " " || nx == "\t" || nx == "=" || nx == "") {
            if (!done) { print line; done = 1 }
            next
          }
        }
        print
      }
      END { if (!done) print line }' "$sc_f" > "$sc_new" || return 1
    if cmp -s "$sc_f" "$sc_new"; then rm -f "$sc_new"; msg "already set: $sc_k$sc_sep$sc_v in $sc_f"; return 0; fi
  else
    printf '%s\n' "$sc_k$sc_sep$sc_v" > "$sc_new" || return 1
  fi
  case "$sc_f" in
    */sshd_config)
      # sshd -t reads the host keys, so it only works as root.
      if ! have sshd; then
        msg "note: sshd not found, the new $sc_f was not syntax-checked"
      elif [ "$(id -u 2>/dev/null)" != 0 ]; then
        msg "note: sshd -t needs root, the new $sc_f was not syntax-checked in this preview"
      elif ! sshd -t -f "$sc_new" > "$WORK/sshd_t" 2>&1; then
        if grep -i 'privilege separation' "$WORK/sshd_t" >/dev/null 2>&1; then
          # sshd is not running (no /run/sshd or /var/empty): sshd -t cannot test anything
          msg "note: sshd -t cannot run here ($(cat "$WORK/sshd_t")), the new $sc_f was not syntax-checked"
        else
          msg "sshd -t rejected the new $sc_f, nothing changed:"; cat "$WORK/sshd_t"; rm -f "$sc_new"; return 1
        fi
      else
        # first value wins in sshd: an Include (sshd_config.d) earlier in the file can override this line
        sc_eff=$(sshd -T -f "$sc_new" 2>/dev/null | SX_K=$sc_k awk 'tolower($1) == tolower(ENVIRON["SX_K"]) { $1 = ""; sub(/^ /, ""); print; exit }')
        if [ -n "$sc_eff" ] && [ "$(printf '%s' "$sc_eff" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$sc_v" | tr 'A-Z' 'a-z')" ]; then
          msg "WARNING: sshd will still use '$sc_k $sc_eff': an earlier line or an Include file (sshd_config.d) sets it first."
        fi
      fi ;;
  esac
  if [ "$DRY" = 1 ]; then
    if [ -f "$sc_f" ]; then msg "WOULD change $sc_f:"; if have diff; then diff "$sc_f" "$sc_new"; else msg "(no diff tool; new content:)"; cat "$sc_new"; fi; else msg "WOULD create $sc_f with: $sc_k$sc_sep$sc_v"; fi
    rm -f "$sc_new"; return 0
  fi
  backup_file "$sc_f" || { rm -f "$sc_new"; return 1; }
  replace_file "$sc_f" "$sc_new" || return 1
  msg "changed $sc_f: $sc_k$sc_sep$sc_v"
  case "$sc_f" in */sshd_config) msg "note: reload sshd for this to take effect (keep a second session open)" ;; esac
  return 0
}

# sysctl_set KEY VALUE : apply now and persist it
#   Linux: /etc/sysctl.d/99-scriptix.conf   BSD: /etc/sysctl.conf   (AIX: use aix_no)
sysctl_set() {
  ss_k=$1; ss_v=$2
  if [ -z "$ss_k" ] || [ -z "$ss_v" ]; then msg "usage: sysctl_set KEY VALUE"; return 2; fi
  if [ "$OS" = Linux ]; then
    ss_conf=/etc/sysctl.d/99-scriptix.conf; ss_line="$ss_k = $ss_v"
  elif is_bsd; then
    ss_conf=/etc/sysctl.conf; ss_line="$ss_k=$ss_v"
  else
    msg "sysctl_set supports Linux and BSD (this is $OS; on AIX use aix_no)"; return 254
  fi
  ss_live=$(sysctl -n "$ss_k" 2>/dev/null | tr '\011' ' ' | tr -s ' ')
  ss_want=$(printf '%s' "$ss_v" | tr '\011' ' ' | tr -s ' ')
  if [ "$ss_live" = "$ss_want" ] && grep -x -F "$ss_line" "$ss_conf" >/dev/null 2>&1; then
    msg "already set: $ss_line"; return 0
  fi
  if [ "$DRY" = 1 ]; then msg "WOULD set $ss_k from '$ss_live' to '$ss_v' and persist it in $ss_conf"; return 0; fi
  mkdir -p "$(dirname "$ss_conf")" || return 1
  backup_file "$ss_conf" || return 1
  { grep -v "^[[:space:]]*$ss_k[[:space:]]*=" "$ss_conf" 2>/dev/null; printf '%s\n' "$ss_line"; } > "$WORK/sysctl.new" || return 1
  replace_file "$ss_conf" "$WORK/sysctl.new" || return 1
  man_add "SYSCTL${TAB}${ss_k}${TAB}${ss_live}"
  if [ "$OS" = Linux ]; then sysctl -w "$ss_k=$ss_v" >/dev/null; else sysctl "$ss_k=$ss_v" >/dev/null; fi ||
    { msg "setting $ss_k=$ss_v live failed (it is persisted for the next boot)"; return 1; }
  msg "set $ss_line (was '$ss_live')"
}

# fperm MODE FILE : set an octal mode (e.g. 0600)
fperm() {
  fp_m=$1; fp_f=$2
  case "$fp_m" in [0-7][0-7][0-7]) fp_m="0$fp_m" ;; [0-7][0-7][0-7][0-7]) ;; *) msg "fperm needs an octal mode like 0600"; return 2 ;; esac
  exists "$fp_f" || { msg "not found: $fp_f"; return 1; }
  fp_cur=$(fmode "$fp_f")
  [ "$fp_cur" = "$fp_m" ] && { msg "already $fp_m: $fp_f"; return 0; }
  [ "$DRY" = 1 ] && { msg "WOULD chmod $fp_f from $fp_cur to $fp_m"; return 0; }
  man_add "MODE${TAB}${fp_f}${TAB}${fp_cur}"
  chmod "$fp_m" "$fp_f" || return 1
  msg "chmod $fp_f: $fp_cur -> $fp_m"
}

# fowner OWNER[:GROUP] FILE
fowner() {
  fo_o=$1; fo_f=$2
  exists "$fo_f" || { msg "not found: $fo_f"; return 1; }
  fo_cur=$(fowner_of "$fo_f")
  case "$fo_o" in *:*) fo_cmp=$fo_cur ;; *) fo_cmp=${fo_cur%%:*} ;; esac
  [ "$fo_cmp" = "$fo_o" ] && { msg "already owned by $fo_o: $fo_f"; return 0; }
  [ "$DRY" = 1 ] && { msg "WOULD chown $fo_f from $fo_cur to $fo_o"; return 0; }
  man_add "OWNER${TAB}${fo_f}${TAB}${fo_cur}"
  chown "$fo_o" "$fo_f" || return 1
  msg "chown $fo_f: $fo_cur -> $fo_o"
}

# line_add FILE LINE : make sure an exact line is present
line_add() {
  la_f=$1; la_l=$2
  grep -x -F -e "$la_l" "$la_f" >/dev/null 2>&1 && { msg "already present in $la_f"; return 0; }
  [ "$DRY" = 1 ] && { msg "WOULD add to $la_f: $la_l"; return 0; }
  mkdir -p "$(dirname "$la_f")" || return 1
  backup_file "$la_f" || return 1
  printf '%s\n' "$la_l" >> "$la_f" || return 1
  msg "added to $la_f: $la_l"
}

# line_del FILE ERE : remove the lines that match an extended regex
line_del() {
  ld_f=$1; ld_re=$2
  [ -f "$ld_f" ] || { msg "not found: $ld_f (nothing to do)"; return 0; }
  grep -E -e "$ld_re" "$ld_f" >/dev/null 2>&1 || { msg "no matching lines in $ld_f"; return 0; }
  if [ "$DRY" = 1 ]; then msg "WOULD remove from $ld_f:"; grep -n -E -e "$ld_re" "$ld_f"; return 0; fi
  backup_file "$ld_f" || return 1
  grep -v -E -e "$ld_re" "$ld_f" > "$WORK/linedel.new"
  replace_file "$ld_f" "$WORK/linedel.new" || return 1
  msg "removed matching lines from $ld_f"
}

# svc_disable NAME : stop and disable a service (systemd / SysV on Linux, SRC + rc.tcpip on AIX)
svc_disable() {
  sv_n=$1
  [ -n "$sv_n" ] || { msg "usage: svc_disable SERVICE"; return 2; }
  case "$OS" in
    Linux)
      if have systemctl; then
        systemctl cat "$sv_n" >/dev/null 2>&1 || { msg "not installed: $sv_n (nothing to do)"; return 0; }
        sv_en=$(systemctl is-enabled "$sv_n" 2>/dev/null); sv_ac=$(systemctl is-active "$sv_n" 2>/dev/null)
        sv_need=0
        case "$sv_en" in enabled|enabled-runtime) sv_need=1 ;; esac
        [ "$sv_ac" = active ] && sv_need=1
        [ "$sv_need" = 0 ] && { msg "already off: $sv_n ($sv_en, $sv_ac)"; return 0; }
        [ "$DRY" = 1 ] && { msg "WOULD disable and stop $sv_n (now $sv_en, $sv_ac)"; return 0; }
        man_add "SVC${TAB}${sv_n}${TAB}systemd/${sv_en}/${sv_ac}"
        systemctl disable "$sv_n" || return 1
        systemctl stop "$sv_n" || return 1
        msg "disabled and stopped $sv_n (was $sv_en, $sv_ac)"
      elif have chkconfig; then
        chkconfig --list "$sv_n" >/dev/null 2>&1 || { msg "not installed: $sv_n (nothing to do)"; return 0; }
        chkconfig --list "$sv_n" 2>/dev/null | grep ':on' >/dev/null || { msg "already off: $sv_n"; return 0; }
        [ "$DRY" = 1 ] && { msg "WOULD chkconfig $sv_n off and stop it"; return 0; }
        man_add "SVC${TAB}${sv_n}${TAB}sysv/on/unknown"
        chkconfig "$sv_n" off || return 1
        service "$sv_n" stop >/dev/null 2>&1
        msg "disabled $sv_n"
      else
        msg "no systemctl or chkconfig found"; return 254
      fi ;;
    AIX)
      lssrc -s "$sv_n" >/dev/null 2>&1 || { msg "no SRC subsystem named $sv_n (nothing to do)"; return 0; }
      sv_ac=$(lssrc -s "$sv_n" 2>/dev/null | awk 'NR > 1 { print $NF }')
      sv_rc=0
      grep "^[[:space:]]*start[[:space:]].*/$sv_n[[:space:]]" /etc/rc.tcpip >/dev/null 2>&1 && sv_rc=1
      if [ "$sv_ac" != active ] && [ "$sv_rc" = 0 ]; then msg "already off: $sv_n"; return 0; fi
      [ "$DRY" = 1 ] && { msg "WOULD stop $sv_n (now $sv_ac) and disable its start line in /etc/rc.tcpip"; return 0; }
      if [ "$sv_rc" = 1 ]; then
        backup_file /etc/rc.tcpip || return 1
        sed "s|^\([[:space:]]*start[[:space:]].*/$sv_n[[:space:]]\)|#\1|" /etc/rc.tcpip > "$WORK/rctcpip.new" || return 1
        replace_file /etc/rc.tcpip "$WORK/rctcpip.new" || return 1
      fi
      man_add "SVC${TAB}${sv_n}${TAB}src/x/${sv_ac}"
      if [ "$sv_ac" = active ]; then stopsrc -s "$sv_n" || return 1; fi
      msg "stopped and disabled $sv_n" ;;
    SunOS)
      have svcs || { msg "no svcs (SMF) found"; return 254; }
      sv_st=$(svcs -H -o state "$sv_n" 2>/dev/null)
      [ -n "$sv_st" ] || { msg "no SMF service named $sv_n (nothing to do)"; return 0; }
      [ "$sv_st" = disabled ] && { msg "already off: $sv_n"; return 0; }
      [ "$DRY" = 1 ] && { msg "WOULD svcadm disable $sv_n (now $sv_st)"; return 0; }
      man_add "SVC${TAB}${sv_n}${TAB}smf/${sv_st}/x"
      svcadm disable "$sv_n" || return 1
      msg "disabled $sv_n (was $sv_st)" ;;
    FreeBSD|DragonFly)
      have sysrc || { msg "no sysrc found"; return 254; }
      service "$sv_n" enabled >/dev/null 2>&1 && sv_en=1 || sv_en=0
      service "$sv_n" onestatus >/dev/null 2>&1 && sv_ac=1 || sv_ac=0
      if [ "$sv_en" = 0 ] && [ "$sv_ac" = 0 ]; then msg "already off: $sv_n"; return 0; fi
      [ "$DRY" = 1 ] && { msg "WOULD set ${sv_n}_enable=NO and stop $sv_n"; return 0; }
      backup_file /etc/rc.conf || return 1
      man_add "SVC${TAB}${sv_n}${TAB}bsd/${sv_en}/${sv_ac}"
      sysrc "${sv_n}_enable=NO" >/dev/null || return 1
      [ "$sv_ac" = 1 ] && { service "$sv_n" onestop || return 1; }
      msg "disabled and stopped $sv_n" ;;
    OpenBSD)
      have rcctl || { msg "no rcctl found"; return 254; }
      rcctl get "$sv_n" status >/dev/null 2>&1 && sv_en=1 || sv_en=0
      rcctl check "$sv_n" >/dev/null 2>&1 && sv_ac=1 || sv_ac=0
      if [ "$sv_en" = 0 ] && [ "$sv_ac" = 0 ]; then msg "already off: $sv_n"; return 0; fi
      [ "$DRY" = 1 ] && { msg "WOULD rcctl disable and stop $sv_n"; return 0; }
      man_add "SVC${TAB}${sv_n}${TAB}rcctl/${sv_en}/${sv_ac}"
      rcctl disable "$sv_n" || return 1
      [ "$sv_ac" = 1 ] && { rcctl stop "$sv_n" || return 1; }
      msg "disabled and stopped $sv_n" ;;
    *) msg "svc_disable supports Linux, AIX, Solaris, FreeBSD and OpenBSD (this is $OS)"; return 254 ;;
  esac
}

# aix_no OPTION VALUE : AIX network tunable, now and after reboot (no -p -o)
aix_no() {
  [ "$OS" = AIX ] || { msg "aix_no supports AIX only (this is $OS)"; return 254; }
  [ $# -eq 2 ] || { msg "usage: aix_no OPTION VALUE"; return 2; }
  an_cur=$(no -o "$1" 2>/dev/null | awk -F= '{ gsub(/[ \t]/, "", $2); print $2 }')
  [ -n "$an_cur" ] || { msg "no such network option: $1"; return 1; }
  [ "$an_cur" = "$2" ] && { msg "already set: $1 = $2"; return 0; }
  [ "$DRY" = 1 ] && { msg "WOULD set network option $1 from '$an_cur' to '$2' (no -p)"; return 0; }
  man_add "AIXNO${TAB}${1}${TAB}${an_cur}"
  no -p -o "$1=$2" >/dev/null || return 1
  msg "set $1 = $2 (was '$an_cur')"
}

# aix_chsec FILE STANZA ATTR VALUE : e.g. aix_chsec /etc/security/user default minlen 8
aix_chsec() {
  [ "$OS" = AIX ] || { msg "aix_chsec supports AIX only (this is $OS)"; return 254; }
  [ $# -eq 4 ] || { msg "usage: aix_chsec FILE STANZA ATTR VALUE"; return 2; }
  ac_cur=$(lssec -f "$1" -s "$2" -a "$3" 2>/dev/null | sed 's/^[^=]*=//')
  [ "$ac_cur" = "$4" ] && { msg "already set: [$2] $3=$4 in $1"; return 0; }
  [ "$DRY" = 1 ] && { msg "WOULD set [$2] $3 in $1 from '$ac_cur' to '$4'"; return 0; }
  backup_file "$1" || return 1
  chsec -f "$1" -s "$2" -a "$3=$4" || return 1
  msg "set [$2] $3=$4 in $1 (was '$ac_cur')"
}

# aix_chuser ATTR=VALUE USER : e.g. aix_chuser rlogin=false root
aix_chuser() {
  [ "$OS" = AIX ] || { msg "aix_chuser supports AIX only (this is $OS)"; return 254; }
  [ $# -eq 2 ] || { msg "usage: aix_chuser ATTR=VALUE USER"; return 2; }
  au_a=${1%%=*}; au_v=${1#*=}
  au_cur=$(lsuser -a "$au_a" "$2" 2>/dev/null | sed 's/^[^=]*=//')
  [ "$au_cur" = "$au_v" ] && { msg "already set: $2 $au_a=$au_v"; return 0; }
  [ "$DRY" = 1 ] && { msg "WOULD set $2 $au_a from '$au_cur' to '$au_v'"; return 0; }
  man_add "USERATTR${TAB}${2}${TAB}${au_a}=${au_cur}"
  chuser "$1" "$2" || return 1
  msg "set $2 $au_a=$au_v (was '$au_cur')"
}

# oval ID : evaluates the compiled OVAL check of the current item (see oval.awk)
oval() {
  [ -f "$WORK/ir/$id" ] || { msg "the compiled check of $id is not in this script"; return 252; }
  awk -v W="$WORK" -v SYS="$OS" -v PIDTAG=$$ -f "$WORK/oval.awk" "$WORK/ir/$id"
}

# ============================================================================
# Running items
# ============================================================================
# record RESULT DETAIL : counts, history line, CSV row, screen line
record() {
  case "$1" in
    PASS) NPASS=$((NPASS + 1)) ;;
    FAIL) NFAIL=$((NFAIL + 1)) ;;
    *) NSKIP=$((NSKIP + 1)) ;;
  esac
  if [ "$2" != FILTERED ]; then
    case "$1" in
      PASS) say "   -> PASS" ;;
      FAIL) if [ "$2" = TIMEOUT ]; then say "   -> FAIL (timed out after ${tmo}s)"; else say "   -> FAIL (rc=${rc:--}${2:+, $2})"; fi ;;
      *) say "   -> SKIPPED ($2)" ;;
    esac
  fi
  printf '%-5s %-9s %-8s %-15s %-4s %s\n' "$N" "$tm" "$1" "${2:--}" "${rc:--}" "$(short "$cmd")" >> "$HTMP"
  rc_out=''
  [ -s "$OF" ] && [ "$1" != SKIPPED ] && rc_out=$(dd if="$OF" bs=600 count=1 2>/dev/null)
  printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
    "$SX_SCHEMA" "$N" "$(csvq "$id")" "$(csvq "$title")" "$sev" "$tm" "$1" "$2" "${rc:--}" "$dur" \
    "$(csvq "$cmd")" "$(csvq "$expected")" "$(csvq "$rc_out" 200)" "$mode" "$ros" "$tmo_raw" "$sh_kind" >> "$CSV"
  INITEM=0
  [ "$1" = FAIL ] && [ "$STOP" = 1 ] && STOPPED=1
  return 0
}

# run_item ID TITLE SEVERITY OS MODE EXPECTED TIMEOUT FLAGS COMMAND
#   FLAGS: h = command is a plain helper call (safe to preview in --dry-run), b = needs bash,
#          o = OVAL check, s = SCE check script, m = check by hand
run_item() {
  if [ "$ACTION" = list ]; then printf '%-28s %-6s %-6s %s\n' "$1" "$4" "$3" "$2"; return 0; fi
  [ "$INTERRUPTED" = 1 ] && return 0
  id=$1; title=$2; sev=$3; ros=$4; mode=$5; expected=$6; tmo=$7; flags=$8; cmd=$9; tmo_raw=$7
  case "$tmo" in ''|*[!0-9]*|0) tmo=$TIMEOUT ;; esac
  N=$((N + 1)); tm=$(date +%H:%M:%S); rc=''; dur=0; INITEM=1
  sh_kind=sh; case "$flags" in *b*) sh_kind=bash ;; esac
  : > "$OF"
  if [ -n "$ONLY" ] && ! in_list "$id" "$ONLY"; then record SKIPPED FILTERED; return 0; fi
  if [ -n "$SKIP" ] && in_list "$id" "$SKIP"; then record SKIPPED FILTERED; return 0; fi
  say ""
  say "=== [$N/$SX_TOTAL] $id  $title"
  say "\$ $cmd"
  if [ "$STOPPED" = 1 ]; then record SKIPPED STOPPED; return 0; fi
  if ! os_match "$ros"; then record SKIPPED OTHER-OS; return 0; fi
  if [ "$sh_kind" = bash ] && ! have bash; then record SKIPPED NEEDS-BASH; return 0; fi
  case "$flags" in
    *m*)
      [ "$DRY" = 0 ] && [ -f "$WORK/ir/$id" ] && { run_cmd sh "$tmo" oval; [ "$rc" = 250 ] && { record SKIPPED NOT-APPLICABLE; return 0; }; : > "$OF"; }
      rc=''; record SKIPPED MANUAL; return 0 ;;
  esac
  if [ "$DRY" = 1 ]; then
    case "$flags" in
      *h*)
        run_cmd sh "$tmo" "$cmd"; show_output "$OF"
        if [ "$rc" = 254 ]; then record SKIPPED UNSUPPORTED
        elif [ "$rc" = 0 ]; then record SKIPPED DRY-RUN
        else record SKIPPED PREVIEW-FAILED; fi
        return 0 ;;
    esac
    record SKIPPED DRY-RUN; return 0
  fi
  t0=$(now_s)
  run_cmd "$sh_kind" "$tmo" "$cmd"
  t1=$(now_s); dur=$((t1 - t0)); [ "$dur" -lt 0 ] && dur=$((dur + 86400))
  show_output "$OF"
  case "$flags" in
    *[os]*)
      if [ "$TIMEDOUT" = 1 ]; then record SKIPPED TIMEOUT; return 0; fi
      case "$rc" in
        0|101|109) record PASS '' ;;
        1|102) record FAIL '' ;;
        250|105) record SKIPPED NOT-APPLICABLE ;;
        251|106|107) record SKIPPED NOT-CHECKED ;;
        253|104) record SKIPPED UNKNOWN ;;
        108) record SKIPPED INFORMATIONAL ;;
        *) record SKIPPED ERROR ;;
      esac
      return 0 ;;
  esac
  if [ "$TIMEDOUT" = 1 ]; then record FAIL TIMEOUT; return 0; fi
  case "$flags" in *h*) [ "$rc" = 254 ] && { record SKIPPED UNSUPPORTED; return 0; } ;; esac
  ok=0
  case "$mode" in
    rc0) [ "$rc" -eq 0 ] && ok=1 ;;
    rc) [ "$rc" = "$expected" ] && ok=1 ;;
    equals) [ "$(cat "$OF")" = "$expected" ] && ok=1 ;;
    contains) grep -F -e "$expected" "$OF" >/dev/null 2>&1 && ok=1 ;;
    notcontains) grep -F -e "$expected" "$OF" >/dev/null 2>&1 || ok=1 ;;
    regex) grep -E -e "$expected" "$OF" >/dev/null 2>&1 && ok=1 ;;
    atleast) v=$(cat "$OF"); [ "$v" -ge "$expected" ] 2>/dev/null && ok=1 ;;
    atmost) v=$(cat "$OF"); [ "$v" -le "$expected" ] 2>/dev/null && ok=1 ;;
  esac
  if [ "$ok" = 1 ]; then record PASS ''; else record FAIL ''; fi
}

finish() {
  [ "$FINISHED" = 1 ] && return 0
  FINISHED=1
  fi_state=COMPLETE
  [ "$STOPPED" = 1 ] && fi_state="STOPPED AT FIRST FAILURE"
  [ "$INTERRUPTED" = 1 ] && fi_state=INTERRUPTED
  [ "$DRY" = 1 ] && fi_state="$fi_state (DRY RUN, nothing changed)"
  fi_ran=$((NPASS + NFAIL)); fi_rate=0
  [ "$fi_ran" -gt 0 ] && fi_rate=$((NPASS * 100 / fi_ran))
  {
    printf 'ScriptIX %s  %s script  host %s (%s)  %s\n' "$SX_VERSION" "$SX_KIND" "$HOST" "$OS" "$STAMP"
    printf 'Run state      : %s\n\n' "$fi_state"
    printf 'COMMAND HISTORY\n'
    printf '%-5s %-9s %-8s %-15s %-4s %s\n' '#' TIME RESULT DETAIL RC COMMAND
    cat "$HTMP" 2>/dev/null
    printf '\nSUMMARY\n'
    printf 'Planned        : %s\n' "$SX_TOTAL"
    printf 'Recorded       : %s\n' "$N"
    printf 'Passed         : %s\n' "$NPASS"
    printf 'Failed         : %s\n' "$NFAIL"
    printf 'Skipped        : %s\n' "$NSKIP"
    printf 'Pass rate      : %s%% (of the commands that ran)\n' "$fi_rate"
    if [ "$NFAIL" -gt 0 ]; then
      printf '\nFAILED COMMANDS\n'
      awk '$3 == "FAIL"' "$HTMP" 2>/dev/null
    fi
  } > "$HIST"
  printf '\n'; cat "$HIST"; printf '\n' >> "$LOG"; cat "$HIST" >> "$LOG"
  if [ -s "$MAN" ]; then
    fi_ch=$(wc -l < "$MAN" | tr -d ' ')
    say ""
    say "Changes recorded: $fi_ch (backups in $BAK)"
    say "To undo them:     sh $SX_SELF --undo $MAN"
  else
    rm -f "$MAN"
  fi
  say ""
  say "Done: $NPASS passed, $NFAIL failed, $NSKIP skipped. Files are in $OUT/"
}

cleanup() {
  rm -rf "$WORK" 2>/dev/null
  [ "$LOCKED" = 1 ] && rm -rf "$LOCKDIR" 2>/dev/null
  LOCKED=0
}

on_signal() {
  trap '' INT TERM HUP
  INTERRUPTED=1
  [ -n "$CPID" ] && kill_tree "$CPID" TERM
  [ -n "$WPID" ] && kill -9 "$WPID" 2>/dev/null
  say ""
  say "!!! Interrupted. Writing the partial results..."
  [ "$INITEM" = 1 ] && record FAIL INTERRUPTED
  finish
  cleanup
  trap - 0   # some shells (mksh) let the exit trap overwrite the exit code
  exit 4
}

take_lock() {
  if [ -d /var/run ] && [ -w /var/run ]; then LOCKDIR=/var/run/scriptix.lock; else LOCKDIR=/tmp/scriptix.lock; fi
  if mkdir "$LOCKDIR" 2>/dev/null; then msg $$ > "$LOCKDIR/pid"; LOCKED=1; return 0; fi
  lk_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
  [ -n "$lk_pid" ] || { sleep 1; lk_pid=$(cat "$LOCKDIR/pid" 2>/dev/null); }
  if [ -n "$lk_pid" ] && kill -0 "$lk_pid" 2>/dev/null; then
    err "Another ScriptIX run is active on this host (pid $lk_pid, lock $LOCKDIR)."; return 1
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || { err "Cannot take the lock $LOCKDIR."; return 1; }
  msg $$ > "$LOCKDIR/pid"; LOCKED=1
  return 0
}

need_root() {
  if [ "$(id -u 2>/dev/null)" != 0 ]; then err "$1"; exit 3; fi
}

confirm() {
  printf '%s [y/N] ' "$1"
  read sx_ans || sx_ans=''
  case "$sx_ans" in y|Y|yes|YES|Yes) return 0 ;; esac
  return 1
}

setup_out() {
  mkdir -p "$OUT" "$WORK" || { err "Cannot create $OUT"; exit 3; }
  : > "$LOG"; : > "$HTMP"
}

# ---- --verify ----------------------------------------------------------------------
sha_of() {
  if have sha256sum; then sha256sum "$1" | awk '{ print $1 }'
  elif have shasum; then shasum -a 256 "$1" | awk '{ print $1 }'
  elif have openssl; then openssl dgst -sha256 "$1" | awk '{ print $NF }'
  elif have digest; then digest -a sha256 "$1"
  elif have sha256; then sha256 -q "$1"
  elif have csum; then csum -h SHA256 "$1" | awk '{ print $1 }'
  else return 1
  fi
}
do_verify() {
  vd="${TMPDIR:-/tmp}/scriptix_verify.$$"
  mkdir "$vd" || { err "Cannot create $vd"; exit 3; }
  sed '1,/^#__SCRIPTIX_BODY__$/d' "$SX_SELF" > "$vd/body"
  got=$(sha_of "$vd/body" | tr 'ABCDEF' 'abcdef')
  rm -rf "$vd"
  if [ -z "$got" ]; then
    msg "Cannot verify: no SHA-256 tool found (sha256sum, shasum, openssl, digest, csum)."; exit 3
  fi
  if [ "$got" = "$SX_SHA256" ]; then
    msg "OK: the script matches its SHA-256 ($SX_SHA256)."
    msg "Compare this value with the one shown in the ScriptIX app."
    exit 0
  fi
  msg "FAILED: this script was changed after ScriptIX generated it."
  msg "  expected $SX_SHA256"
  msg "  actual   $got"
  exit 1
}

# ---- --selftest --------------------------------------------------------------------
# Proves, on THIS server and THIS shell, that every construct and tool the script
# relies on behaves as expected. Changes nothing outside a temp folder; no root.
st_ok=0; st_bad=0; st_warn=0
st() {  # st LABEL STATUS [optional]  (STATUS 0 = ok)
  if [ "$2" = 0 ]; then st_ok=$((st_ok + 1)); printf '  ok    %s\n' "$1"
  elif [ -n "$3" ]; then st_warn=$((st_warn + 1)); printf '  warn  %s\n' "$1"
  else st_bad=$((st_bad + 1)); printf '  FAIL  %s\n' "$1"
  fi
}
do_selftest() {
  WORK="${TMPDIR:-/tmp}/scriptix_selftest_$$"
  OF="$WORK/out"
  rm -rf "$WORK" 2>/dev/null
  mkdir "$WORK" || { err "Cannot create $WORK"; exit 3; }
  trap 'rm -rf "$WORK" 2>/dev/null' 0
  trap 'rm -rf "$WORK" 2>/dev/null; exit 4' INT TERM HUP
  st_sh=$(ps -p $$ -o comm= 2>/dev/null | awk 'NR == 1 { print $1 }')
  msg "ScriptIX $SX_VERSION selftest on $HOST: $OS $(uname -r 2>/dev/null) $(uname -v 2>/dev/null), shell ${st_sh:-unknown}, uid $(id -u 2>/dev/null)"
  msg ""
  msg "Required tools"
  for st_c in awk sed grep tr cut wc cat cp mv rm mkdir chmod chown ls ps kill sleep date id uname dirname; do
    have "$st_c"; st "$st_c" $?
  done
  msg ""
  msg "Shell features"
  st "arithmetic \$((...))" "$( [ $((7 * 6 + 1)) = 43 ]; printf '%s' $?)"
  st_x=abc.tar.gz
  [ "${st_x%%.*}" = abc ] && [ "${st_x#*.}" = tar.gz ] && [ "${st_x%.gz}" = abc.tar ] && [ "${#st_x}" = 10 ]; st "parameter expansion" $?
  [ "$(printf '%s-%d|%5s' a 5 b)" = "a-5|    b" ]; st "printf formats" $?
  [ "$(printf 'x\ty' | tr '\011' '_')" = x_y ]; st "printf escapes + tr octal" $?
  st_f() { return 3; }; st_f; [ $? = 3 ]; st "function return codes" $?
  case "a.b" in *.*) st "case patterns" 0 ;; *) st "case patterns" 1 ;; esac
  printf 'a\\b%sc d\n' "$TAB" > "$WORK/r"
  IFS="$TAB" read -r st_a st_b < "$WORK/r"
  IFS=$SX_IFS   # ksh88 may keep an assignment made in front of a builtin
  [ "$st_a" = 'a\b' ] && [ "$st_b" = 'c d' ]; st "read -r with IFS=TAB" $?
  ( exit 7 ) & wait $!; [ $? = 7 ]; st "background job + wait exit code" $?
  if ! false; then st "! negation" 0; else st "! negation" 1; fi
  cat > "$WORK/hd" <<EOF
h$st_x
EOF
  [ "$(cat "$WORK/hd")" = habc.tar.gz ]; st "here-document" $?
  msg ""
  msg "Text tools"
  [ "$(SX_T=MiXed awk 'BEGIN { print tolower(ENVIRON["SX_T"]) }')" = mixed ]; st "awk ENVIRON + tolower" $?
  [ "$(awk -v v='a b' 'BEGIN { n = split(v, p, " "); print n p[2] }')" = 2b ]; st "awk -v + split" $?
  [ "$(printf 'k = 1\n' | awk -F= '{ gsub(/[ \t]/, "", $2); print $2 }')" = 1 ]; st "awk -F + gsub" $?
  printf 'abc\nx-y\nTab\n' > "$WORK/g"
  grep -E '^a(b|z)c$' "$WORK/g" >/dev/null; st "grep -E" $?
  grep -x -F -e 'x-y' "$WORK/g" >/dev/null; st "grep -x -F -e" $?
  grep -i '^tab$' "$WORK/g" >/dev/null; st "grep -i" $?
  [ "$(grep -c '' "$WORK/g" | tr -d ' ')" = 3 ]; st "grep -c" $?
  [ "$(printf 'a \t b\n' | sed 's/[[:space:]][[:space:]]*/_/g')" = a_b ]; st "sed [[:space:]]" $?
  [ "$(printf 'PassWord=xyz\n' | REDACT=1 redact)" = 'PassWord=*****' ]; st "sed redaction" $?
  [ "$(printf 'abcdef\n' | cut -c2-4)" = bcd ]; st "cut -c" $?
  [ "$(wc -l < "$WORK/g" | tr -d ' ')" = 3 ]; st "wc -l" $?
  [ "$(printf '3\n1\n2\n' | sort | awk '{ s = s $0 } END { print s }')" = 123 ]; st "sort" $?
  printf 'a\n#__SCRIPTIX_BODY__\nb\n' > "$WORK/m"
  [ "$(sed '1,/^#__SCRIPTIX_BODY__$/d' "$WORK/m")" = b ]; st "sed address range (used by --verify)" $?
  msg ""
  msg "Files"
  mkdir -p "$WORK/a/b/c"; st "mkdir -p" $?
  mkdir "$WORK/lock" && ! mkdir "$WORK/lock" 2>/dev/null; st "mkdir as a lock" $?
  printf 'one\n' > "$WORK/f1"; chmod 640 "$WORK/f1"
  [ "$(fmode "$WORK/f1")" = 0640 ]; st "chmod + mode read back from ls -ld" $?
  cp -p "$WORK/f1" "$WORK/f2" && [ "$(fmode "$WORK/f2")" = 0640 ]; st "cp -p keeps the mode" $?
  printf 'two\n' > "$WORK/n"; replace_file "$WORK/f1" "$WORK/n"
  [ "$(cat "$WORK/f1")" = two ] && [ "$(fmode "$WORK/f1")" = 0640 ]; st "rewrite in place keeps the mode" $?
  [ -n "$(fowner_of "$WORK/f1")" ]; st "owner read back from ls -ld" $?
  have cmp && cmp -s "$WORK/f2" "$WORK/f2"; st "cmp -s" $? opt
  if have diff; then diff "$WORK/f1" "$WORK/f2" >/dev/null; [ $? = 1 ]; st "diff (dry-run previews)" $? opt; else st "diff (dry-run previews)" 1 opt; fi
  exists "$WORK/f1" && exists "$WORK/a" && ! exists "$WORK/none"; st "file tests" $?
  [ -w "$(pwd)" ]; st "current folder is writable (results go to $(pwd))" $? opt
  if [ -d /var/run ] && [ -w /var/run ]; then st "lock folder /var/run is writable" 0; else [ -w /tmp ]; st "lock folder /tmp is writable" $?; fi
  msg ""
  msg "Processes and time"
  kill -0 $$ 2>/dev/null; st "kill -0" $?
  [ -n "$(ps_list | awk -v p=$$ '$1 == p')" ]; st "ps lists PID + PPID (needed to stop timed-out commands)" $?
  case "$(now_s)" in ''|*[!0-9]*) st "date '+%H %M %S'" 1 ;; *) st "date '+%H %M %S'" 0 ;; esac
  case "$(id -u 2>/dev/null)" in ''|*[!0-9]*) st "id -u" 1 ;; *) st "id -u" 0 ;; esac
  [ "$HOST" != unknown ]; st "host name ($HOST)" $? opt
  run_cmd sh 0 'printf hello; exit 3'
  [ "$rc" = 3 ] && [ "$(cat "$OF")" = hello ] && [ "$TIMEDOUT" = 0 ]; st "run a command, capture output + exit code" $?
  st_t0=$(now_s)
  run_cmd sh 2 'sleep 9; printf late'
  st_t1=$(now_s); st_d=$((st_t1 - st_t0))
  [ "$TIMEDOUT" = 1 ] && [ "$st_d" -lt 8 ] && [ "$(cat "$OF")" != late ]; st "timeout stops a hung command (${st_d}s)" $?
  msg ""
  msg "Optional (only some features need these)"
  st_s=$(printf 'abc' > "$WORK/h"; sha_of "$WORK/h" | tr 'ABCDEF' 'abcdef')
  [ "$st_s" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]; st "SHA-256 tool (for --verify)" $? opt
  have bash; st "bash (only for rules marked shell: bash)" $? opt
  case "$OS" in
    Linux) have sysctl; st "sysctl" $? opt; { have systemctl || have chkconfig; }; st "systemctl or chkconfig (svc_disable)" $? opt ;;
    AIX) for st_c in lssrc stopsrc startsrc chsec lssec chuser lsuser no; do have "$st_c"; st "$st_c" $? opt; done ;;
    SunOS) have svcs; st "svcs/svcadm (svc_disable)" $? opt ;;
    FreeBSD|DragonFly) have sysrc; st "sysrc (svc_disable)" $? opt; have sysctl; st "sysctl" $? opt ;;
    OpenBSD) have rcctl; st "rcctl (svc_disable)" $? opt; have sysctl; st "sysctl" $? opt ;;
  esac
  msg ""
  if [ "$st_bad" = 0 ]; then st_r=PASS; else st_r=FAIL; fi
  msg "SELFTEST os=$OS shell=${st_sh:-unknown} ok=$st_ok warn=$st_warn fail=$st_bad result=$st_r"
  if [ "$st_bad" = 0 ]; then
    msg "This server can run ScriptIX scripts."
    exit 0
  fi
  msg "Fix the FAIL lines first (install the tool, or run with another shell: ksh, bash)."
  exit 1
}

# ---- --undo ------------------------------------------------------------------------
do_undo() {
  [ -f "$UNDO" ] || { err "Manifest not found: $UNDO"; exit 3; }
  UNDO_DIR=$(cd "$(dirname "$UNDO")" && pwd)
  need_root "Undo must run as root."
  take_lock || exit 3
  setup_out
  un_n=$(wc -l < "$UNDO" | tr -d ' ')
  say "ScriptIX $SX_VERSION undo on $HOST ($OS): $un_n recorded change(s) from $UNDO"
  if [ "$YES" = 0 ] && ! confirm "Restore them now?"; then say "Cancelled. Nothing was changed."; cleanup; exit 0; fi
  awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$UNDO" > "$WORK/undo.rev"
  un_ok=0; un_bad=0
  while IFS="$TAB" read -r u_kind u_a u_b; do
    IFS=$SX_IFS; u_rc=0
    case "$u_kind" in
      FILE)
        # the backup sits at <run folder>/backup<original path>; works even if the folder was moved
        [ -f "$u_b" ] || u_b="$UNDO_DIR/backup$u_a"
        cp -p "$u_b" "$u_a" || u_rc=1; say "restore file   $u_a" ;;
      NEWFILE) rm -f "$u_a" || u_rc=1; say "remove new     $u_a" ;;
      MODE) chmod "$u_b" "$u_a" || u_rc=1; say "restore mode   $u_a -> $u_b" ;;
      OWNER) chown "$u_b" "$u_a" || u_rc=1; say "restore owner  $u_a -> $u_b" ;;
      SYSCTL)
        if [ -n "$u_b" ]; then
          if [ "$OS" = Linux ]; then sysctl -w "$u_a=$u_b" >/dev/null || u_rc=1; else sysctl "$u_a=$u_b" >/dev/null || u_rc=1; fi
        fi
        say "restore sysctl $u_a = $u_b" ;;
      AIXNO) no -p -o "$u_a=$u_b" >/dev/null || u_rc=1; say "restore no     $u_a = $u_b" ;;
      USERATTR) chuser "$u_b" "$u_a" || u_rc=1; say "restore user   $u_a $u_b" ;;
      SVC)
        case "$u_b" in
          systemd/enabled*) systemctl enable "$u_a" || u_rc=1 ;;
          sysv/on*) chkconfig "$u_a" on || u_rc=1 ;;
          smf/online*|smf/degraded*|smf/maintenance*|smf/offline*) svcadm enable "$u_a" || u_rc=1 ;;
          rcctl/1/*) rcctl enable "$u_a" >/dev/null || u_rc=1 ;;
        esac
        case "$u_b" in
          */active) if [ "$OS" = AIX ]; then startsrc -s "$u_a" || u_rc=1; elif have systemctl; then systemctl start "$u_a" || u_rc=1; fi ;;
          sysv/*) service "$u_a" start >/dev/null 2>&1 ;;
          bsd/*/1) service "$u_a" onestart >/dev/null 2>&1 || u_rc=1 ;;
          rcctl/*/1) rcctl start "$u_a" >/dev/null 2>&1 || u_rc=1 ;;
        esac
        say "restore svc    $u_a ($u_b)" ;;
      *) continue ;;
    esac
    if [ "$u_rc" = 0 ]; then un_ok=$((un_ok + 1)); else un_bad=$((un_bad + 1)); say "   -> FAILED"; fi
  done < "$WORK/undo.rev"
  IFS=$SX_IFS
  say ""
  say "Undo finished: $un_ok restored, $un_bad failed. Log: $LOG"
  say "Reload or restart the services you changed (sshd, ...) if needed."
  cleanup
  trap - 0
  [ "$un_bad" -gt 0 ] && exit 1
  exit 0
}

# ============================================================================
# The commands (generated from your rules; every value is a single-quoted literal)
# ============================================================================
run_all() {
:
{{ITEMS}}
}

# ============================================================================
# Main
# ============================================================================
case "$ACTION" in
  verify) do_verify ;;
  selftest) do_selftest ;;
  list) run_all; exit 0 ;;
esac

trap on_signal INT TERM HUP
trap cleanup 0

[ "$ACTION" = undo ] && do_undo

if [ "$DRY" = 0 ] && [ "$NEEDROOT" = 1 ]; then
  need_root "Run this as root, or preview first with: sh $SX_SELF --dry-run"
fi
if [ "$DRY" = 0 ] && [ "$READONLY" = 0 ]; then
  take_lock || exit 3
fi
setup_out
printf '"schema_version","seq","id","title","severity","time","result","detail","rc","seconds","command","expected","output","mode","os","timeout","shell"\n' > "$CSV"

say "ScriptIX $SX_VERSION  |  $SX_KIND script  |  host $HOST ($OS)  |  user $(id -un 2>/dev/null)  |  $(date)"
if [ "$DRY" = 1 ]; then sx_m="DRY RUN (nothing is changed)"; else sx_m=RUN; fi
if [ "$STOP" = 1 ]; then sx_s=yes; else sx_s=no; fi
say "Mode: $sx_m   Stop at first failure: $sx_s   Timeout per command: ${TIMEOUT}s"
[ -n "$ONLY" ] && say "Only: $ONLY"
[ -n "$SKIP" ] && say "Skip: $SKIP"
say "Output: $OUT/"

if [ "$DRY" = 0 ] && [ "$YES" = 0 ]; then
  say ""
  if [ "$READONLY" = 1 ]; then
    say "This runs $SX_TOTAL check command(s) on $HOST. Checks should not change anything."
    sx_q="Run the checks?"
  else
    say "This runs $SX_TOTAL command(s) on $HOST that CHANGE the system ($SX_RISKY flagged as risky)."
    say "Files changed by ScriptIX helpers are backed up to $BAK first, and can be"
    say "restored with --undo. Other commands cannot be undone automatically."
    say "Tip: run --dry-run first, and keep a second admin session open."
    sx_q="Apply?"
  fi
  if ! confirm "$sx_q"; then
    printf 'Cancelled. Nothing was changed.\n'
    cleanup; rm -rf "$OUT"
    exit 0
  fi
fi

{{OVAL}}
run_all
finish
cleanup
trap - 0
[ "$INTERRUPTED" = 1 ] && exit 4
[ "$NFAIL" -gt 0 ] && exit 1
exit 0

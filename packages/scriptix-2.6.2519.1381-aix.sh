#!/bin/sh
# ScriptIX 2.6.0-20261124.230156 package for AIX 7.1 or newer, fileset scriptix.rte 2.6.2519.1381.
# AIX's own backup command turns the files in here into a real .bff for installp, smit or NIM.
#
#   sh THIS_FILE              make scriptix.rte.2.6.2519.1381.bff in this folder
#   sh THIS_FILE --install    make it and install it with installp
#   sh THIS_FILE --uninstall  remove the fileset (the results in /var/lib/scriptix stay)
#
# Or install the .bff later: installp -acgXd scriptix.rte.2.6.2519.1381.bff scriptix.rte

PATH=/usr/bin:/usr/sbin:/etc:/usr/ccs/bin:/bin:/sbin; export PATH
LC_ALL=C; LANG=C; export LC_ALL LANG
unset CDPATH ENV

fail() { printf 'scriptix package: %s\n' "$1" >&2; exit 1; }

MODE=build
case "$1" in
  '') ;;
  --install) MODE=install ;;
  --uninstall) MODE=uninstall ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  *) fail "unknown option: $1 (use --install or --uninstall)" ;;
esac

[ "$(uname -s)" = AIX ] || fail "this file is for AIX"
[ "$(id -u)" = 0 ] || fail "run this as root"
if [ "$MODE" = uninstall ]; then
  installp -u scriptix.rte
  exit $?
fi
for c in backup restore ar installp; do
  [ -x "/usr/sbin/$c" ] || [ -x "/usr/bin/$c" ] || [ -x "/usr/ccs/bin/$c" ] || fail "the $c command is missing"
done

START=$(pwd)
T="${TMPDIR:-/tmp}/scriptix_bff_$$"
umask 077
mkdir "$T" || fail "cannot create $T"
trap 'cd /; rm -rf "$T"' 0
trap 'exit 4' 1 2 15
umask 022
mkdir "$T/root" && cd "$T/root" || fail "cannot use $T"

# ---- the files ----------------------------------------------------------------
mkdir -p './usr/bin' || fail "mkdir /usr/bin"
mkdir -p './usr/share/man/man8' || fail "mkdir /usr/share/man/man8"
mkdir -p './usr/share/scriptix' || fail "mkdir /usr/share/scriptix"
mkdir -p './usr/share/scriptix/content' || fail "mkdir /usr/share/scriptix/content"
mkdir -p './usr/share/scriptix/lib' || fail "mkdir /usr/share/scriptix/lib"
mkdir -p './usr/share/scriptix/scripts' || fail "mkdir /usr/share/scriptix/scripts"
cat > './usr/bin/scriptix' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write ./usr/bin/scriptix"
#!/bin/sh
# scriptix 2.6.0-20261124.230156 - runs the ScriptIX scripts installed on this server.
# Strict POSIX sh: AIX 7.1+ ksh88, dash, bash, ksh93, mksh, busybox ash.

# ---- safe environment --------------------------------------------------------
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ -d /usr/xpg4/bin ] && PATH=/usr/xpg4/bin:$PATH
export PATH
LC_ALL=C; LANG=C; export LC_ALL LANG
unset CDPATH ENV BASH_ENV
IFS=$(printf ' \t\n.'); IFS=${IFS%.}
NL=$(printf '\n.'); NL=${NL%.}
unset PERL5LIB PERL5OPT PERLLIB PERL5DB
UMASK0=$(umask)
umask 077
ORIG=$(pwd 2>/dev/null) || ORIG=/

VERSION='2.6.0-20261124.230156'
LIB=/usr/share/scriptix/scripts
SCAPLIB=/usr/share/scriptix/lib
STATE=/var/lib/scriptix
RUNS=$STATE/runs
KEEP=30
TMPD=''; LOCKED=0; SSH_ON=0; OSCAP=0; SSH_FILE=''
CRONCMD='/usr/bin/scriptix scan -q'
OS=$(uname -s 2>/dev/null)

msg() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
die() { err "scriptix: $1"; leave "${2:-1}"; }
# exit; the oscap names (scriptix xccdf eval ...) have oscap's exit codes: 0 passed, 2 a rule failed, 1 error
leave() {
  if [ "$OSCAP" = 1 ]; then case "$1" in 0) exit 0 ;; 1) exit "${2:-2}" ;; *) exit 1 ;; esac; fi
  exit "$1"
}
# set at the top, not in a function: in ksh88 a function's own exit trap runs when the function ends
tidy() {
  [ "$SSH_ON" = 1 ] && ssh_end
  [ -n "$TMPD" ] && rm -rf "$TMPD"
  [ "$LOCKED" = 1 ] && rm -rf "$STATE/lock"
  return 0
}
trap 'tidy' 0
trap 'tidy; trap - 0; exit 4' 1 2 15
have() {
  for hv_d in /usr/bin /bin /usr/sbin /sbin; do
    if [ -f "$hv_d/$1" ] && [ -x "$hv_d/$1" ]; then return 0; fi
  done
  return 1
}

usage() {
  cat <<'EOF'
scriptix - run the ScriptIX scripts on this server, or on others over ssh

  scriptix list                     scripts on this server
  scriptix scan [NAME...] [-q]      run the check scripts (they change nothing)
  scriptix status                   last result of every script
  scriptix results [NAME] [--all]   failed rules of the last run (--all: every rule)
  scriptix diff [NAME]              what changed between the last two runs
  scriptix export [NAME] [--stamp]  print the last results file (CSV; --stamp: its time first)

 SCAP files (data stream, XCCDF, OVAL), as with oscap
  scriptix content                  the SCAP files on this server
  scriptix info [FILE]              what is in a file, with its profiles
  scriptix eval --profile P [FILE]  scan this server with it (no FILE: the one made for this system)
       --report F.html   --results F.xml   --results-arf F.xml   --csv F   files to write
       --tailoring-file F   --set NAME=VALUE   --rule ID   --skip-rule ID   --benchmark-id ID
       --remediate       fix what failed (it asks first, -y: no question), then scan again.
                         The fixes in a SCAP file have no undo: take a backup, try a test server first.
       -v   every command and its output            -q   only the last line
  scriptix add FILE.xml --profile P [--name N]   keep it as a check script, for scan, schedule and ssh
  scriptix report [NAME | RESULTS]  a web page of the last run (--html F, --results F, --results-arf F, --csv F)
  scriptix guide [FILE] --profile P [--out F.html]   the rules as a web page
  scriptix fix [FILE] --profile P [--type bash|ansible|...] [--results NAME|F] [--out F]
       --type script     a ScriptIX script of the fixes, with a log of each (preview lists them)
  scriptix tailor [FILE] --profile P [--select ID] [--unselect ID] [--set NAME=VALUE] --out F.xml
  scriptix validate FILE            find mistakes in a file
  scriptix xccdf eval | validate | generate guide, fix, report    the same, under the names oscap uses

  scriptix ssh [USER@]HOST...       run the check scripts on other servers (they need nothing installed)
       -c FILE --profile P           scan them with a SCAP file
       --out DIR  a report of each server in this folder
       -f FILE    servers from a file, one per line     -s NAME    only this script
       -i KEY     ssh key file                          -p PORT    ssh port (or HOST:PORT)
       --sudo     for a user that is not root           -q         only the summary
       --apply NAME   run a script that changes them (each asks first, -y: no question)
  scriptix servers                  last result of every server
       results, diff and export take  --host HOST  for one of them

  scriptix preview NAME             show what a script would change
  scriptix apply NAME [OPTIONS]     run a script that changes the server (it asks first)
  scriptix undo [MANIFEST]          put back what the last apply changed

  scriptix add FILE.sh              add a script made by ScriptIX (or a SCAP file, see above)
  scriptix remove NAME              remove an added script
  scriptix verify                   check that no script was changed
  scriptix selftest                 check that this server has every tool needed

  scriptix schedule daily HH:MM     scan every day
  scriptix schedule weekly DAY HH:MM   scan every week (DAY: mon ... sun)
  scriptix schedule off             stop the scheduled scan
  scriptix schedule                 show the schedule
  scriptix version

Run it as root. Results are kept in /var/lib/scriptix (the last 30 scans).
ssh asks for passwords itself. They are never stored.
Exit codes: 0 all passed, 1 a rule failed, 2 usage error, 3 cannot run.
Scanning needs only sh and awk. Reading a SCAP file also needs perl (AIX has it).
EOF
}

# ---- helpers -------------------------------------------------------------------
need_root() {
  [ "$(id -u 2>/dev/null)" = 0 ] || die "run this as root" 3
  mkdir -p "$STATE/scripts" "$STATE/runs" "$STATE/content" || die "cannot create $STATE" 3
  chmod 700 "$STATE" "$STATE/scripts" "$STATE/runs" "$STATE/content"
}
good_name() {
  case "$1" in
    ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}
# all_scripts : "NAME FILE" for every script, added ones first
all_scripts() {
  for as_d in "$STATE/scripts" "$LIB"; do
    [ -d "$as_d" ] || continue
    for as_f in "$as_d"/*.sh; do
      [ -f "$as_f" ] || continue
      as_n=${as_f##*/}; as_n=${as_n%.sh}; as_n=${as_n#scriptix_}
      good_name "$as_n" && printf '%s %s\n' "$as_n" "$as_f"
    done
  done
}
# find_script NAME : prints the file
find_script() {
  fs_n=${1#scriptix_}; fs_n=${fs_n%.sh}
  fs_f=$(all_scripts | awk -v n="$fs_n" '$1 == n { print $2; exit }')
  [ -n "$fs_f" ] || return 1
  printf '%s\n' "$fs_f"
}
# the first READONLY= line is the app's own; a later one could be part of a rule
is_check() { [ "$(sed -n 's/^READONLY=//p' "$1" | head -n 1)" = 1 ]; }
check_names() { all_scripts | while read cn_n cn_f; do is_check "$cn_f" && printf '%s\n' "$cn_n"; done; }
# runs NAME : run folders, oldest first (sorted by the time in the name)
runs() {
  [ -d "$RUNS/$1" ] || return 0
  ls "$RUNS/$1" | grep '^scriptix_' | grep -v '^scriptix_undo_' |
    sed -n 's/^\(.*_\([0-9]\{8\}_[0-9]\{6\}\)\)$/\2 \1/p' | sort | awk '{ print $2 }'
}
csv_of() { for co_f in "$1"/results_*.csv; do [ -f "$co_f" ] && printf '%s\n' "$co_f"; done | head -n 1; }
# last_csv NAME [N] : the Nth newest results file (1 = newest)
last_csv() {
  lc_n=${2:-1}
  for lc_d in $(runs "$1" | awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }'); do
    lc_f=$(csv_of "$RUNS/$1/$lc_d")
    [ -n "$lc_f" ] || continue
    if [ "$lc_n" -le 1 ]; then printf '%s\n' "$lc_f"; return 0; fi
    lc_n=$((lc_n - 1))
  done
  return 1
}
# the first N fields of a CSV line whose fields are all in quotes
CSVAWK='
function fields(s, n,   i, c, v, p) {
  for (i = 1; i <= n; i++) {
    v = ""
    s = substr(s, 2)
    while ((p = index(s, "\"")) > 0) {
      v = v substr(s, 1, p - 1)
      c = substr(s, p + 1, 1)
      if (c == "\"") { v = v "\""; s = substr(s, p + 2) } else { s = substr(s, p + 2); break }
    }
    if (p == 0) { v = v s; s = "" }
    F[i] = v
  }
}'
# counts FILE : "passed failed skipped"
counts() {
  awk "$CSVAWK"' NR > 1 { fields($0, 7); if (F[7] == "PASS") p++; else if (F[7] == "FAIL") f++; else s++ }
    END { print p + 0, f + 0, s + 0 }' "$1"
}
when_of() { printf '%s\n' "$1" | sed 's/^.*_\([0-9]\{4\}\)\([0-9][0-9]\)\([0-9][0-9]\)_\([0-9][0-9]\)\([0-9][0-9]\)[0-9][0-9]\.csv$/\1-\2-\3 \4:\5/'; }
pick_name() {   # the script a command is about: the given one, or the only (first) check script
  if [ -n "$1" ]; then
    pn_n=${1#scriptix_}; pn_n=${pn_n%.sh}
    good_name "$pn_n" || die "bad script name: $1" 2
  elif [ "$RUNS" != "$STATE/runs" ]; then
    # another server: the first check script that was run there
    pn_n=''
    for pn_i in $(check_names) $(ls "$RUNS"); do
      if [ -z "$pn_n" ] && last_csv "$pn_i" > /dev/null; then pn_n=$pn_i; fi
    done
    [ -n "$pn_n" ] || die "$pn_h has no results" 3
  else
    pn_n=$(check_names | head -n 1)
    [ -n "$pn_n" ] || die "no check script is installed (scriptix add FILE.sh)" 3
  fi
}
# use_host HOST : look at the results of another server
use_host() {
  SSH_PORT=''
  split_target "$1" || die "bad server name: $1" 2
  pn_h=$1; RUNS=$STATE/hosts/$tg_dir
  [ -d "$RUNS" ] || die "no results of $1 yet (see: scriptix servers)" 3
}
lock() {
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    lk_p=$(cat "$STATE/lock/pid" 2>/dev/null)
    case "$lk_p" in *[!0-9]*) lk_p='' ;; esac
    if [ -n "$lk_p" ] && kill -0 "$lk_p" 2>/dev/null; then die "another scan is running (pid $lk_p)" 3; fi
    [ -n "$lk_p" ] || sleep 2   # perhaps it was made just now
    lk_q=$(cat "$STATE/lock/pid" 2>/dev/null)
    [ "$lk_p" = "$lk_q" ] || die "another scan is running" 3
    rm -rf "$STATE/lock"
    mkdir "$STATE/lock" 2>/dev/null || die "cannot lock $STATE" 3
  fi
  LOCKED=1
  printf '%s\n' $$ > "$STATE/lock/pid"
}

# ---- commands ------------------------------------------------------------------
do_list() {
  need_root
  ls_any=0
  while read ls_n ls_f; do
    [ -n "$ls_n" ] || continue
    ls_any=1
    if is_check "$ls_f"; then ls_k='check  (changes nothing)'; else ls_k='apply  (changes the server)'; fi
    case "$ls_f" in "$LIB"/*) ls_w=package ;; *) ls_w=added ;; esac
    ls_t=$(sed -n 's/^SX_TOTAL=//p' "$ls_f" | head -n 1)
    printf '%-24s %-28s %5s commands  %s\n' "$ls_n" "$ls_k" "$ls_t" "$ls_w"
  done <<EOF
$(all_scripts)
EOF
  [ "$ls_any" = 1 ] || msg "No scripts yet. Add one with: scriptix add FILE.sh"
}

do_scan() {
  need_root
  sc_q=0; sc_names=''
  for sc_a in "$@"; do
    case "$sc_a" in
      -q|--quiet) sc_q=1 ;;
      -*) die "unknown option: $sc_a" 2 ;;
      *) sc_a=${sc_a#scriptix_}; sc_a=${sc_a%.sh}
         good_name "$sc_a" || die "bad script name: $sc_a" 2
         sc_names="$sc_names $sc_a" ;;
    esac
  done
  [ -n "$sc_names" ] || sc_names=$(check_names)
  [ -n "$sc_names" ] || die "no check script is installed (scriptix add FILE.sh)" 3
  lock
  sc_rc=0
  for sc_n in $sc_names; do
    sc_f=$(find_script "$sc_n") || { err "scriptix: no script named $sc_n"; sc_rc=3; continue; }
    is_check "$sc_f" || { err "scriptix: $sc_n changes the server. Use: scriptix apply $sc_n"; sc_rc=3; continue; }
    if ! sh "$sc_f" --verify >/dev/null 2>&1; then
      err "scriptix: $sc_n was changed, or it cannot be verified. Not run. See: scriptix verify"
      sc_rc=3; continue
    fi
    mkdir -p "$STATE/runs/$sc_n" && cd "$STATE/runs/$sc_n" || { sc_rc=3; continue; }
    # run folders are named by the second: never two in the same one
    case "$(runs "$sc_n" | tail -n 1)" in *_$(date +%Y%m%d_%H%M%S)) sleep 1 ;; esac
    sc_old=$(last_csv "$sc_n")
    if [ "$sc_q" = 1 ]; then sh "$sc_f" -y >/dev/null 2>&1 </dev/null; sc_r=$?
    else sh "$sc_f" -y </dev/null; sc_r=$?; fi
    sc_new=$(last_csv "$sc_n")
    cd /
    if [ "$sc_new" = "$sc_old" ] || [ -z "$sc_new" ]; then
      err "scriptix: $sc_n did not finish (exit code $sc_r)"; sc_rc=3; continue
    fi
    sc_c=$(counts "$sc_new")
    sc_line=$(printf '%s\n' "$sc_c" | awk -v n="$sc_n" '{ printf "%s: %d passed, %d failed, %d skipped", n, $1, $2, $3 }')
    [ "$sc_q" = 1 ] || msg "$sc_line"
    have logger && logger -t scriptix -p auth.notice "$sc_line" 2>/dev/null
    case "$sc_r" in
      0) ;;
      1) [ "$sc_rc" = 0 ] && sc_rc=1 ;;
      *) sc_rc=3 ;;
    esac
    prune "$sc_n"
  done
  exit "$sc_rc"
}

# prune NAME : keep the newest scans. Only folders of check scripts are ever removed.
prune() {
  pr_t=$(runs "$1" | wc -l | tr -d ' ')
  [ "$pr_t" -gt "$KEEP" ] || return 0
  for pr_d in $(runs "$1" | head -n "$((pr_t - KEEP))"); do
    case "$pr_d" in
      scriptix_*[!A-Za-z0-9._-]*) ;;
      scriptix_check_*|scriptix_oscap_*) rm -rf "$RUNS/$1/$pr_d" ;;
    esac
  done
}

do_status() {
  need_root
  printf '%-36s %-17s %7s %7s %8s\n' SCRIPT 'LAST RUN' PASSED FAILED SKIPPED
  all_scripts | while read st_n st_f; do
    st_c=$(last_csv "$st_n")
    if [ -z "$st_c" ]; then printf '%-36s %s\n' "$st_n" "never"; continue; fi
    set -- $(counts "$st_c")
    printf '%-36s %-17s %7s %7s %8s\n' "$st_n" "$(when_of "$st_c")" "$1" "$2" "$3"
  done
  # scans with a SCAP file
  for st_d in "$STATE"/runs/*; do
    st_n=${st_d##*/}
    case "$st_n" in *_fix|undo|'*') continue ;; esac
    find_script "$st_n" > /dev/null && continue
    st_c=$(last_csv "$st_n") || continue
    set -- $(counts "$st_c")
    printf '%-36s %-17s %7s %7s %8s\n' "$st_n" "$(when_of "$st_c")" "$1" "$2" "$3"
  done
  msg ""
  show_schedule
}

do_results() {
  need_root
  rs_all=0; rs_n=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) rs_all=1 ;;
      --host) [ $# -ge 2 ] || die "--host needs a server" 2; use_host "$2"; shift ;;
      -*) die "unknown option: $1" 2 ;;
      *) rs_n=$1 ;;
    esac
    shift
  done
  pick_name "$rs_n"
  rs_f=$(last_csv "$pn_n") || die "$pn_n was not run yet" 3
  msg "${pn_h:+$pn_h, }$pn_n, $(when_of "$rs_f")"
  awk -v all="$rs_all" "$CSVAWK"' NR > 1 { fields($0, 8)
      if (F[7] == "PASS") p++; else if (F[7] == "FAIL") f++; else s++
      if (all == 1 || F[7] == "FAIL") printf "%-8s %-14s %-40s %s\n", F[7], F[8], F[3], F[4] }
    END { printf "%d passed, %d failed, %d skipped\n", p, f, s }' "$rs_f"
  msg "Full results: $rs_f"
}

do_diff() {
  need_root
  df_n=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) [ $# -ge 2 ] || die "--host needs a server" 2; use_host "$2"; shift ;;
      -*) die "unknown option: $1" 2 ;;
      *) df_n=$1 ;;
    esac
    shift
  done
  pick_name "$df_n"
  df_new=$(last_csv "$pn_n") || die "$pn_n was not run yet" 3
  df_old=$(last_csv "$pn_n" 2) || die "$pn_n was run only once" 3
  msg "${pn_h:+$pn_h, }$pn_n: $(when_of "$df_old")  ->  $(when_of "$df_new")"
  awk "$CSVAWK"' FNR == 1 { file++; next }
    { fields($0, 7) }
    file == 1 { old[F[3]] = F[7]; next }
    { seen[F[3]] = 1
      if (!(F[3] in old)) { printf "%-8s -> %-8s %-40s %s\n", "(new)", F[7], F[3], F[4]; n++ }
      else if (old[F[3]] != F[7]) { printf "%-8s -> %-8s %-40s %s\n", old[F[3]], F[7], F[3], F[4]; n++ } }
    END { for (k in old) if (!(k in seen)) { printf "%-8s -> %-8s %s\n", old[k], "(gone)", k; n++ }
      printf "%d difference(s)\n", n }' "$df_old" "$df_new"
}

do_export() {
  need_root
  ex_n=''; ex_s=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stamp) ex_s=1 ;;
      --host) [ $# -ge 2 ] || die "--host needs a server" 2; use_host "$2"; shift ;;
      -*) die "unknown option: $1" 2 ;;
      *) ex_n=$1 ;;
    esac
    shift
  done
  pick_name "$ex_n"
  ex_f=$(last_csv "$pn_n") || die "$pn_n was not run yet" 3
  [ "$ex_s" = 1 ] && printf '%s\n' "$ex_f" | sed 's/^.*_\([0-9]\{8\}_[0-9]\{6\}\)\.csv$/#scriptix \1/'
  cat "$ex_f"
}

do_apply() {
  need_root
  [ $# -ge 1 ] || die "which script? See: scriptix list" 2
  ap_f=$(find_script "$1") || die "no script named $1" 2
  ap_n=${1#scriptix_}; ap_n=${ap_n%.sh}
  shift
  sh "$ap_f" --verify >/dev/null 2>&1 || die "$ap_n was changed, or it cannot be verified. Not run. See: scriptix verify" 3
  mkdir -p "$STATE/runs/$ap_n" && cd "$STATE/runs/$ap_n" || exit 3
  exec sh "$ap_f" "$@"
}

do_undo() {
  need_root
  un_m=''; un_y=''
  for un_a in "$@"; do
    case "$un_a" in -y|--yes) un_y=--yes ;; -*) die "unknown option: $un_a" 2 ;; *) un_m=$un_a ;; esac
  done
  if [ -z "$un_m" ]; then
    # newest change list that was not undone yet
    un_m=$(for un_f in "$STATE"/runs/*/scriptix_*/changes_*.manifest; do
        [ -f "$un_f" ] && [ ! -f "$un_f.undone" ] && printf '%s\n' "$un_f"
      done | sed -n 's/^\(.*_\([0-9]\{8\}_[0-9]\{6\}\)\.manifest\)$/\2 \1/p' | sort | tail -n 1 | awk '{ print $2 }')
    [ -n "$un_m" ] || die "nothing to undo" 3
  fi
  [ -f "$un_m" ] || die "no such file: $un_m" 2
  case "$un_m" in
    "$STATE"/runs/*) un_n=${un_m#$STATE/runs/}; un_n=${un_n%%/*} ;;
    *) un_n='' ;;
  esac
  un_s=''
  [ -n "$un_n" ] && un_s=$(find_script "$un_n")
  [ -n "$un_s" ] || un_s=$(all_scripts | awk 'NR == 1 { print $2 }')
  [ -n "$un_s" ] || die "no script is installed to run the undo with" 3
  msg "Undo: $un_m"
  if [ -z "$un_y" ]; then
    printf 'Put these changes back? [y/N] '
    read un_r || un_r=n
    case "$un_r" in y|Y|yes|YES) un_y=--yes ;; *) msg "Cancelled. Nothing was changed."; exit 0 ;; esac
  fi
  un_d=${un_n:-undo}
  mkdir -p "$STATE/runs/$un_d" && cd "$STATE/runs/$un_d" || exit 3
  sh "$un_s" --undo "$un_m" --yes; un_r=$?
  [ "$un_r" = 0 ] && : > "$un_m.undone"
  exit "$un_r"
}

do_add() {
  for ad_a in "$@"; do case "$ad_a" in *.xml|--profile*) do_add_scap "$@"; return ;; esac; done
  need_root
  [ $# -eq 1 ] || die "scriptix add FILE.sh" 2
  [ -f "$1" ] || die "no such file: $1" 2
  case "$1" in -*) set -- "./$1" ;; esac
  ad_n=${1##*/}; ad_n=${ad_n%.sh}; ad_n=${ad_n#scriptix_}
  good_name "$ad_n" || die "the file name may only have letters, digits, . _ -" 2
  [ -f "$LIB/scriptix_$ad_n.sh" ] || [ -f "$LIB/$ad_n.sh" ] && die "$ad_n comes with the package. Give the file another name." 2
  ad_t="$STATE/scripts/.add.$$"
  cp "$1" "$ad_t" || die "cannot copy $1" 3
  if ! grep '^#__SCRIPTIX_BODY__$' "$ad_t" >/dev/null 2>&1; then rm -f "$ad_t"; die "$1 is not a ScriptIX script" 2; fi
  if ! sh "$ad_t" --verify >/dev/null 2>&1; then rm -f "$ad_t"; die "$1 was changed, or it cannot be verified" 3; fi
  chmod 700 "$ad_t" && mv -f "$ad_t" "$STATE/scripts/$ad_n.sh" || { rm -f "$ad_t"; die "cannot add $1" 3; }
  msg "Added: $ad_n"
}

do_remove() {
  need_root
  [ $# -eq 1 ] || die "scriptix remove NAME" 2
  rm_n=${1#scriptix_}; rm_n=${rm_n%.sh}
  good_name "$rm_n" || die "bad script name: $1" 2
  if [ -f "$STATE/scripts/$rm_n.sh" ]; then rm -f "$STATE/scripts/$rm_n.sh" && msg "Removed: $rm_n (its results are kept)"; rm -rf "$STATE/content/$rm_n" "$STATE/content/$rm_n.ref"; return; fi
  find_script "$rm_n" >/dev/null && die "$rm_n comes with the package" 2
  die "no script named $rm_n" 2
}

do_verify() {
  need_root
  vf_bad=0
  while read vf_n vf_f; do
    [ -n "$vf_n" ] || continue
    if vf_o=$(sh "$vf_f" --verify 2>&1 </dev/null); then printf 'ok       %s\n' "$vf_n"
    else printf 'CHANGED  %s  (%s)\n' "$vf_n" "$(printf '%s\n' "$vf_o" | tail -n 1)"; vf_bad=1; fi
  done <<EOF
$(all_scripts)
EOF
  exit "$vf_bad"
}

do_selftest() {
  need_root
  sf_f=$(all_scripts | awk 'NR == 1 { print $2 }')
  [ -n "$sf_f" ] || die "no script is installed (scriptix add FILE.sh)" 3
  cd /tmp || exit 3
  exec sh "$sf_f" --selftest
}

# ---- SCAP files -------------------------------------------------------------------
# scap.pl reads the file and writes a check script; the check script does the scan.
CONTENT="/usr/share/scriptix/content /usr/share/xml/scap/ssg/content"

need_perl() {
  [ -f "$SCAPLIB/scap.pl" ] || die "$SCAPLIB/scap.pl is missing (install the package again)" 3
  for np_f in /usr/bin/perl /usr/opt/perl5/bin/perl /opt/freeware/bin/perl /usr/local/bin/perl; do
    if [ -x "$np_f" ]; then PERL=$np_f; return 0; fi
  done
  die "SCAP files need perl, which is missing here. On Red Hat: dnf install perl-interpreter. On Debian and Ubuntu: apt install perl-base" 3
}
# what the user gets is written with the user's own umask
scap() { (umask "$UMASK0"; exec "$PERL" "$SCAPLIB/scap.pl" "$@"); }
abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$ORIG/$1" ;; esac; }
quoted() { printf '%s\n' "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"; }

# add_load KIND VALUE : an option of scap.pl that says what to load; also kept for later reports
add_load() {
  case "$2" in *"$NL"*) die "a line break in the value of --$1" 2 ;; esac
  SP="$SP --$1 $(quoted "$2")"
  SREF="$SREF$1 $2$NL"
}
in_file() { [ -f "$1" ] || die "no such file: $1" 2; abs "$1"; }
out_file() {
  [ "$1" = - ] && { msg -; return; }
  of_f=$(abs "$1")
  [ -d "${of_f%/*}" ] || [ "${of_f%/*}" = '' ] || die "no such folder: ${of_f%/*}" 2
  [ -d "$of_f" ] && die "$1 is a folder" 2
  printf '%s\n' "$of_f"
}
scap_opts() {
  SP=''; SREF=''; SEL=''; SF=''; O_HTML=''; O_XCCDF=''; O_ARF=''; O_CSV=''; O_OUT=''; O_TYPE=bash; O_IN=''; O_NAME=''; O_HOST=''; O_CONTENT=''; O_SELF=0
  REMEDIATE=0; QUIET=0; FULL=0; YES=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) sp_o=${1%%=*}; sp_v=${1#*=}; shift; set -- "$sp_o" "$sp_v" "$@" ;;
    esac
    case "$1" in
      --profile|--tailoring-file|--tailoring|--benchmark-id|--benchmark|--set|--rule|--skip-rule|--results|--xccdf|--results-arf|--arf|--report|--html|--csv|\
      --out|--output|--type|--fix-type|--result-id|--name|--host|--content|--select|--unselect|--title|--verbose|--verbose-log-file)
        [ $# -ge 2 ] || die "$1 needs a value" 2 ;;
    esac
    case "$1" in
      --profile) [ "$2" = '(default)' ] || add_load profile "$2"; shift ;;
      --tailoring-file|--tailoring) sp_f=$(in_file "$2") || exit $?; add_load tailoring "$sp_f"; shift ;;
      --benchmark-id|--benchmark) add_load benchmark "$2"; shift ;;
      --set) add_load set "$2"; shift ;;
      --rule|--skip-rule|--select|--unselect|--title) SEL="$SEL $1 $(quoted "$2")"; shift ;;
      --results|--xccdf)
        if [ "$SCMD" = fix ]; then O_IN=$2; else O_XCCDF=$(out_file "$2") || exit $?; fi; shift ;;
      --results-arf|--arf) O_ARF=$(out_file "$2") || exit $?; shift ;;
      --report|--html) O_HTML=$(out_file "$2") || exit $?; shift ;;
      --csv) O_CSV=$(out_file "$2") || exit $?; shift ;;
      --out|--output) O_OUT=$(out_file "$2") || exit $?; shift ;;
      --type|--fix-type) O_TYPE=$2; shift ;;
      --result-id) O_SELF=1; shift ;;   # oscap: the file holds the results as well
      --name) O_NAME=$2; good_name "$2" || die "the name may only have letters, digits, . _ -" 2; shift ;;
      --host) O_HOST=$2; shift ;;
      --content) O_CONTENT=$2; shift ;;
      --remediate) REMEDIATE=1 ;;
      -y|--yes) YES=-y ;;
      -q|--quiet) QUIET=1 ;;
      -v|--full) FULL=1 ;;
      # options of oscap that change nothing here
      --verbose|--verbose-log-file) shift ;;
      --progress|--progress-full|--skip-valid|--skip-validation|--without-syschar|--thin-results|--oval-results|--check-engine-results) ;;
      --fetch-remote-resources) err "scriptix: nothing is downloaded, --fetch-remote-resources is ignored" ;;
      --) ;;
      -*) die "unknown option: $1" 2 ;;
      *) [ -z "$SF" ] || die "one file at a time ($SF, $1)" 2; SF=$1 ;;
    esac
    shift
  done
}
# the names this system has in the SCAP Security Guide
os_names() {
  on_f=/etc/os-release; [ -r "$on_f" ] || on_f=/usr/lib/os-release
  if [ -r "$on_f" ]; then
    on_i=$(sed -n 's/^ID=//p' "$on_f" | tr -d "\"'" | head -n 1)
    on_v=$(sed -n 's/^VERSION_ID=//p' "$on_f" | tr -d "\"'" | head -n 1)
    on_m=${on_v%%.*}; on_a=$(printf '%s\n' "$on_v" | tr -d .)
    case "$on_i" in
      sles|sled) msg "sle$on_m" ;;
      centos) msg "cs$on_m centos$on_m" ;;
      rocky) msg "rl$on_m rocky$on_m" ;;
      amzn) msg "al$on_a" ;;
      opensuse*) msg "opensuse opensuse$on_m" ;;
      fedora) msg fedora ;;
      *) msg "$on_i$on_a $on_i$on_m" ;;
    esac
  elif [ "$OS" = AIX ]; then msg "aix$(uname -v)$(uname -r) aix$(uname -v)"
  fi
}
own_content() {   # the SCAP file made for this system
  for oc_n in $(os_names); do
    case "$oc_n" in *[!a-z0-9]*) continue ;; esac
    for oc_d in $CONTENT; do
      for oc_f in "$oc_d/ssg-$oc_n-ds.xml" "$oc_d/ssg-$oc_n-xccdf.xml" "$oc_d/$oc_n.xml"; do
        if [ -f "$oc_f" ]; then printf '%s\n' "$oc_f"; return 0; fi
      done
    done
  done
  # the only file that came with the package
  oc_l=$(ls /usr/share/scriptix/content/*.xml 2>/dev/null)
  case "$oc_l" in ''|*"$NL"*) return 1 ;; esac
  printf '%s\n' "$oc_l"
}
# find_content NAME : sets fc_f
find_content() {
  if [ -n "$1" ]; then
    fc_f=$(abs "$1")
    [ -f "$fc_f" ] && return 0
    case "$1" in */*) die "no such file: $1" 2 ;; esac
    fc_f=$(for fc_d in $CONTENT; do
        for fc_x in "$fc_d/$1" "$fc_d/$1.xml" "$fc_d/ssg-$1-ds.xml"; do [ -f "$fc_x" ] && printf '%s\n' "$fc_x"; done
      done | head -n 1)
    [ -n "$fc_f" ] || die "no such file: $1 (see: scriptix content)" 2
  else
    fc_f=$(own_content) || die "which SCAP file? None was found for this system (see: scriptix content)" 2
  fi
}
do_content() {
  ct_o=$(own_content)
  ct_l=$(for ct_d in $CONTENT; do ls -d "$ct_d"/*.xml 2>/dev/null; done | grep -v -e '-oval\.xml$' -e '-ocil\.xml$' -e '-cpe-dictionary\.xml$')
  if [ -z "$ct_l" ]; then
    msg "No SCAP files here. Copy one to this server, or install the SCAP Security Guide:"
    msg "  Red Hat: dnf install scap-security-guide    SUSE: zypper install scap-security-guide"
    msg "  Debian and Ubuntu: apt install ssg-debderived ssg-debian"
    return 0
  fi
  printf '%s\n' "$ct_l" | while read -r ct_f; do
    if [ "$ct_f" = "$ct_o" ]; then msg "$ct_f   <- used when no file is named"; else msg "$ct_f"; fi
  done
}
make_tmp() {
  TMPD=$STATE/.tmp.$$
  rm -rf "$TMPD"; mkdir "$TMPD" || die "cannot create $TMPD" 3
}
# compile FILE OUT : makes the check script. Sets cp_name, cp_total, cp_title
compile() {
  cp_f=$1; cp_o=$2
  add_load file "$cp_f"
  eval "set -- $SP $SEL"
  cp_l=$(scap compile --lib "$SCAPLIB" --out "$cp_o" "$@") || leave 3
  cp_name=$(printf '%s\n' "$cp_l" | cut -f1)
  cp_total=$(printf '%s\n' "$cp_l" | cut -f2)
  cp_title=$(printf '%s\n' "$cp_l" | cut -f3)
  good_name "$cp_name" || die "bad name: $cp_name" 3
}
# eval_run NAME SCRIPT : one scan. Sets er_rc and er_csv
eval_run() {
  mkdir -p "$STATE/runs/$1" && cd "$STATE/runs/$1" || die "cannot create $STATE/runs/$1" 3
  case "$(runs "$1" | tail -n 1)" in *_$(date +%Y%m%d_%H%M%S)) sleep 1 ;; esac
  er_old=$(last_csv "$1")
  if [ "$QUIET" = 1 ]; then sh "$2" -y > /dev/null 2>&1 < /dev/null; er_rc=$?
  elif [ "$FULL" = 1 ]; then sh "$2" -y < /dev/null; er_rc=$?
  else
    { sh "$2" -y < /dev/null; printf '%s\n' $? > "$TMPD/rc"; } | awk '
      /^=== \[[0-9]+\/[0-9]+\] / { id = $3; t = $0; sub(/^=== \[[0-9\/]+\] +[^ ]+ +/, "", t); next }
      /^   -> / { r = $2; d = $3; gsub(/[()]/, "", d); if (d ~ /^rc=/) d = ""; printf "%-8s %-15s %-44s %s\n", r, d, id, t }'
    er_rc=$(cat "$TMPD/rc")
  fi
  er_csv=$(last_csv "$1")
  cd /
  if [ "$er_csv" = "$er_old" ] || [ -z "$er_csv" ]; then die "the scan did not finish (exit code $er_rc)" 3; fi
  printf '%s' "$SREF" > "${er_csv%/*}/scap.ref"
  prune "$1"
}
# write_reports CSV : the files that were asked for. Sets wr_score
write_reports() {
  eval "set -- $SP"
  [ -z "$O_HTML" ] || set -- "$@" --html "$O_HTML"
  [ -z "$O_XCCDF" ] || set -- "$@" --xccdf "$O_XCCDF"
  [ -z "$O_ARF" ] || set -- "$@" --arf "$O_ARF"
  wr_score=$(scap report --csv "$WR_CSV" "$@") || return 1
  [ -z "$O_CSV" ] || (umask "$UMASK0"; cat "$WR_CSV" > "$O_CSV") || return 1
  for wr_f in "$O_HTML" "$O_XCCDF" "$O_ARF" "$O_CSV"; do
    [ -z "$wr_f" ] || [ "$QUIET" = 1 ] || msg "Wrote $wr_f"
  done
  return 0
}
no_stdout() { for ns_f in "$O_HTML" "$O_XCCDF" "$O_ARF" "$O_CSV"; do [ "$ns_f" = - ] && die "give a file name, not -" 2; done; return 0; }

do_eval() {
  SCMD=eval; scap_opts "$@"
  need_root; need_perl; no_stdout
  if [ "$REMEDIATE" = 1 ] && [ -z "$YES" ]; then
    [ -t 0 ] || die "there is no terminal to ask on (add -y to fix without a question)" 3
  fi
  find_content "$SF"
  make_tmp
  compile "$fc_f" "$TMPD/check.sh"
  lock
  if [ "$QUIET" = 0 ]; then
    msg "File:    $cp_f"
    msg "Profile: $cp_title"
    msg "Rules:   $cp_total"
    msg ""
  fi
  eval_run "$cp_name" "$TMPD/check.sh"
  if [ "$REMEDIATE" = 1 ] && [ "$er_rc" = 1 ]; then
    eval "set -- $SP"
    if ev_n=$(scap fix --type script --csv "$er_csv" --lib "$SCAPLIB" --out "$TMPD/fix.sh" "$@"); then
      msg ""
      msg "Fixes for $ev_n failed rules. They come from the SCAP file and cannot be undone by ScriptIX: have a backup."
      mkdir -p "$STATE/runs/${cp_name}_fix" && cd "$STATE/runs/${cp_name}_fix" || die "cannot create a folder for the fixes" 3
      # shellcheck disable=SC2086
      sh "$TMPD/fix.sh" $YES; ev_r=$?
      cd /
      case "$ev_r" in
        0|1) msg ""; msg "Scanning again:"; eval_run "$cp_name" "$TMPD/check.sh" ;;
        *) err "scriptix: the fixes did not finish (exit code $ev_r)" ;;
      esac
    fi
  fi
  WR_CSV=$er_csv; wr_score=''
  if [ "$QUIET" = 0 ] || [ -n "$O_HTML$O_XCCDF$O_ARF$O_CSV" ]; then
    write_reports || { err "scriptix: the reports could not be written"; er_rc=3; }
  fi
  set -- $(counts "$er_csv")
  ev_l="$cp_name: $1 passed, $2 failed, $3 skipped"
  have logger && logger -t scriptix -p auth.notice "$ev_l" 2>/dev/null
  msg ""
  msg "$ev_l${wr_score:+, score $wr_score of 100}"
  if [ "$1$2" = 00 ]; then msg "No rule could be checked. Is this file made for this system?"; fi
  [ "$QUIET" = 1 ] || msg "See them again: scriptix results $cp_name      As a web page: scriptix report $cp_name"
  case "$er_rc" in 0|1) ;; *) er_rc=3 ;; esac
  leave "$er_rc"
}
do_info() { SCMD=info; scap_opts "$@"; need_perl; find_content "$SF"; add_load file "$fc_f"; eval "set -- $SP"; scap info "$@"; }
do_validate() { SCMD=validate; scap_opts "$@"; need_perl; find_content "$SF"; scap validate --file "$fc_f"; leave $? 1; }
do_guide() {
  SCMD=guide; scap_opts "$@"; need_perl; find_content "$SF"; add_load file "$fc_f"
  eval "set -- $SP"
  scap guide --out "${O_OUT:--}" "$@" || leave 3
  [ -z "$O_OUT" ] || msg "Wrote $O_OUT" >&2
}
do_tailor() {
  SCMD=tailor; scap_opts "$@"; need_perl; find_content "$SF"; add_load file "$fc_f"
  eval "set -- $SP $SEL"
  scap tailor --out "${O_OUT:--}" "$@" || leave 3
  [ -z "$O_OUT" ] || msg "Wrote $O_OUT" >&2
}
do_fix() {
  SCMD=fix; scap_opts "$@"; need_perl
  fx_c=''
  [ "$O_SELF" = 0 ] || O_IN=$SF
  if [ -n "$O_IN" ]; then   # a results file, or the last run of a name
    if [ -f "$O_IN" ]; then fx_c=$(abs "$O_IN")
    else
      need_root; pick_name "$O_IN"
      fx_c=$(last_csv "$pn_n") || die "$O_IN is not a file, and was not run yet" 2
      [ -n "$SP$SF" ] || [ ! -f "${fx_c%/*}/scap.ref" ] || read_ref "${fx_c%/*}/scap.ref"
    fi
  fi
  if [ -z "$RF_OK" ]; then find_content "$SF"; add_load file "$fc_f"; fi
  [ "$O_TYPE" != script ] || [ -n "$O_OUT" ] || O_OUT=$ORIG/scriptix_fix.sh
  [ "$O_TYPE$O_OUT" != script- ] || die "give a file name, not -" 2
  eval "set -- $SP"
  [ -z "$fx_c" ] || set -- "$@" --csv "$fx_c"
  fx_n=''
  if [ "$O_TYPE" = script ]; then fx_n=$(scap fix --type script --lib "$SCAPLIB" --out "$O_OUT" "$@") || leave 3
  else scap fix --type "$O_TYPE" --out "${O_OUT:--}" "$@" || leave 3; fi
  [ -z "$O_OUT" ] || [ "$O_OUT" = - ] || msg "Wrote $O_OUT${fx_n:+ ($fx_n fixes). Use it with: scriptix add $O_OUT}" >&2
}
# read_ref FILE : what was scanned, out of a run folder
RF_OK=''
read_ref() {
  while read -r rf_k rf_v; do
    case "$rf_k" in
      file) [ -f "$rf_v" ] || { SP=''; RF_OK=''; return 0; }; RF_OK=1; SP="$SP --file $(quoted "$rf_v")" ;;
      tailoring) [ -f "$rf_v" ] && SP="$SP --tailoring $(quoted "$rf_v")" ;;
      profile|set|benchmark) SP="$SP --$rf_k $(quoted "$rf_v")" ;;
    esac
  done < "$1"
  # a tailored profile cannot be found without its file
  if grep '^tailoring ' "$1" > /dev/null 2>&1 && [ ! -f "$(sed -n 's/^tailoring //p' "$1" | head -n 1)" ]; then SP=''; RF_OK=''; fi
  return 0
}
ref_of() {   # ref_of CSV NAME : reads what was scanned, when it is known
  if [ -f "${1%/*}/scap.ref" ]; then read_ref "${1%/*}/scap.ref"
  elif [ -f "$STATE/content/$2.ref" ]; then read_ref "$STATE/content/$2.ref"
  elif ro_f=$(own_content); then SP="--file $(quoted "$ro_f")"; fi   # used only when it has these rules
}
do_report() {
  SCMD=report; scap_opts "$@"; need_perl
  if [ -n "$SF" ] && [ -f "$SF" ]; then
    WR_CSV=$(abs "$SF"); rp_n=${SF##*/}; rp_n=${rp_n%.*}
  else
    need_root
    [ -z "$O_HOST" ] || use_host "$O_HOST"
    pick_name "$SF"
    WR_CSV=$(last_csv "$pn_n") || die "$pn_n was not run yet" 3
    rp_n=scriptix_${O_HOST:+${tg_dir}_}$pn_n
    [ -n "$O_CONTENT" ] || ref_of "$WR_CSV" "$pn_n"
  fi
  if [ -n "$O_CONTENT" ]; then find_content "$O_CONTENT"; add_load file "$fc_f"; fi
  rp_d=$ORIG/$rp_n.html
  [ "$OSCAP" = 1 ] && rp_d=-
  if [ -z "$O_HTML$O_XCCDF$O_ARF$O_CSV" ]; then O_HTML=${O_OUT:-$rp_d}; fi
  if [ "$O_HTML" = - ]; then eval "set -- $SP"; scap report --csv "$WR_CSV" --html - "$@"; return; fi
  no_stdout
  write_reports || leave 3
}
# add FILE.xml : its checks become a check script of this server
do_add_scap() {
  SCMD=add; scap_opts "$@"
  need_root; need_perl; find_content "$SF"
  make_tmp
  compile "$fc_f" "$TMPD/check.sh"
  as_n=${O_NAME:-$cp_name}
  [ -f "$LIB/scriptix_$as_n.sh" ] || [ -f "$LIB/$as_n.sh" ] && die "$as_n comes with the package. Use --name." 2
  # reports need the file later: a copy, unless it belongs to a package
  mkdir "$TMPD/c" || exit 3
  as_r=''
  while read -r as_k as_v; do
    case "$as_k $as_v" in
      'file /usr/share/'*|'tailoring /usr/share/'*) ;;
      'file '*) cp "$as_v" "$TMPD/c/content.xml" || exit 3; as_v=$STATE/content/$as_n/${as_v##*/}; mv "$TMPD/c/content.xml" "$TMPD/c/${as_v##*/}" || exit 3 ;;
      'tailoring '*) cp "$as_v" "$TMPD/c/tailoring.scriptix.xml" || exit 3; as_v=$STATE/content/$as_n/tailoring.scriptix.xml ;;
    esac
    [ -z "$as_k" ] || as_r="$as_r$as_k $as_v$NL"
  done <<EOF
$SREF
EOF
  rm -rf "$STATE/content/$as_n"
  mv "$TMPD/c" "$STATE/content/$as_n" && printf '%s' "$as_r" > "$STATE/content/$as_n.ref" &&
    chmod 700 "$TMPD/check.sh" && mv -f "$TMPD/check.sh" "$STATE/scripts/$as_n.sh" || die "cannot add $SF" 3
  rmdir "$STATE/content/$as_n" 2>/dev/null
  msg "Added: $as_n  ($cp_title, $cp_total rules)"
  msg "Run it: scriptix scan $as_n"
}
# the names oscap uses for the same things
do_oscap() {
  OSCAP=1
  case "$1 $2" in
    'xccdf eval'|'oval eval'|'ds eval') shift 2; do_eval "$@" ;;
    'xccdf validate'|'oval validate'|'ds sds-validate') shift 2; do_validate "$@" ;;
    'xccdf generate')
      case "$3" in
        guide) shift 3; do_guide "$@" ;;
        fix) shift 3; do_fix "$@" ;;
        report) shift 3; [ $# -gt 0 ] || die "which results file?" 2
          do_report "$@" ;;
        *) die "xccdf generate guide, fix or report" 2 ;;
      esac ;;
    *) die "known here: xccdf eval, xccdf validate, xccdf generate guide|fix|report, oval eval" 2 ;;
  esac
}
# ---- other servers, over ssh --------------------------------------------------------
# The script is sent, run and removed again: the other server needs only sh and sshd.
# ssh itself asks for passwords, on the terminal. They never pass through here.

# split_target [USER@]HOST[:PORT] : sets tg_user, tg_host, tg_port and tg_dir (the folder for its results)
split_target() {
  tg_host=$1; tg_user=''; tg_port=$SSH_PORT
  case "$tg_host" in
    *@*) tg_user=${tg_host%@*}; tg_host=${tg_host##*@}
      case "$tg_user" in ''|[!A-Za-z_]*|*[!A-Za-z0-9._-]*) return 1 ;; esac ;;
  esac
  case "$tg_host" in *:*) tg_port=${tg_host##*:}; tg_host=${tg_host%:*}; [ -n "$tg_port" ] || return 1 ;; esac
  case "$tg_host" in [!A-Za-z0-9]*) return 1 ;; esac
  good_name "$tg_host" || return 1
  good_port "$tg_port" || return 1
  tg_dir=$tg_host
  [ -n "$tg_port" ] && tg_dir=${tg_host}_$tg_port
  return 0
}
good_port() {
  case "$1" in '') return 0 ;; *[!0-9]*|??????*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
# ssh_do MODE [COMMAND] : run ssh for the current target. MODE: tty, plain, open or close (the shared connection)
ssh_do() {
  so_m=$1; so_c=$2
  set -- -a -x -o ConnectTimeout=15 -o ServerAliveInterval=30
  [ -n "$tg_port" ] && set -- "$@" -p "$tg_port"
  [ -n "$SSH_KEY" ] && set -- "$@" -i "$SSH_KEY"
  [ -n "$tg_user" ] && set -- "$@" -l "$tg_user"
  [ "$SSH_TTY_OK" = 1 ] || set -- "$@" -o BatchMode=yes
  [ -n "$SSH_MUX" ] && set -- "$@" -o "ControlPath=$SSH_MUX"
  case "$so_m" in
    open) ssh "$@" -T -f -N -o ControlMaster=yes -o ControlPersist=600 "$tg_host" < /dev/null > /dev/null ;;
    close) ssh "$@" -O exit "$tg_host" < /dev/null > /dev/null 2>&1 ;;
    tty) ssh "$@" -t "$tg_host" "sh -c '$so_c'" < /dev/tty ;;
    *) ssh "$@" -T "$tg_host" "sh -c '$so_c'" ;;
  esac
}
ssh_end() {
  [ "$SSH_OPEN" = 1 ] && ssh_do close
  SSH_OPEN=0
  rm -f "$STATE/.ssh.$$" "$STATE/.ssh.$$.rc"
}
# ssh_one NAME FILE : run one script on the current target. Sets so_state, and so_csv when results came back.
ssh_one() {
  s1_n=$1; s1_f=$2; so_csv=''; so_state=failed
  s1_kind=$(sed -n "s/^SX_KIND='\([a-z0-9-]*\)'.*/\1/p" "$s1_f" | head -n 1)
  RUNS=$STATE/hosts/$tg_dir
  while :; do
    s1_ts=$(date +%Y%m%d_%H%M%S)
    s1_run=$RUNS/$s1_n/scriptix_${s1_kind}_${tg_dir}_$s1_ts
    [ -d "$s1_run" ] || break
    sleep 1
  done
  mkdir -p "$s1_run" || { so_state="cannot create $s1_run"; return 3; }
  s1_d=scriptix_${s1_ts}_$$
  s1_p=scriptix_$s1_n.sh
  s1_part=$s1_run/part
  s1_log=$s1_run/run_${tg_dir}_$s1_ts.txt
  s1_pre="umask 077; PATH=\$PATH:/usr/local/bin:/opt/freeware/bin; export PATH; "
  s1_put="mkdir $s1_d && cd $s1_d || exit 96; cat > $s1_p && sh $s1_p --verify 1>&2 || { cd; rm -rf $s1_d; exit 97; }; "
  s1_get="find scriptix_* -name results_\\*.csv -exec cat {} \\;"
  s1_y=-y
  [ -n "$SSH_APPLY" ] && s1_y=$SSH_YES
  s1_rc=0
  if [ "$SSH_ASKS" = 1 ]; then
    # a question or sudo's password needs a terminal, so this takes three steps
    s1_s=''
    [ "$SSH_SUDO" = 1 ] && s1_s='sudo '
    s1_clean=''
    [ -n "$SSH_APPLY" ] || s1_clean="${s1_s}rm -rf scriptix_*; "
    ssh_do plain "$s1_pre$s1_put" < "$s1_f"; s1_rc=$?
    if [ "$s1_rc" = 0 ]; then
      ssh_do tty "${s1_pre}cd $s1_d || exit 96; ${s1_s}sh $s1_p $s1_y; r=\$?; ${s1_s}$s1_get > out.csv; ${s1_clean}exit \$r"; s1_rc=$?
      if [ -n "$SSH_APPLY" ]; then s1_end="rm -f $s1_d/out.csv"; else s1_end="rm -rf $s1_d"; fi
      ssh_do plain "cat $s1_d/out.csv; $s1_end" < /dev/null > "$s1_part"
    fi
  else
    s1_s=''
    [ "$SSH_SUDO" = 1 ] && s1_s='sudo -n '
    s1_end=''
    [ -n "$SSH_APPLY" ] || s1_end="${s1_s}rm -rf scriptix_*; cd; rm -rf $s1_d; "
    s1_c="$s1_pre$s1_put${s1_s}sh $s1_p $s1_y 1>&2 < /dev/null; r=\$?; $s1_s$s1_get; ${s1_end}exit \$r"
    if [ "$SSH_QUIET" = 1 ]; then ssh_do plain "$s1_c" < "$s1_f" > "$s1_part" 2> "$s1_log"; s1_rc=$?
    else
      { ssh_do plain "$s1_c" < "$s1_f" > "$s1_part"; printf '%s\n' $? > "$STATE/.ssh.$$.rc"; } 2>&1 | tee "$s1_log"
      s1_rc=$(cat "$STATE/.ssh.$$.rc")
    fi
  fi
  # what another server sends is not trusted: no control characters, and nothing before the first line of the results
  if [ -s "$s1_part" ]; then
    tr -d '\000-\011\013-\037\177' < "$s1_part" | sed -n '/^"schema_version","seq",/,$p' > "$s1_part.2"
    if [ -s "$s1_part.2" ]; then
      so_csv=$s1_run/results_${tg_dir}_$s1_ts.csv
      mv "$s1_part.2" "$so_csv"
    fi
  fi
  rm -f "$s1_part" "$s1_part.2"
  if [ -z "$so_csv" ]; then
    case "$s1_rc" in
      255) so_state='no connection' ;;
      96) so_state='cannot write in the home folder there' ;;
      97) so_state='the script did not arrive whole, or cannot be verified there' ;;
      0) [ -n "$SSH_APPLY" ] && so_state='cancelled' ;;
      *) so_state="no results (exit code $s1_rc)" ;;
    esac
    [ "$SSH_QUIET" = 1 ] && [ -s "$s1_log" ] && tail -n 3 "$s1_log" >&2
    rm -rf "$s1_run"
    [ "$so_state" = cancelled ] && return 0
    return 3
  fi
  so_state=ok
  if [ -n "$SSH_APPLY" ]; then
    msg ""
    msg "The log, the backups and the list of changes stay on $tg_host, in ~$tg_user/$s1_d"
    msg "To put everything back, there as root: cd ~$tg_user/$s1_d && sh $s1_p --undo scriptix_${s1_kind}_*/changes_*.manifest"
  fi
  [ -n "$SSH_FILE" ] && printf '%s' "$SREF" > "$s1_run/scap.ref"
  if [ -n "$SSH_OUT" ]; then
    # shellcheck disable=SC2034
    ( [ -n "$SSH_FILE" ] || { SP=''; ref_of "$so_csv" "$s1_n"; }
      QUIET=1; WR_CSV=$so_csv; O_CSV=''; O_ARF=''; O_HTML=$SSH_OUT/${tg_dir}_$s1_n.html; O_XCCDF=$SSH_OUT/${tg_dir}_$s1_n.xml
      write_reports && msg "Wrote $O_HTML and .xml" ) || err "scriptix: the report of $tg_dir could not be written"
  fi
  prune "$s1_n"
  case "$s1_rc" in 0|1) return "$s1_rc" ;; esac
  so_state="not finished (exit code $s1_rc)"
  return 3
}

ssh_script() { if [ -n "$SSH_FILE" ]; then printf '%s\n' "$SSH_FILE"; else find_script "$1"; fi; }

do_ssh() {
  need_root
  SSH_PORT=''; SSH_KEY=''; SSH_SUDO=0; SSH_QUIET=0; SSH_APPLY=''; SSH_YES=''; SSH_MUX=''; SSH_OPEN=0; SSH_ASKS=0; SSH_TTY_OK=0
  dh_names=''; dh_hosts=''; dh_cont=''; SSH_OUT=''; SP=''; SREF=''; SEL=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) dh_o=${1%%=*}; dh_v=${1#*=}; shift; set -- "$dh_o" "$dh_v" "$@" ;;
    esac
    case "$1" in
      -p|-i|-f|-s|--apply|-c|--content|--profile|--tailoring-file|--tailoring|--benchmark-id|--set|--rule|--skip-rule|--out) [ $# -ge 2 ] || die "$1 needs a value" 2 ;;
    esac
    case "$1" in
      -p) SSH_PORT=$2; [ -n "$2" ] && good_port "$2" || die "bad port: $2" 2; shift ;;
      -i) SSH_KEY=$2; [ -f "$2" ] || die "no such key file: $2" 2; shift ;;
      -f) [ -f "$2" ] || die "no such file: $2" 2
        dh_hosts="$dh_hosts $(sed 's/#.*//' "$2" | tr -d '\015' | awk 'NF { print $1 }')"; shift ;;
      -s) dh_n=${2#scriptix_}; dh_n=${dh_n%.sh}; good_name "$dh_n" || die "bad script name: $2" 2
        dh_names="$dh_names $dh_n"; shift ;;
      --apply) dh_n=${2#scriptix_}; dh_n=${dh_n%.sh}; good_name "$dh_n" || die "bad script name: $2" 2
        SSH_APPLY=$dh_n; shift ;;
      -c|--content) dh_cont=$2; [ -n "$2" ] || die "which SCAP file?" 2; shift ;;
      --profile) add_load profile "$2"; shift ;;
      --tailoring-file|--tailoring) dh_v=$(in_file "$2") || exit $?; add_load tailoring "$dh_v"; shift ;;
      --benchmark-id) add_load benchmark "$2"; shift ;;
      --set) add_load set "$2"; shift ;;
      --rule|--skip-rule) SEL="$SEL $1 $(quoted "$2")"; shift ;;
      --out) SSH_OUT=$(abs "$2"); shift ;;
      --sudo) SSH_SUDO=1 ;;
      -y|--yes) SSH_YES=-y ;;
      -q|--quiet) SSH_QUIET=1 ;;
      -*) die "unknown option: $1" 2 ;;
      *) case "$1" in *[!A-Za-z0-9._@:-]*) die "bad server name: $1 (use [USER@]HOST[:PORT])" 2 ;; esac
        dh_hosts="$dh_hosts $1" ;;
    esac
    shift
  done
  set -f   # words from here on are names, never patterns
  set -- $dh_hosts
  set +f
  [ $# -gt 0 ] || die "which server? scriptix ssh [USER@]HOST[:PORT]..." 2
  for dh_h in "$@"; do split_target "$dh_h" || die "bad server name: $dh_h (use [USER@]HOST[:PORT])" 2; done
  if [ -n "$SSH_APPLY" ]; then
    [ -z "$dh_names" ] || die "use -s or --apply, not both" 2
    dh_names=$SSH_APPLY
  fi
  if [ -n "$SSH_OUT" ]; then
    [ -z "$SSH_APPLY" ] || die "--out is for check scripts" 2
    need_perl
    (umask "$UMASK0"; mkdir -p "$SSH_OUT") || die "cannot create $SSH_OUT" 3
  fi
  if [ -n "$dh_cont" ]; then
    [ -z "$dh_names" ] || die "use -c, -s or --apply, only one of them" 2
    need_perl
    find_content "$dh_cont"
    make_tmp
    compile "$fc_f" "$TMPD/check.sh"
    SSH_FILE=$TMPD/check.sh
    dh_names=$cp_name
  else
    [ -z "$SP$SEL" ] || die "--profile and the like need a SCAP file: -c FILE" 2
  fi
  [ -n "$dh_names" ] || dh_names=$(check_names)
  [ -n "$dh_names" ] || die "no check script is installed (scriptix add FILE.sh)" 3
  for dh_n in $dh_names; do
    dh_f=$(ssh_script "$dh_n") || die "no script named $dh_n" 2
    if is_check "$dh_f"; then
      [ -z "$SSH_APPLY" ] || die "$dh_n only checks. Use: scriptix ssh -s $dh_n" 2
    else
      [ -n "$SSH_APPLY" ] || die "$dh_n changes the server. Use: scriptix ssh --apply $dh_n" 2
    fi
    sh "$dh_f" --verify > /dev/null 2>&1 || die "$dh_n was changed, or it cannot be verified. Not sent. See: scriptix verify" 3
  done
  have ssh || die "the ssh command is missing on this server" 3
  (: < /dev/tty) 2>/dev/null && SSH_TTY_OK=1
  [ -n "$SSH_APPLY" ] && [ -z "$SSH_YES" ] && SSH_ASKS=1
  [ "$SSH_SUDO" = 1 ] && [ "$SSH_TTY_OK" = 1 ] && SSH_ASKS=1
  [ "$SSH_ASKS" = 1 ] && [ "$SSH_TTY_OK" = 0 ] && die "there is no terminal to ask on (add -y to apply without a question)" 3
  # one shared connection per server, so a password is asked for once
  ssh -G -o ControlMaster=yes -o ControlPersist=600 localhost > /dev/null 2>&1 < /dev/null && SSH_MUX=$STATE/.cm.$$
  : > "$STATE/.ssh.$$"
  SSH_ON=1
  dh_rc=0; dh_i=0
  for dh_h in "$@"; do
    dh_i=$((dh_i + 1))
    split_target "$dh_h"
    [ "$SSH_QUIET" = 1 ] || { msg ""; msg "==== $dh_h  ($dh_i of $#)"; }
    if [ -n "$SSH_MUX" ]; then
      if ssh_do open; then SSH_OPEN=1
      else
        printf '%-24s %-18s %s\n' "$tg_dir" - 'no connection' >> "$STATE/.ssh.$$"
        dh_rc=3; continue
      fi
    fi
    for dh_n in $dh_names; do
      ssh_one "$dh_n" "$(ssh_script "$dh_n")"; dh_r=$?
      if [ -n "$so_csv" ]; then
        set -f; dh_c=$(counts "$so_csv"); set +f
        printf '%s\n' "$dh_c" | awk -v h="$tg_dir" -v n="$dh_n" -v s="$so_state" '{ printf "%-24s %-18s %7d %7d %8d  %s\n", h, n, $1, $2, $3, (s == "ok" ? "" : s) }' >> "$STATE/.ssh.$$"
        have logger && logger -t scriptix -p auth.notice "$tg_dir $dh_n: $dh_c (passed failed skipped)" 2>/dev/null
      else
        printf '%-24s %-18s %s\n' "$tg_dir" "$dh_n" "$so_state" >> "$STATE/.ssh.$$"
      fi
      case "$dh_r" in
        0) ;;
        1) [ "$dh_rc" = 0 ] && dh_rc=1 ;;
        *) dh_rc=3 ;;
      esac
    done
    [ "$SSH_OPEN" = 1 ] && ssh_do close
    SSH_OPEN=0
  done
  msg ""
  printf '%-24s %-18s %7s %7s %8s\n' SERVER SCRIPT PASSED FAILED SKIPPED
  cat "$STATE/.ssh.$$"
  [ "$SSH_QUIET" = 1 ] || { msg ""; msg "What failed on one of them:  scriptix results --host HOST"; }
  exit "$dh_rc"
}

# the servers that were scanned over ssh
do_servers() {
  need_root
  sv_any=0
  for sv_d in "$STATE"/hosts/*/*; do
    [ -d "$sv_d" ] || continue
    sv_n=${sv_d##*/}; RUNS=${sv_d%/*}
    sv_c=$(last_csv "$sv_n") || continue
    [ "$sv_any" = 1 ] || printf '%-24s %-18s %-17s %7s %7s %8s\n' SERVER SCRIPT 'LAST RUN' PASSED FAILED SKIPPED
    sv_any=1
    set -- $(counts "$sv_c")
    printf '%-24s %-18s %-17s %7s %7s %8s\n' "${RUNS##*/}" "$sv_n" "$(when_of "$sv_c")" "$1" "$2" "$3"
  done
  [ "$sv_any" = 1 ] || msg "No servers yet. Scan one with: scriptix ssh [USER@]HOST"
}

# ---- schedule --------------------------------------------------------------------
CROND=/etc/cron.d/scriptix
UNIT=/etc/systemd/system/scriptix
# where the schedule goes on this system: cron.d, systemd or crontab
sched_kind() {
  if [ "$OS" = Linux ]; then
    if [ -d /etc/cron.d ] && { have cron || have crond; }; then msg cron.d; return; fi
    if have systemctl && [ -d /run/systemd/system ]; then msg systemd; return; fi
  fi
  if have crontab; then msg crontab; else msg none; fi
}
# root's crontab without our line, into FILE. Fails rather than lose somebody's entries.
other_cron() {
  if crontab -l > "$1.all" 2>/dev/null; then :
  else
    for oc_f in /var/spool/cron/crontabs/root /var/spool/cron/root /var/cron/tabs/root; do
      if [ -s "$oc_f" ]; then rm -f "$1.all"; err "scriptix: cannot read root's crontab, so it was left alone"; return 1; fi
    done
    : > "$1.all"
  fi
  # Vixie cron prints three comment lines of its own that must not pile up
  awk -v c="$CRONCMD" 'NR <= 3 && /^# (DO NOT EDIT THIS FILE|\(.* installed on |\(Cron version)/ { next } index($0, c) == 0' "$1.all" > "$1"
  rm -f "$1.all"
}
sched_clear() {
  [ -f "$CROND" ] && rm -f "$CROND"
  if [ -f "$UNIT.timer" ]; then
    have systemctl && systemctl disable --now scriptix.timer >/dev/null 2>&1
    rm -f "$UNIT.timer" "$UNIT.service"
    have systemctl && systemctl daemon-reload >/dev/null 2>&1
  fi
  if have crontab && crontab -l 2>/dev/null | grep "$CRONCMD" >/dev/null 2>&1; then
    sl_t="$STATE/.cron.$$"
    other_cron "$sl_t" || return 1
    crontab "$sl_t"; sl_r=$?
    rm -f "$sl_t"
    return "$sl_r"
  fi
  return 0
}
show_schedule() {
  if [ -f "$CROND" ]; then sh_l=$(grep "$CRONCMD" "$CROND")
  elif [ -f "$UNIT.timer" ]; then sh_l=$(sed -n 's/^OnCalendar=//p' "$UNIT.timer")
  else sh_l=$(crontab -l 2>/dev/null | grep "$CRONCMD"); fi
  [ -n "$sh_l" ] || { msg "Scheduled scan: off"; return 0; }
  case "$sh_l" in
    *"$CRONCMD"*) printf '%s\n' "$sh_l" | awk '{ split("sun mon tue wed thu fri sat", d, " ")
        printf "Scheduled scan: %s at %02d:%02d\n", ($5 == "*" ? "every day" : "every " d[$5 + 1]), $2, $1 }' ;;
    *) msg "Scheduled scan: $sh_l" ;;
  esac
}
do_schedule() {
  need_root
  case "$1" in
    '') show_schedule; return 0 ;;
    off) sched_clear || exit 3; msg "Scheduled scan: off"; return 0 ;;
    daily) sd_t=$2; sd_d='*'; sd_s='*-*-*' ;;
    weekly)
      sd_t=$3
      case "$2" in
        sun) sd_d=0; sd_s='Sun *-*-*' ;; mon) sd_d=1; sd_s='Mon *-*-*' ;; tue) sd_d=2; sd_s='Tue *-*-*' ;;
        wed) sd_d=3; sd_s='Wed *-*-*' ;; thu) sd_d=4; sd_s='Thu *-*-*' ;; fri) sd_d=5; sd_s='Fri *-*-*' ;;
        sat) sd_d=6; sd_s='Sat *-*-*' ;; *) die "the day must be one of: mon tue wed thu fri sat sun" 2 ;;
      esac ;;
    *) die "scriptix schedule [daily HH:MM | weekly DAY HH:MM | off]" 2 ;;
  esac
  case "$sd_t" in
    [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
    *) die "the time must look like 02:30" 2 ;;
  esac
  sd_h=${sd_t%:*}; sd_m=${sd_t#*:}
  # no leading zeros: some crons read them badly
  case "$sd_h" in 0?) sd_h=${sd_h#0} ;; esac
  case "$sd_m" in 0?) sd_m=${sd_m#0} ;; esac
  [ -n "$(check_names)" ] || die "no check script is installed (scriptix add FILE.sh)" 3
  sd_k=$(sched_kind)
  [ "$sd_k" = none ] && die "this server has no cron and no systemd" 3
  sched_clear || exit 3
  case "$sd_k" in
    cron.d)
      { printf '# made by: scriptix schedule\nSHELL=/bin/sh\n'
        printf '%s %s * * %s root %s >/dev/null 2>&1\n' "$sd_m" "$sd_h" "$sd_d" "$CRONCMD"; } > "$CROND.$$" &&
        chmod 644 "$CROND.$$" && mv -f "$CROND.$$" "$CROND" || { rm -f "$CROND.$$"; die "cannot write $CROND" 3; } ;;
    systemd)
      printf '[Unit]\nDescription=ScriptIX scan\n\n[Service]\nType=oneshot\nExecStart=%s\nSuccessExitStatus=1\n' "$CRONCMD" > "$UNIT.service" &&
        printf '[Unit]\nDescription=ScriptIX scan\n\n[Timer]\nOnCalendar=%s %s:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' "$sd_s" "$sd_t" > "$UNIT.timer" &&
        chmod 644 "$UNIT.service" "$UNIT.timer" && systemctl daemon-reload && systemctl enable --now scriptix.timer >/dev/null 2>&1 ||
        die "systemd did not accept the timer" 3 ;;
    crontab)
      sd_f="$STATE/.cron.$$"
      other_cron "$sd_f" || exit 3
      printf '%s %s * * %s %s >/dev/null 2>&1\n' "$sd_m" "$sd_h" "$sd_d" "$CRONCMD" >> "$sd_f"
      crontab "$sd_f" || { rm -f "$sd_f"; die "crontab did not accept the entry" 3; }
      rm -f "$sd_f" ;;
  esac
  show_schedule
}

# ---- main ------------------------------------------------------------------------
[ $# -gt 0 ] || { usage; exit 2; }
sx_c=$1; shift
case "$sx_c" in
  list) do_list ;;
  scan) do_scan "$@" ;;
  status) do_status ;;
  results) do_results "$@" ;;
  diff) do_diff "$@" ;;
  export) do_export "$@" ;;
  ssh) do_ssh "$@" ;;
  content) do_content ;;
  info) do_info "$@" ;;
  eval) do_eval "$@" ;;
  report) do_report "$@" ;;
  guide) do_guide "$@" ;;
  fix) do_fix "$@" ;;
  tailor) do_tailor "$@" ;;
  validate) do_validate "$@" ;;
  xccdf|oval|ds) do_oscap "$sx_c" "$@" ;;
  servers) do_servers ;;
  preview) [ $# -ge 1 ] || die "which script? See: scriptix list" 2
    sx_n=$1; shift; do_apply "$sx_n" --dry-run "$@" ;;
  apply) do_apply "$@" ;;
  undo) do_undo "$@" ;;
  add) do_add "$@" ;;
  remove) do_remove "$@" ;;
  verify) do_verify ;;
  selftest) do_selftest ;;
  schedule) do_schedule "$1" "$2" "$3" ;;
  version|--version) msg "scriptix $VERSION" ;;
  help|-h|--help) usage ;;
  *) err "scriptix: unknown command: $sx_c"; err "Run: scriptix help"; exit 2 ;;
esac
SCRIPTIX_END_OF_FILE
chmod 755 './usr/bin/scriptix' || fail "chmod ./usr/bin/scriptix"
cat > './usr/share/man/man8/scriptix.8' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write ./usr/share/man/man8/scriptix.8"
.TH SCRIPTIX 8
.SH NAME
scriptix \- run the ScriptIX scripts installed on this server
.SH SYNOPSIS
.B scriptix
.I command
[options]
.SH DESCRIPTION
Scans this server, or others over ssh, with SCAP files (data streams, XCCDF, OVAL) or with the check scripts made in
ScriptIX. Keeps the results, shows what changed, and makes reports and fixes.
Scanning needs sh and awk. Reading a SCAP file also needs perl.
Run
.B scriptix help
for the list of commands.
.SH EXAMPLES
.nf
scriptix info FILE.xml
scriptix eval \-\-profile cis_level1_server \-\-report report.html FILE.xml
scriptix add FILE.xml \-\-profile cis_level1_server \-\-name cis
scriptix ssh root@web1
scriptix schedule daily 02:30
.fi
.SH FILES
.TP
.I /usr/share/scriptix/content
SCAP files from the package, or put there by you
.TP
.I /usr/share/scriptix/scripts
the scripts from the package
.TP
.I /var/lib/scriptix/scripts
added scripts
.TP
.I /var/lib/scriptix/runs
results, logs and backups. They stay when the package is removed.
.TP
.I /var/lib/scriptix/hosts
results of other servers (scriptix ssh)
SCRIPTIX_END_OF_FILE
chmod 644 './usr/share/man/man8/scriptix.8' || fail "chmod ./usr/share/man/man8/scriptix.8"
chmod 755 './usr/share/scriptix'
chmod 755 './usr/share/scriptix/content'
chmod 755 './usr/share/scriptix/lib'
cat > './usr/share/scriptix/lib/oval.awk' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write ./usr/share/scriptix/lib/oval.awk"
# ScriptIX OVAL engine. Plain POSIX awk (AIX awk, mawk, gawk, busybox, BWK awk): evaluates one
# compiled check on this server. Read-only. An answer it can't give is never reported as a pass.
#   awk -v W=WORKDIR -v SYS=uname -f oval.awk CHECKFILE
# Exit: 0 pass, 1 fail, 250 not applicable, 251 not checked, 252 error, 253 unknown.

# ---------------------------------------------------------------- helpers
function unesc(s,   o, i, c) {
  if (index(s, "\\") == 0) return s
  o = ""
  while ((i = index(s, "\\")) > 0) {
    c = substr(s, i + 1, 1)
    if (c == "n") c = "\n"; else if (c == "t") c = "\t"; else if (c == "r") c = "\r"
    o = o substr(s, 1, i - 1) c
    s = substr(s, i + 2)
  }
  return o s
}
function sq(s,   o, i) {   # single quotes for sh
  o = "'"
  while ((i = index(s, "'")) > 0) { o = o substr(s, 1, i - 1) "'\\''"; s = substr(s, i + 1) }
  return o s "'"
}
function oneline(s) { gsub(/[\n\r\t]/, " ", s); return substr(s, 1, 110) }
function dirpart(p,   i) { i = lastslash(p); if (i <= 1) return "/"; return substr(p, 1, i - 1) }
function basepart(p) { return substr(p, lastslash(p) + 1) }
function lastslash(p,   i) { for (i = length(p); i > 0; i--) if (substr(p, i, 1) == "/") return i; return 0 }
function joinpath(d, f) { if (d == "/" || substr(d, length(d), 1) == "/") return d f; return d "/" f }
function num(s) { return s ~ /^[ \t]*[-+]?[0-9]+[ \t]*$/ }
function keyof(s,   o, i, c) {   # a safe file name for a cache key, "" when too long
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c ~ /^[A-Za-z0-9]$/) o = o c; else o = o "_" ORD[c] "_"
  }
  if (length(o) > 180) return ""
  return o
}
# cached CMD : runs CMD once per script run, returns the file that holds its output
function cached(cmd,   k, f, x, r) {
  k = keyof(cmd)
  if (k == "") { f = W "/c/t" (++NTMP) "_" PIDTAG; system("{ " cmd " ; } > " sq(f) " 2>/dev/null < /dev/null"); return f }
  f = W "/c/" k
  r = (getline x < f); close(f)
  if (r < 0) { system("{ " cmd " ; } > " sq(f "_" PIDTAG) " 2>/dev/null < /dev/null; mv " sq(f "_" PIDTAG) " " sq(f)) }
  return f
}
function has(tool,   c, x, r) {
  if (tool in HAS) return HAS[tool]
  c = "for d in `echo \"$PATH\" | tr : ' '`; do if [ -f \"$d/" tool "\" ] && [ -x \"$d/" tool "\" ]; then echo y; break; fi; done"
  x = ""; c | getline x; close(c)
  HAS[tool] = (x == "y")
  return HAS[tool]
}

# ---------------------------------------------------------------- regex (PCRE subset), backtracking
function mk(t, l, r) { NN++; NT[NN] = t; NL[NN] = l; NR_[NN] = r; return NN }
# lists ("," and "|") are flat, children NK[n, 1..NC[n]]: deep nesting overflows the stack of some awks
function addkid(n, k) { NC[n]++; NK[n, NC[n]] = k }
function up(c,   i) { i = index("abcdefghijklmnopqrstuvwxyz", c); return i ? substr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", i, 1) : c }
function setnode(s, neg) { NN++; NT[NN] = "K"; NS[NN] = s; NL[NN] = neg; return NN }
function charnode(c,   l, u) {
  if (RFI) { l = tolower(c); u = up(l); if (l != u) return setnode(l u, 0) }
  NN++; NT[NN] = "C"; NS[NN] = c
  return NN
}
function inverse(s,   o, i, c) {
  o = ""
  for (i = 1; i < 256; i++) { c = CHR[i]; if (index(s, c) == 0) o = o c }
  return o
}
# class for an escape letter, "" when it isn't one
function esc_set(c) {
  if (c == "d") return DIG
  if (c == "D") return inverse(DIG)
  if (c == "w") return WRD
  if (c == "W") return inverse(WRD)
  if (c == "s") return SPC
  if (c == "S") return inverse(SPC)
  if (c == "h") return " \t"
  if (c == "H") return inverse(" \t")
  if (c == "v") return "\n\013\f\r"
  if (c == "V") return inverse("\n\013\f\r")
  if (c == "N") return inverse("\n")
  return ""
}
function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
# literal for an escape; RI points at the escape letter on entry and at the last used char on exit
function esc_char(c,   h, v) {
  if (c == "n") return "\n"
  if (c == "t") return "\t"
  if (c == "r") return "\r"
  if (c == "f") return "\f"
  if (c == "a") return "\007"
  if (c == "e") return "\033"
  if (c == "x") {
    if (substr(RP, RI + 1, 1) == "{") {
      v = 0; RI++
      while (RI < RN && substr(RP, RI + 1, 1) != "}") { RI++; v = v * 16 + hexval(substr(RP, RI, 1)) }
      RI++
    } else {
      v = 0; h = hexval(substr(RP, RI + 1, 1))
      if (h >= 0) { v = h; RI++; h = hexval(substr(RP, RI + 1, 1)); if (h >= 0 && RI < RN) { v = v * 16 + h; RI++ } }
    }
    if (v > 0 && v < 256) return CHR[v]
    RERR = "unsupported character code"; return "x"
  }
  return c
}
function posix_set(nm) {
  if (nm == "alpha") return LOW UPP
  if (nm == "digit") return DIG
  if (nm == "alnum") return LOW UPP DIG
  if (nm == "upper") return UPP
  if (nm == "lower") return LOW
  if (nm == "space") return SPC
  if (nm == "blank") return " \t"
  if (nm == "punct") return PUN
  if (nm == "word") return WRD
  if (nm == "xdigit") return DIG "abcdefABCDEF"
  if (nm == "print") return LOW UPP DIG PUN " "
  if (nm == "graph") return LOW UPP DIG PUN
  if (nm == "cntrl") return substr(inverse(LOW UPP DIG PUN " "), 1, 31) "\177"
  RERR = "unknown class [:" nm ":]"
  return ""
}
function parse_class(   neg, s, c, first, i, e, lo, hi, j, t, isset) {
  neg = 0; s = ""; first = 1
  if (substr(RP, RI, 1) == "^") { neg = 1; RI++ }
  while (RI <= RN) {
    c = substr(RP, RI, 1)
    if (c == "]" && !first) { RI++; if (RFI) s = foldset(s); return setnode(s, neg) }
    first = 0; isset = 0
    if (c == "[" && substr(RP, RI + 1, 1) == ":") {
      e = index(substr(RP, RI + 2), ":]")
      if (e > 0) {
        t = substr(RP, RI + 2, e - 1)
        if (substr(t, 1, 1) == "^") s = s inverse(posix_set(substr(t, 2))); else s = s posix_set(t)
        RI = RI + e + 3
        continue
      }
    }
    if (c == "\\") {
      RI++; c = substr(RP, RI, 1); t = esc_set(c)
      if (t != "") { s = s t; isset = 1 }
      else if (c == "b") c = "\010"
      else if (c ~ /^[pPRX]$/) { RERR = "unsupported escape in a class"; return setnode(s, neg) }
      else c = esc_char(c)
    }
    RI++
    if (isset) continue
    if (substr(RP, RI, 1) == "-" && substr(RP, RI + 1, 1) != "]" && RI < RN) {
      lo = c; RI++; hi = substr(RP, RI, 1)
      if (hi == "\\") {
        RI++; hi = substr(RP, RI, 1)
        if (esc_set(hi) != "") { s = s lo "-" esc_set(hi); RI++; continue }
        hi = esc_char(hi)
      } else if (hi == "[" && substr(RP, RI + 1, 1) == ":") { s = s lo "-"; continue }
      RI++
      if (ORD[lo] > ORD[hi]) { RERR = "bad range in a class"; return setnode(s, neg) }
      for (j = ORD[lo]; j <= ORD[hi]; j++) s = s CHR[j]
    } else s = s c
  }
  RERR = "missing ]"
  return setnode(s, neg)
}
function foldset(s,   o, i, c, l) {
  o = s
  for (i = 1; i <= 26; i++) {
    l = substr(LOW, i, 1); c = substr(UPP, i, 1)
    if (index(s, l) && !index(s, c)) o = o c
    else if (index(s, c) && !index(s, l)) o = o l
  }
  return o
}
function parse_alt(   l, n) {
  l = parse_cat(); n = 0
  while (RI <= RN && substr(RP, RI, 1) == "|" && RERR == "") {
    if (!n) { n = mk("|", 0, 0); addkid(n, l) }
    RI++; l = parse_cat(); addkid(n, l)
  }
  return n ? n : l
}
function parse_cat(   l, a, c, n) {
  l = 0; n = 0
  while (RI <= RN && RERR == "") {
    c = substr(RP, RI, 1)
    if (c == "|" || c == ")") break
    a = parse_rep()
    if (!l) { l = a; continue }
    if (!n) { n = mk(",", 0, 0); addkid(n, l) }
    addkid(n, a)
  }
  if (n) return n
  if (!l) l = mk("E", 0, 0)
  return l
}
function parse_rep(   a, c, mn, mx, g, t, i, n) {
  a = parse_atom()
  while (RI <= RN && RERR == "") {
    c = substr(RP, RI, 1)
    if (RFX && (c == " " || c == "\t" || c == "\n")) { RI++; continue }
    if (c == "*") { mn = 0; mx = -1; RI++ }
    else if (c == "+") { mn = 1; mx = -1; RI++ }
    else if (c == "?") { mn = 0; mx = 1; RI++ }
    else if (c == "{") {
      i = index(substr(RP, RI), "}")
      t = i ? substr(RP, RI + 1, i - 2) : ""
      if (t ~ /^[0-9]+$/) { mn = t + 0; mx = mn }
      else if (t ~ /^[0-9]+,$/) { mn = t + 0; mx = -1 }
      else if (t ~ /^[0-9]+,[0-9]+$/) { n = index(t, ","); mn = substr(t, 1, n - 1) + 0; mx = substr(t, n + 1) + 0 }
      else break
      RI = RI + i
    } else break
    g = 1
    c = substr(RP, RI, 1)
    if (c == "?" && RI <= RN) { g = 0; RI++ } else if (c == "+" && RI <= RN) { g = 2; RI++ }
    if (mx == 0) { a = mk("E", 0, 0); continue }
    a = mk("*", a, 0); NMN[a] = mn; NMX[a] = mx; NG[a] = g
  }
  return a
}
function parse_atom(   c, n, k, t, fi, fm, fs, fx, on, body, neg) {
  c = substr(RP, RI, 1); RI++
  if (c == ".") { if (RFS) return setnode("", 1); return mk(".", 0, 0) }
  if (c == "^") return mk(RFM ? "^" : "A", 0, 0)
  if (c == "$") return mk(RFM ? "$" : "Z", 0, 0)
  if (c == "[") return parse_class()
  if (c == "(") {
    fi = RFI; fm = RFM; fs = RFS; fx = RFX
    if (substr(RP, RI, 1) == "?") {
      t = substr(RP, RI + 1, 1)
      if (t == ":") { RI += 2; n = parse_alt() }
      else if (t == "=" || t == "!") { RI += 2; body = parse_alt(); n = mk("=", body, (t == "!")) }
      else if (t == ">") { RI += 2; body = parse_alt(); n = mk(">", body, 0) }
      else if (t == "#") { while (RI <= RN && substr(RP, RI, 1) != ")") RI++; n = mk("E", 0, 0) }
      else if (t == "<" && (substr(RP, RI + 2, 1) == "=" || substr(RP, RI + 2, 1) == "!")) {
        neg = (substr(RP, RI + 2, 1) == "!"); RI += 3; body = parse_alt(); n = mk("<", body, neg)
      }
      else if (t == "P" || t == "<" || t == "'") {   # named group: counts like a normal one
        if (t == "P" && substr(RP, RI + 2, 1) != "<") { RERR = "unsupported group"; return mk("E", 0, 0) }
        while (RI <= RN && substr(RP, RI, 1) != ">" && !(t == "'" && substr(RP, RI, 1) == "'" && substr(RP, RI - 1, 1) != "?")) RI++
        RI++; k = ++RCAP; body = parse_alt(); n = mk("(", body, k)
      }
      else if (t ~ /^[imsxU-]$/ && t != "U") {
        on = 1; RI++
        while (RI <= RN) {
          t = substr(RP, RI, 1)
          if (t == "-") on = 0
          else if (t == "i") RFI = on
          else if (t == "m") RFM = on
          else if (t == "s") RFS = on
          else if (t == "x") RFX = on
          else break
          RI++
        }
        if (t == ")") { RI++; return mk("E", 0, 0) }   # flags hold until the enclosing group ends
        if (t != ":") { RERR = "unsupported group"; return mk("E", 0, 0) }
        RI++; n = parse_alt()
      }
      else { RERR = "unsupported group"; return mk("E", 0, 0) }
    } else { k = ++RCAP; body = parse_alt(); n = mk("(", body, k) }
    if (substr(RP, RI, 1) != ")") { if (RERR == "") RERR = "missing )"; return n }
    RI++
    RFI = fi; RFM = fm; RFS = fs; RFX = fx
    return n
  }
  if (c == "\\") {
    if (RI > RN) { RERR = "trailing backslash"; return mk("E", 0, 0) }
    c = substr(RP, RI, 1)
    t = esc_set(c)
    if (t != "") { RI++; return setnode(t, 0) }
    if (c == "b" || c == "B" || c == "A" || c == "Z" || c == "z") { RI++; return mk(c, 0, 0) }
    if (c == "R") { RI++; return setnode("\n\013\f\r", 0) }
    if (c == "Q") {
      RI++; n = mk(",", 0, 0); NC[n] = 0
      while (RI <= RN && substr(RP, RI, 2) != "\\E") { t = charnode(substr(RP, RI, 1)); RI++; addkid(n, t) }
      RI += 2
      return n
    }
    if (c == "E") { RI++; return mk("E", 0, 0) }
    if (c ~ /^[1-9]$/) { RI++; return mk("\\", c + 0, RFI) }
    if (c ~ /^[pPXGKCgku0]$/) { RERR = "unsupported escape \\" c; return mk("E", 0, 0) }
    c = esc_char(c); RI++
    return charnode(c)
  }
  if (RFX && (c == " " || c == "\t" || c == "\n")) return mk("E", 0, 0)
  if (RFX && c == "#") { while (RI <= RN && substr(RP, RI, 1) != "\n") RI++; return mk("E", 0, 0) }
  if (c == "*" || c == "+" || c == "?") { RERR = "nothing to repeat"; return mk("E", 0, 0) }
  return charnode(c)
}
function emit(op, a, b) {
  PC++
  if (PC > 6000) { RERR = "pattern too long"; PC = 6000 }
  OP[RID, PC] = op; PA[RID, PC] = a; PB[RID, PC] = b
  return PC
}
function simple(n) { return NT[n] == "C" || NT[n] == "K" || NT[n] == "." }
function emit1(n) {
  if (NT[n] == "C") return emit(1, NS[n], "")
  if (NT[n] == "K") return emit(2, NS[n], NL[n])
  return emit(3, "", "")
}
# point every instruction in the list " 3 9 12" at the next one (second target when SECOND)
function patch(l, second,   m, i) {
  m = split(l, PTL, " ")
  for (i = 1; i <= m; i++) if (second) PB[RID, PTL[i]] = PC + 1; else PA[RID, PTL[i]] = PC + 1
}
function gen(n,   t, a, b, i, k, x, first) {
  if (RERR != "") return
  t = NT[n]
  if (t == "E") return
  if (simple(n)) { emit1(n); return }
  if (t == ",") { for (i = 1; i <= NC[n]; i++) gen(NK[n, i]); return }
  if (t == "|") {
    b = ""
    for (i = 1; i <= NC[n]; i++) {
      if (i == NC[n]) { gen(NK[n, i]); break }
      a = emit(4, 0, 0); PA[RID, a] = PC + 1; gen(NK[n, i])
      b = b " " emit(5, 0, 0); PB[RID, a] = PC + 1
    }
    patch(b, 0)
    return
  }
  if (t == "(") { emit(6, NR_[n] * 2, ""); gen(NL[n]); emit(6, NR_[n] * 2 + 1, ""); return }
  if (t == "^") { emit(7, "", ""); return }
  if (t == "$") { emit(8, "", ""); return }
  if (t == "A") { emit(11, "", ""); return }
  if (t == "Z") { emit(12, "", ""); return }
  if (t == "z") { emit(13, "", ""); return }
  if (t == "b") { emit(14, 0, ""); return }
  if (t == "B") { emit(14, 1, ""); return }
  if (t == "\\") { emit(15, NL[n], NR_[n]); return }
  if (t == "=") { a = emit(16, NR_[n], 0); gen(NL[n]); emit(9, "", ""); PB[RID, a] = PC + 1; return }
  if (t == "<") { a = emit(17, NR_[n], 0); gen(NL[n]); emit(18, "", ""); emit(9, "", ""); PB[RID, a] = PC + 1; return }
  if (t == ">") { a = emit(19, "", 0); gen(NL[n]); emit(9, "", ""); PB[RID, a] = PC + 1; return }
  if (t == "*") {
    if (NG[n] == 2) { a = emit(19, "", 0); NG[n] = 1; gen(n); NG[n] = 2; emit(9, "", ""); PB[RID, a] = PC + 1; return }
    if (simple(NL[n])) { a = emit(10, NMN[n], NMX[n]); PX[RID, a] = NG[n]; emit1(NL[n]); return }
    for (i = 1; i <= NMN[n] && RERR == ""; i++) gen(NL[n])
    if (NMX[n] < 0) {
      k = ++RMARK
      a = emit(4, 0, 0); PM[RID, a] = NG[n]
      x = emit(20, k, ""); gen(NL[n]); emit(21, k, ""); emit(5, a, 0)
      if (NG[n]) { PA[RID, a] = x; PB[RID, a] = PC + 1 } else { PA[RID, a] = PC + 1; PB[RID, a] = x }
    } else if (NMX[n] > NMN[n]) {
      first = 0; b = ""
      for (i = NMN[n] + 1; i <= NMX[n] && RERR == ""; i++) {
        a = emit(4, 0, 0); b = b " " a
        if (NG[n]) PA[RID, a] = PC + 1; else PB[RID, a] = PC + 1
        gen(NL[n])
      }
      patch(b, NG[n])
    }
    return
  }
  RERR = "unsupported pattern"
}
# where can a match start? 1 = only at a line start, 2 = also where the search begins, 3 = only at the start of the text, 4 = only where the search begins
function anchor(n,   t, a, b) {
  t = NT[n]
  if (t == "^") return 1
  if (t == "A") return 3
  if (t == ",") {
    b = 0
    for (a = 1; a <= NC[n]; a++) {
      if (NT[NK[n, a]] == "=") { b = 1; continue }
      if (NT[NK[n, a]] == "E") continue
      a = anchor(NK[n, a])
      return (b && (a == 2 || a == 4)) ? 0 : a   # after a lookahead, .* does not have to start the line
    }
    return 0
  }
  if (t == "(" || t == ">") return anchor(NL[n])
  if (t == "|") { a = anchor(NK[n, 1]); for (b = 2; b <= NC[n]; b++) if (anchor(NK[n, b]) != a) return 0; return a }
  if (t == "*" && NMN[n] == 0 && NMX[n] < 0 && NG[n] == 1) {
    if (NT[NL[n]] == ".") return 2
    if (NT[NL[n]] == "K" && NS[NL[n]] == "" && NL[NL[n]] == 1) return 4
  }
  return 0
}
function litflush() { if (length(LCUR) > length(LBEST)) LBEST = LCUR; LCUR = "" }
function literal(n,   t, i) {   # longest text that every match must contain
  t = NT[n]
  if (t == "C") { LCUR = LCUR NS[n]; return }
  if (t == ",") { for (i = 1; i <= NC[n]; i++) literal(NK[n, i]); return }
  if (t == "(" || t == ">") { literal(NL[n]); return }
  if (t == "E") return
  litflush()
}
function firstchar(n,   t, i) {
  t = NT[n]
  if (t == "C") return NS[n]
  if (t == ",") { for (i = 1; i <= NC[n]; i++) if (NT[NK[n, i]] != "E") return firstchar(NK[n, i]); return "" }
  if (t == "(" || t == ">") return firstchar(NL[n])
  return ""
}
# re PATTERN FLAGS(i m s) : compiled program number, 0 when the pattern is not supported (RERR says why)
function re(pat, fl,   key, n) {
  key = fl SUBSEP pat
  if (key in REID) { RERR = REBAD[key]; return REID[key] }
  RERR = ""; RP = pat; RI = 1; RN = length(pat); RCAP = 0; RMARK = 0; PC = 0
  RFI = index(fl, "i") > 0; RFM = index(fl, "m") > 0; RFS = index(fl, "s") > 0; RFX = 0
  n = parse_alt()
  if (RERR == "" && RI <= RN) RERR = "unbalanced )"
  RID = ++NRE
  if (RERR == "") { gen(n); emit(9, "", "") }
  REBAD[key] = RERR
  if (RERR != "") { REID[key] = 0; return 0 }
  RCAPS[RID] = RCAP; RANCH[RID] = anchor(n); RTOP[RID] = n
  LCUR = ""; LBEST = ""; literal(n); litflush()
  RLIT[RID] = LBEST; RFC[RID] = firstchar(n)
  RALL[RID] = (pat == "^.*$" || pat == ".*" || pat == "^.*" || pat == ".*$")
  REID[key] = RID
  return RID
}
function one(p, pc, c,   o) {   # does the single-character instruction match c?
  if (c == "") return 0
  o = OP[p, pc]
  if (o == 2) return (index(PA[p, pc], c) > 0) != PB[p, pc]
  if (o == 1) return c == PA[p, pc]
  return c != "\n"
}
function wordat(i,   c) { if (i < 1 || i > BLEN) return 0; c = substr(BUF, i, 1); return index(WRD, c) > 0 }
function vm(p, pc, pos, tgt,   sp0, o, c, n, mx, t, ok, k, e) {
  sp0 = SP
  while (1) {
    if (++STEPS > MAXSTEPS) { RERR = "pattern needs too much work on this text"; SP = sp0; return 0 }
    o = OP[p, pc]; ok = 1
    if (o == 1) { if (pos <= BLEN && substr(BUF, pos, 1) == PA[p, pc]) { pos++; pc++ } else ok = 0 }
    else if (o == 10) {
      n = 0; mx = PB[p, pc]; k = pc + 1; t = OP[p, k]
      if (PX[p, pc] == 1) {
        if (t == 2) {
          while ((mx < 0 || n < mx) && pos + n <= BLEN && (index(PA[p, k], substr(BUF, pos + n, 1)) > 0) != PB[p, k]) n++
        } else if (t == 3) {
          while ((mx < 0 || n < mx) && pos + n <= BLEN && substr(BUF, pos + n, 1) != "\n") n++
        } else {
          while ((mx < 0 || n < mx) && pos + n <= BLEN && substr(BUF, pos + n, 1) == PA[p, k]) n++
        }
        STEPS += n / 4
        if (n < PA[p, pc]) ok = 0
        else {
          if (n > PA[p, pc]) { SP++; ST[SP] = 3; SA[SP] = pc + 2; SB[SP] = pos + PA[p, pc]; SC[SP] = pos + n }
          pos += n; pc += 2
        }
      } else {
        while (n < PA[p, pc] && pos + n <= BLEN && one(p, k, substr(BUF, pos + n, 1))) n++
        if (n < PA[p, pc]) ok = 0
        else {
          SP++; ST[SP] = 4; SA[SP] = pc; SB[SP] = (mx < 0 ? -1 : pos + mx); SC[SP] = pos + n
          pos += n; pc += 2
        }
      }
    }
    else if (o == 2) { if (pos <= BLEN && (index(PA[p, pc], substr(BUF, pos, 1)) > 0) != PB[p, pc]) { pos++; pc++ } else ok = 0 }
    else if (o == 3) { if (pos <= BLEN && substr(BUF, pos, 1) != "\n") { pos++; pc++ } else ok = 0 }
    else if (o == 4) { SP++; ST[SP] = 0; SA[SP] = PB[p, pc]; SB[SP] = pos; pc = PA[p, pc] }
    else if (o == 5) pc = PA[p, pc]
    else if (o == 6) { k = PA[p, pc]; SP++; ST[SP] = 1; SA[SP] = k; SB[SP] = CAP[k]; CAP[k] = pos; pc++ }
    else if (o == 7) { if (pos == 1 || (pos <= BLEN && substr(BUF, pos - 1, 1) == "\n")) pc++; else ok = 0 }
    else if (o == 8) { if (pos > BLEN || substr(BUF, pos, 1) == "\n") pc++; else ok = 0 }
    else if (o == 9) {   # matched: forget the choices, keep the capture history for the caller
      MEND = pos
      n = sp0
      for (k = sp0 + 1; k <= SP; k++) if (ST[k] == 1 || ST[k] == 2) { n++; ST[n] = ST[k]; SA[n] = SA[k]; SB[n] = SB[k] }
      SP = n
      return 1
    }
    else if (o == 11) { if (pos == 1) pc++; else ok = 0 }
    else if (o == 12) { if (pos > BLEN || (pos == BLEN && substr(BUF, pos, 1) == "\n")) pc++; else ok = 0 }
    else if (o == 13) { if (pos > BLEN) pc++; else ok = 0 }
    else if (o == 14) { if ((wordat(pos - 1) != wordat(pos)) != PA[p, pc]) pc++; else ok = 0 }
    else if (o == 15) {
      k = PA[p, pc]
      if (CAP[k * 2 + 1] == 0) ok = 0
      else {
        t = substr(BUF, CAP[k * 2], CAP[k * 2 + 1] - CAP[k * 2])
        e = substr(BUF, pos, length(t))
        if ((e "") == (t "") || (PB[p, pc] && tolower(e) == tolower(t))) { pos += length(t); pc++ } else ok = 0
      }
    }
    else if (o == 16) {
      n = SP; e = vm(p, pc + 1, pos, 0)
      if (PA[p, pc]) { while (SP > n) { if (ST[SP] == 1) CAP[SA[SP]] = SB[SP]; else if (ST[SP] == 2) MRK[SA[SP]] = SB[SP]; SP-- } e = !e }
      if (e && RERR == "") pc = PB[p, pc]; else ok = 0
    }
    else if (o == 17) {
      e = 0
      for (k = pos; k >= 1 && !e && RERR == ""; k--) {
        n = SP; e = vm(p, pc + 1, k, pos)
        if (PA[p, pc]) while (SP > n) { if (ST[SP] == 1) CAP[SA[SP]] = SB[SP]; else if (ST[SP] == 2) MRK[SA[SP]] = SB[SP]; SP-- }
      }
      if (e != PA[p, pc] && RERR == "") pc = PB[p, pc]; else ok = 0
    }
    else if (o == 18) { if (pos == tgt) pc++; else ok = 0 }
    else if (o == 19) { if (vm(p, pc + 1, pos, 0)) { pos = MEND; pc = PB[p, pc] } else ok = 0 }
    else if (o == 20) { k = PA[p, pc]; SP++; ST[SP] = 2; SA[SP] = k; SB[SP] = MRK[k]; MRK[k] = pos; pc++ }
    else if (o == 21) { if (MRK[PA[p, pc]] == pos) pc += 2; else pc++ }   # an empty pass ends the loop
    if (ok) continue
    if (RERR != "") { SP = sp0; return 0 }
    while (1) {   # backtrack
      if (SP <= sp0) return 0
      t = ST[SP]
      if (t == 0) { pc = SA[SP]; pos = SB[SP]; SP--; break }
      if (t == 3) {
        SC[SP]--; pos = SC[SP]; pc = SA[SP]
        if (pos <= SB[SP]) SP--
        break
      }
      if (t == 4) {
        k = SC[SP]
        if ((SB[SP] >= 0 && k >= SB[SP]) || k > BLEN || !one(p, SA[SP] + 1, substr(BUF, k, 1))) { SP--; continue }
        SC[SP]++; pos = k + 1; pc = SA[SP] + 2
        break
      }
      if (t == 1) CAP[SA[SP]] = SB[SP]; else MRK[SA[SP]] = SB[SP]
      SP--
    }
  }
}
# search BUF from position FROM: 1 and MBEG, MEND, CAP when found
function search(p, from,   i, a, fc, k, nx) {
  RERR = ""; STEPS = 0
  a = RANCH[p]; fc = RFC[p]
  if (RLIT[p] != "" && index(BUF, RLIT[p]) == 0) return 0
  for (i = from; i <= BLEN + 1; i++) {
    if (a == 1 || a == 2) {
      if (!(i == 1 || substr(BUF, i - 1, 1) == "\n" || (a == 2 && i == from))) {
        nx = index(substr(BUF, i), "\n")
        if (!nx) return 0
        i += nx
      }
    } else if (a == 3) { if (i > 1) return 0 }
    else if (a == 4) { if (i > from) return 0 }
    else if (fc != "" && substr(BUF, i, 1) != fc) {
      nx = index(substr(BUF, i), fc)
      if (!nx) return 0
      i += nx - 1
    }
    for (k = 0; k <= RCAPS[p] * 2 + 1; k++) CAP[k] = 0
    SP = 0
    if (vm(p, 1, i, 0)) { MBEG = i; return 1 }
    if (RERR != "") return 0
  }
  return 0
}
# "true", "false" or "error": does PAT match somewhere in S?
function rematch(pat, s, fl,   p) {
  p = re(pat, fl)
  if (!p) return "error"
  if (RALL[p] && index(s, "\n") == 0) return "true"
  BUF = s; BLEN = length(s)
  if (search(p, 1)) return "true"
  return RERR == "" ? "false" : "error"
}

# literal starts of a path pattern, so find does not have to walk the whole disk.
# entries end in \001 (something variable follows), \002 (that is the whole path) or nothing
function pf(n, set,   t, m, i, e, o, b, x) {
  t = NT[n]
  if (set == PFALL) return set
  if (t == "E" || t == "^" || t == "A" || t == "=") return set
  if (t == ",") { for (i = 1; i <= NC[n]; i++) set = pf(NK[n, i], set); return set }
  if (t == "(" || t == ">") return pf(NL[n], set)
  if (t == "|") {
    b = ""
    for (i = 1; i <= NC[n]; i++) { x = pf(NK[n, i], set); if (x == PFALL || length(b) + length(x) > 3000) return PFALL; b = b (i > 1 ? "\n" : "") x }
    return b
  }
  m = split(set, PFT, "\n"); o = ""
  if (m == 0) { m = 1; PFT[1] = "" }
  for (i = 1; i <= m; i++) PFC[i] = PFT[i]
  for (i = 1; i <= m; i++) {
    e = PFC[i]
    if (substr(e, length(e), 1) != "\001" && substr(e, length(e), 1) != "\002") {
      if (t == "C") e = e NS[n]
      else if (t == "$" || t == "Z" || t == "z") e = e "\002"
      else e = e "\001"
    }
    o = o (i > 1 ? "\n" : "") e
  }
  return o
}
# starts for a path regex: fills PS[1..n] (PE[i] = 1: an exact path), returns n
function starts(pat,   p, set, m, i, e, n, x, j, dup) {
  p = re(pat, "")
  if (!p) return -1
  n = 0
  if (RANCH[p] != 3) { PS[1] = "/"; PE[1] = 0; return 1 }
  set = pf(RTOP[p], "")
  if (set == PFALL) { PS[1] = "/"; PE[1] = 0; return 1 }
  m = split(set, PFT, "\n")
  for (i = 1; i <= m; i++) {
    e = PFT[i]; x = 0
    if (substr(e, length(e), 1) == "\002") { x = 1; e = substr(e, 1, length(e) - 1) }
    else {
      if (substr(e, length(e), 1) == "\001") e = substr(e, 1, length(e) - 1)
      e = substr(e, 1, lastslash(e))
      if (e == "") e = "/"
      if (length(e) > 1) e = substr(e, 1, length(e) - 1)
    }
    dup = 0
    for (j = 1; j <= n; j++) if (PS[j] == e && PE[j] == x) dup = 1
    if (!dup && e != "") { n++; PS[n] = e; PE[n] = x }
  }
  return n
}

# ---------------------------------------------------------------- comparing
function rpmcmp(a, b,   i, j, x, y, ca, cb, isn) {
  if (a == b) return 0
  i = 1; j = 1
  while (i <= length(a) || j <= length(b)) {
    while (i <= length(a) && substr(a, i, 1) !~ /^[A-Za-z0-9~^]$/) i++
    while (j <= length(b) && substr(b, j, 1) !~ /^[A-Za-z0-9~^]$/) j++
    ca = substr(a, i, 1); cb = substr(b, j, 1)
    if (ca == "~" || cb == "~") { if (ca != "~") return 1; if (cb != "~") return -1; i++; j++; continue }
    if (ca == "^" || cb == "^") {
      if (ca == "") return -1
      if (cb == "") return 1
      if (ca != "^") return 1
      if (cb != "^") return -1
      i++; j++; continue
    }
    if (ca == "" || cb == "") break
    isn = ca ~ /^[0-9]$/
    x = ""; y = ""
    if (isn) {
      while (substr(a, i, 1) ~ /^[0-9]$/) { x = x substr(a, i, 1); i++ }
      while (substr(b, j, 1) ~ /^[0-9]$/) { y = y substr(b, j, 1); j++ }
    } else {
      while (substr(a, i, 1) ~ /^[A-Za-z]$/) { x = x substr(a, i, 1); i++ }
      while (substr(b, j, 1) ~ /^[A-Za-z]$/) { y = y substr(b, j, 1); j++ }
    }
    if (y == "") return isn ? 1 : -1
    if (isn) {
      sub(/^0+/, "", x); sub(/^0+/, "", y)
      if (length(x) != length(y)) return length(x) > length(y) ? 1 : -1
    }
    if ((x "") > (y "")) return 1
    if ((x "") < (y "")) return -1
  }
  if (i > length(a) && j > length(b)) return 0
  return i > length(a) ? -1 : 1
}
function dord(c) { if (c == "~") return -1; if (c == "" || c ~ /^[0-9]$/) return 0; if (c ~ /^[A-Za-z]$/) return ORD[c]; return ORD[c] + 256 }
function dpkgcmp(a, b,   i, j, d, x, y) {
  i = 1; j = 1
  while (i <= length(a) || j <= length(b)) {
    while ((i <= length(a) && substr(a, i, 1) !~ /^[0-9]$/) || (j <= length(b) && substr(b, j, 1) !~ /^[0-9]$/)) {
      d = dord(substr(a, i, 1)) - dord(substr(b, j, 1))
      if (d) return d < 0 ? -1 : 1
      if (i <= length(a)) i++
      if (j <= length(b)) j++
    }
    x = ""; y = ""
    while (substr(a, i, 1) ~ /^[0-9]$/) { x = x substr(a, i, 1); i++ }
    while (substr(b, j, 1) ~ /^[0-9]$/) { y = y substr(b, j, 1); j++ }
    sub(/^0+/, "", x); sub(/^0+/, "", y)
    if (length(x) != length(y)) return length(x) > length(y) ? 1 : -1
    if ((x "") > (y "")) return 1
    if ((x "") < (y "")) return -1
  }
  return 0
}
function splitevr(s,   i) {   # sets EE, EV, ER
  i = index(s, ":")
  if (i) { EE = substr(s, 1, i - 1); s = substr(s, i + 1) } else EE = 0
  if (EE == "" || EE == "(none)") EE = 0
  i = 0
  while (match(substr(s, i + 1), /-/)) i += RSTART
  if (i) { EV = substr(s, 1, i - 1); ER = substr(s, i + 1) } else { EV = s; ER = "" }
}
function evrcmp(a, b, deb,   e1, v1, r1, d) {
  splitevr(a); e1 = EE; v1 = EV; r1 = ER; splitevr(b)
  if (e1 + 0 != EE + 0) return e1 + 0 > EE + 0 ? 1 : -1
  d = deb ? dpkgcmp(v1, EV) : rpmcmp(v1, EV)
  if (d) return d
  if (!deb && (r1 == "" || ER == "")) return 0
  return deb ? dpkgcmp(r1, ER) : rpmcmp(r1, ER)
}
function vercmp(a, b,   n, m, i, x, y) {   # 1.10.2 against 1.9
  n = split(a, VC1, /[^0-9]+/); m = split(b, VC2, /[^0-9]+/)
  for (i = 1; i <= n || i <= m; i++) {
    x = (i <= n ? VC1[i] + 0 : 0); y = (i <= m ? VC2[i] + 0 : 0)
    if (x != y) return x > y ? 1 : -1
  }
  return 0
}
function bitop(a, b, isand,   r, p, x, y) {
  r = 0; p = 1
  while (a > 0 || b > 0) {
    x = a % 2; y = b % 2
    if (isand ? (x && y) : (x || y)) r += p
    a = int(a / 2); b = int(b / 2); p *= 2
  }
  return r
}
function bool(s) { s = tolower(s); if (s == "1" || s == "true" || s == "yes") return "true"; if (s == "0" || s == "false" || s == "no") return "false"; return s }
function ord3(op, d) {   # d = -1, 0, 1
  if (op == "equals" || op == "case insensitive equals") return d == 0 ? "true" : "false"
  if (op == "not equal" || op == "case insensitive not equal") return d != 0 ? "true" : "false"
  if (op == "greater than") return d > 0 ? "true" : "false"
  if (op == "greater than or equal") return d >= 0 ? "true" : "false"
  if (op == "less than") return d < 0 ? "true" : "false"
  if (op == "less than or equal") return d <= 0 ? "true" : "false"
  return "error"
}
function ipnum(s,   n) {
  n = split(s, IPP, ".")
  if (n != 4 || s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return -1
  return ((IPP[1] * 256 + IPP[2]) * 256 + IPP[3]) * 256 + IPP[4]
}
function cmpval(op, dt, have, want,   a, b, i, m1, m2, s) {
  have = have ""; want = want ""
  if (op == "pattern match") return rematch(want, have, "")
  if (dt == "int") {
    if (!num(have) || !num(want)) return "error"
    a = have + 0; b = want + 0
    if (op == "bitwise and") return bitop(a, b, 1) == b ? "true" : "false"
    if (op == "bitwise or") return bitop(a, b, 0) == b ? "true" : "false"
    return ord3(op, a < b ? -1 : a > b ? 1 : 0)
  }
  if (dt == "float") { a = have + 0; b = want + 0; return ord3(op, a < b ? -1 : a > b ? 1 : 0) }
  if (dt == "boolean") { a = bool(have); b = bool(want); return ord3(op, a == b ? 0 : 1) }
  if (dt == "evr_string") return ord3(op, evrcmp(have, want, 0))
  if (dt == "debian_evr_string") return ord3(op, evrcmp(have, want, 1))
  if (dt == "version" || dt == "fileset_revision" || dt == "ios_version") return ord3(op, vercmp(have, want))
  if (dt == "ipv4_address") {
    m1 = 32; m2 = 32
    if ((i = index(have, "/")) > 0) { m1 = substr(have, i + 1) + 0; have = substr(have, 1, i - 1) }
    if ((i = index(want, "/")) > 0) { m2 = substr(want, i + 1) + 0; want = substr(want, 1, i - 1) }
    a = ipnum(have); b = ipnum(want)
    if (a < 0 || b < 0 || m1 > 32 || m2 > 32) return "error"
    s = 1; for (i = 1; i <= 32 - m2; i++) s *= 2
    if (op == "subset of") return (m1 >= m2 && int(a / s) == int(b / s)) ? "true" : "false"
    if (op == "equals" || op == "not equal") return ord3(op, (a == b && m1 == m2) ? 0 : 1)
    return ord3(op, a < b ? -1 : a > b ? 1 : 0)
  }
  if (dt != "" && dt != "string" && dt != "binary") return "error"
  if (op == "case insensitive equals" || op == "case insensitive not equal") { have = tolower(have); want = tolower(want) }
  return ord3(op, (have "") == (want "") ? 0 : (have "") < (want "") ? -1 : 1)
}
function tally(r) {
  if (r == "true") CT++; else if (r == "false") CF++; else if (r == "error") CE++
  else if (r == "unknown") CU++; else if (r == "not evaluated") CV++; else CA++
}
function bycheck(chk, t, f, e, u, v, a) {
  if (chk == "all") {
    if (f) return "false"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (t) return "true"
  } else if (chk == "at least one") {
    if (t) return "true"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (f) return "false"
  } else if (chk == "only one") {
    if (t > 1) return "false"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (t == 1) return "true"
    if (f) return "false"
  } else {   # none satisfy, none exist
    if (t) return "false"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (f) return "true"
  }
  return a ? "not applicable" : "unknown"
}
function byop(op, t, f, e, u, v, a) {
  if (op == "AND") return bycheck("all", t, f, e, u, v, a)
  if (op == "OR") return bycheck("at least one", t, f, e, u, v, a)
  if (op == "ONE") return bycheck("only one", t, f, e, u, v, a)
  if (e) return "error"   # XOR
  if (u) return "unknown"
  if (v) return "not evaluated"
  if (t + f == 0) return a ? "not applicable" : "unknown"
  return t % 2 ? "true" : "false"
}
function flip(r) { if (r == "true") return "false"; if (r == "false") return "true"; return r }

# ---------------------------------------------------------------- variables
# val VID : evaluates a variable once. VF[VID] = ok, none, error. VN[VID] values in VV[VID, i]
function val(v,   x, i, n) {
  if (v in VF) return VF[v]
  if (!(v in VK)) { VF[v] = "error"; VN[v] = 0; return "error" }
  if (VK[v] != "local") { VN[v] += 0; VF[v] = VN[v] ? "ok" : "none"; return VF[v] }
  VF[v] = "error"; VN[v] = 0   # guards against loops
  x = VX[v]; comp(x)
  n = XN[x]
  for (i = 1; i <= n; i++) VV[v, i] = XV[x, i]
  VN[v] = n
  VF[v] = XF[x] == "ok" ? (n ? "ok" : "none") : XF[x]
  return VF[v]
}
function xput(x, s) { XN[x]++; XV[x, XN[x]] = s "" }
function comp(x,   f, i, j, k, n, c, o, it, e, p, s, t, best) {
  if (x in XF) return
  XF[x] = "ok"; XN[x] = 0
  f = XK[x]
  if (f == "lit") { xput(x, XA[x, 1]); return }
  if (f == "bad") { XF[x] = "error"; return }
  if (f == "var") {
    XF[x] = val(XA[x, 1])
    for (i = 1; i <= VN[XA[x, 1]]; i++) xput(x, VV[XA[x, 1], i])
    return
  }
  if (f == "obj") {
    o = XA[x, 1]; collect(o)
    if (OF_[o] == "error" || OF_[o] == "nc") { XF[x] = "error"; return }
    if (OF_[o] == "na") { XF[x] = "error"; return }
    for (i = 1; i <= OIN[o]; i++) {
      n = split(getent(OI[o, i], XA[x, 2]), MV, SEP)
      if (!hasent(OI[o, i], XA[x, 2])) continue
      if (n == 0) xput(x, "")
      for (j = 1; j <= n; j++) xput(x, MV[j])
    }
    if (OIN[o] == 0) XF[x] = "none"
    return
  }
  n = XC[x]
  for (i = 1; i <= n; i++) {
    c = XA[x, i]
    if (f == "split" && i > 1 || f == "substring" && i > 1 || f == "regex_capture" && i > 1 || f == "begin" && i > 1 || f == "end" && i > 1 || f == "arithmetic" && i == 1 || f == "time_difference" && i < 3) continue
    comp(c)
    if (XF[c] == "error") XF[x] = "error"
    else if (XF[c] == "none" && f != "count" && f != "unique" && f != "merge" && XF[x] == "ok") XF[x] = "none"
  }
  if (XF[x] == "error") return
  if (f == "count") {
    k = 0; for (i = 1; i <= n; i++) k += XN[XA[x, i]]
    XF[x] = "ok"; xput(x, k); return
  }
  if (XF[x] == "none") return
  if (f == "unique" || f == "merge") {
    for (i = 1; i <= n; i++) for (j = 1; j <= XN[XA[x, i]]; j++) {
      s = XV[XA[x, i], j]
      if (f == "unique" && ((x, s) in XU)) continue
      XU[x, s] = 1; xput(x, s)
    }
    if (XN[x] == 0) XF[x] = "none"
    return
  }
  if (f == "concat") {
    XV[x, 1] = ""; XN[x] = 1
    for (i = 1; i <= n; i++) {
      c = XA[x, i]; k = XN[x]; t = 0
      for (j = 1; j <= k; j++) XT[j] = XV[x, j]
      for (j = 1; j <= k; j++) for (p = 1; p <= XN[c]; p++) { t++; XV[x, t] = XT[j] XV[c, p] }
      XN[x] = t
    }
    return
  }
  if (f == "arithmetic") {
    for (i = 2; i <= n; i++) {
      c = XA[x, i]
      for (j = 1; j <= XN[c]; j++) if (XV[c, j] !~ /^[ \t]*[-+]?[0-9.]+[ \t]*$/) { XF[x] = "error"; return }
      if (i == 2) { for (j = 1; j <= XN[c]; j++) xput(x, XV[c, j]); continue }
      k = XN[x]; t = 0
      for (j = 1; j <= k; j++) XT[j] = XV[x, j]
      for (j = 1; j <= k; j++) for (p = 1; p <= XN[c]; p++) {
        t++; s = XA[x, 1] == "multiply" ? XT[j] * XV[c, p] : XT[j] + XV[c, p]
        XV[x, t] = s == int(s) ? sprintf("%.0f", s) : s ""
      }
      XN[x] = t
    }
    return
  }
  c = XA[x, 1]
  if (f == "time_difference") {   # only seconds since 1970: now minus the value, or value 1 minus value 2
    if (XA[x, 2] != "seconds_since_epoch" || (n > 3 && XA[x, 1] != "seconds_since_epoch")) { XF[x] = "error"; return }
    c = XA[x, 3]
    for (j = 1; j <= XN[c]; j++) {
      if (!num(XV[c, j])) { XF[x] = "error"; return }
      if (n < 4) { xput(x, sprintf("%.0f", NOW - XV[c, j])); continue }
      for (k = 1; k <= XN[XA[x, 4]]; k++) { if (!num(XV[XA[x, 4], k])) { XF[x] = "error"; return } xput(x, sprintf("%.0f", XV[c, j] - XV[XA[x, 4], k])) }
    }
    return
  }
  for (j = 1; j <= XN[c]; j++) {
    s = XV[c, j]
    if (f == "split") {
      t = XA[x, 2]
      if (t == "") { xput(x, s); continue }
      while ((i = index(s, t)) > 0) { xput(x, substr(s, 1, i - 1)); s = substr(s, i + length(t)) }
      xput(x, s)
    } else if (f == "substring") {
      i = XA[x, 2] + 0; k = XA[x, 3] + 0
      if (i > length(s)) { XF[x] = "error"; return }
      if (i < 1) i = 1
      xput(x, k < 0 ? substr(s, i) : substr(s, i, k))
    } else if (f == "regex_capture") {
      p = re(XA[x, 2], "")
      if (!p) { XF[x] = "error"; return }
      BUF = s; BLEN = length(s)
      if (search(p, 1)) xput(x, CAP[3] ? substr(BUF, CAP[2], CAP[3] - CAP[2]) : "")
      else if (RERR != "") { XF[x] = "error"; return }
      else xput(x, "")
    } else if (f == "begin") xput(x, substr(s, 1, length(XA[x, 2])) == XA[x, 2] ? s : XA[x, 2] s)
    else if (f == "end") xput(x, substr(s, length(s) - length(XA[x, 2]) + 1) == XA[x, 2] ? s : s XA[x, 2])
    else if (f == "escape_regex") {
      t = ""
      for (i = 1; i <= length(s); i++) { k = substr(s, i, 1); t = t (index("^$\\.[](){}*+?|", k) ? "\\" k : k) }
      xput(x, t)
    } else if (f == "glob_to_regex") xput(x, globre(s))
    else { XF[x] = "error"; return }
  }
}
function globre(g,   o, i, c, n) {
  o = "^"
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "\\" && i < length(g)) { i++; o = o "\\" substr(g, i, 1) }
    else if (c == "*") o = o "[^/]*"
    else if (c == "?") o = o "[^/]"
    else if (c == "[") {
      n = index(substr(g, i + 2), "]")
      if (!n) { o = o "\\["; continue }
      c = substr(g, i + 1, n)
      if (substr(c, 1, 1) == "!") c = "^" substr(c, 2)
      o = o "[" c "]"; i += n + 1
    }
    else o = o (index("^$.](){}+|", c) ? "\\" c : c)
  }
  return o "$"
}

# ---------------------------------------------------------------- items
function newitem(kind) { NI++; IK[NI] = kind; return NI }
function put(it, e, v) { IV[it, e] = v "" }
function hasent(it, e) {
  if ((it, e) in IV) return 1
  if (IK[it] == "file") return (e in FPERM)
  if (IK[it] == "partition") return (e == "total_space" || e == "space_used" || e == "space_left")
  return 0
}
function getent(it, e,   m, r, k) {
  if ((it, e) in IV) return IV[it, e]
  if (IK[it] == "file" && (e in FPERM)) {
    m = IV[it, "mode"]
    k = FPERM[e]
    if (e == "suid" || e == "sgid") return substr(m, k, 1) ~ /^[sS]$/ ? "true" : "false"
    if (e == "sticky") return substr(m, k, 1) ~ /^[tT]$/ ? "true" : "false"
    if (e == "has_extended_acl") return substr(m, 11, 1) == "+" ? "true" : "false"
    if (e == "oexec") return substr(m, k, 1) ~ /^[xt]$/ ? "true" : "false"
    if (e == "uexec" || e == "gexec") return substr(m, k, 1) ~ /^[xs]$/ ? "true" : "false"
    return substr(m, k, 1) != "-" ? "true" : "false"
  }
  return ""
}
# what the item is, to compare members of sets
function ident(it,   s, i, n) {
  n = split("filepath text instance subexpression name arch evr value unit property dependency mount_point device username pid command_line protocol local_full_address canonical_path hash_type hash", IDE, " ")
  s = IK[it]
  for (i = 1; i <= n; i++) if ((it, IDE[i]) in IV) s = s SUBSEP IDE[i] "=" IV[it, IDE[i]]
  return s
}
function show(it,   s, i, n, v) {
  n = split("filepath name unit username mount_point property value canonical_path text subexpression evr dependency user_id group_id mode type os_name processor_type flstinst level state maintenance_level tunable vuid label service_name runlevel start protocol local_full_address command_line hash inet_addr", SHE, " ")
  s = ""
  if (IV[it, "filepath"] ~ /^\/etc\/(shadow|gshadow|security\/passwd)/) return IV[it, "filepath"] " (content hidden)"
  for (i = 1; i <= n; i++) if ((it, SHE[i]) in IV) {
    v = IV[it, SHE[i]]
    if (IK[it] == "password" && SHE[i] != "username" && SHE[i] != "user_id" && SHE[i] != "group_id") continue
    if (IK[it] == "shadow" && SHE[i] != "username") continue
    if (SHE[i] == "subexpression" && (it, "text") in IV && index(IV[it, "text"], v)) continue
    gsub(SEP, ",", v)
    s = s (s == "" ? "" : " | ") v
  }
  return oneline(s)
}

# ---------------------------------------------------------------- objects
function entn(o, e) { if (OEX[o, e] == "var") return VN[OEA[o, e]]; return 1 }
function entv(o, e, i) { if (OEX[o, e] == "var") return VV[OEA[o, e], i]; return OEA[o, e] }
function hasobj(o, e) { return (o, e) in OEX }
function prepstate(s,   i) { for (i = 1; i <= SEN[s]; i++) if (SEX[s, i] == "var") val(SEA[s, i]) }
# all variables an object needs. "" when fine, else the flag the object gets
function prep(o,   i, e, r) {
  for (i = 1; i <= OEN[o]; i++) {
    e = OEL[o, i]
    if (OEX[o, e] == "var") {
      r = val(OEA[o, e])
      if (r == "error") return "error"
      if (r == "none") return "none"
    }
  }
  # variables of the filters too: they may run probes, which must not happen in the middle of a listing
  for (i = 1; i <= OFN[o]; i++) prepstate(OFL[o, i])
  return ""
}
# does value v satisfy the object's entity e? true/false/error
function objent(o, e, v,   i, n, r) {
  if (!hasobj(o, e) || OEX[o, e] == "nil") return "true"
  if (OEX[o, e] != "var") return cmpval(OEP[o, e], OED[o, e], v, OEA[o, e])
  CT = CF = CE = CU = CV = CA = 0
  n = entn(o, e)
  for (i = 1; i <= n; i++) tally(cmpval(OEP[o, e], OED[o, e], v, entv(o, e, i)))
  return bycheck(OEV[o, e], CT, CF, CE, CU, CV, CA)
}
function objmatch(o, e, v,   r) { r = objent(o, e, v); if (r == "error") OBAD[o] = 1; return r == "true" }

# addto O IT : applies the object's filters, then keeps the item
function addto(o, it,   i, r) {
  for (i = 1; i <= OFN[o]; i++) {
    r = evalstate(OFL[o, i], it)
    if (r == "error") OBAD[o] = 1
    if (OFA[o, i] == "include" ? r != "true" : r == "true") return 0
  }
  OIN[o]++; OI[o, OIN[o]] = it
  return 1
}
function collect(o,   r, k) {
  if (o in OF_) return
  OF_[o] = "error"; OIN[o] = 0
  if (!(o in OKIND)) return
  if (o in SOP) { for (k = 1; k <= OFN[o]; k++) prepstate(OFL[o, k]); collectset(o); return }
  r = prep(o)
  if (r != "") { OF_[o] = r; return }
  k = OKIND[o]
  if (k == "textfilecontent54") r = p_text(o)
  else if (k == "file") r = p_file(o)
  else if (k == "dpkginfo") r = p_dpkg(o)
  else if (k == "rpminfo") r = p_rpm(o)
  else if (k == "partition") r = p_partition(o)
  else if (k == "sysctl") r = p_sysctl(o)
  else if (k == "systemdunitproperty") r = p_unitprop(o)
  else if (k == "systemdunitdependency") r = p_unitdep(o)
  else if (k == "family") r = p_family(o)
  else if (k == "uname") r = p_uname(o)
  else if (k == "password") r = p_password(o)
  else if (k == "shadow") r = p_shadow(o)
  else if (k == "environmentvariable58" || k == "environmentvariable") r = p_env(o)
  else if (k == "variable") r = p_variable(o)
  else if (k == "symlink") r = p_symlink(o)
  else if (k == "filehash58") r = p_hash(o)
  else if (k == "interface") r = p_interface(o)
  else if (k == "inetlisteningservers") r = p_listen(o)
  else if (k == "process58" || k == "process") r = p_process(o)
  else if (k == "runlevel") r = p_runlevel(o)
  else if (k == "selinuxboolean") r = p_sebool(o)
  else if (k == "selinuxsecuritycontext") r = p_secontext(o)
  else if (k == "fileset") r = p_fileset(o)
  else if (k == "oslevel") r = p_oslevel(o)
  else if (k == "no") r = p_no(o)
  else if (k == "interim_fix") r = p_ifix(o)
  else r = "nc"
  if (r == "ok") r = OBAD[o] ? "error" : OIN[o] ? "complete" : "none"
  OF_[o] = r
}
function collectset(o,   n, i, j, it, f, k, any, fl, id) {
  n = SNUM[o]; any = ""
  for (i = 1; i <= n; i++) {
    collect(SOB[o, i]); f = OF_[SOB[o, i]]
    if (f == "error") any = "error"
    else if ((f == "nc" || f == "na") && any == "") any = f
  }
  if (any != "") { OF_[o] = any; return }
  for (i = 1; i <= n; i++) for (j = 1; j <= OIN[SOB[o, i]]; j++) {
    it = OI[SOB[o, i], j]; id = ident(it)
    SEEN[o, i, id] = 1
  }
  for (i = 1; i <= n; i++) {
    if (i == 2 && SOP[o] != "UNION") break
    for (j = 1; j <= OIN[SOB[o, i]]; j++) {
      it = OI[SOB[o, i], j]; id = ident(it)
      if (SOP[o] == "UNION" && i == 2 && ((o, 1, id) in SEEN)) continue
      if (SOP[o] == "COMPLEMENT" && ((o, 2, id) in SEEN)) continue
      if (SOP[o] == "INTERSECTION" && n > 1 && !((o, 2, id) in SEEN)) continue
      addto(o, it)
    }
  }
  OF_[o] = OBAD[o] ? "error" : OIN[o] ? "complete" : "none"
}

# ---------------------------------------------------------------- files
function iswsl(  l) { if (WSL == "") { WSL = 0; if ((getline l < "/proc/version") > 0 && tolower(l) ~ /microsoft/) WSL = 1; close("/proc/version") } return WSL }
function fsprune(st, how,   s, n, i, t) {
  if (how == "defined") return "-xdev "
  if (st ~ /^\/(proc|sys)(\/|$)/) return ""
  if (SYS != "Linux") return (how == "local" && (SYS == "AIX" || SYS == "SunOS")) ? "-fstype nfs -prune -o " : ""
  s = "proc sysfs"
  if (how != "all") s = s " nfs nfs4 cifs smb3 smbfs 9p drvfs afs ncpfs autofs fuse.sshfs ceph glusterfs fuse.glusterfs"
  else if (iswsl()) s = s " 9p drvfs"   # the drives of the Windows PC are not part of this system
  n = split(s, FST, " "); t = ""
  for (i = 1; i <= n; i++) t = t (i > 1 ? " -o " : "") "-fstype " FST[i]
  return "\\( " t " \\) -prune -o "
}
function slashes(s) { gsub(/\/\/+/, "/", s); return s }
# every path under START (dirs: only directories). Returns the list file
function walk(st, how, types,   t) {
  t = types == "d" ? "-type d " : types == "f" ? "\\( -type f -o -type l \\) " : ""
  return cached("find " sq(st == "/" ? "/" : st "/") " " fsprune(st, how) t "-print")
}
function addpath(p) { p = slashes(p); if (length(p) > 1 && substr(p, length(p), 1) == "/") p = substr(p, 1, length(p) - 1); if ((FGEN, p) in FSEEN) return; FSEEN[FGEN, p] = 1; FLN++; FL[FLN] = p }
function adddir(p) { p = slashes(p); if (length(p) > 1 && substr(p, length(p), 1) == "/") p = substr(p, 1, length(p) - 1); if ((FGEN, "d", p) in FSEEN) return; FSEEN[FGEN, "d", p] = 1; DLN++; DL[DLN] = p }
function isthere(p, t,   c, x) { x = ""; c = "[ " t " " sq(p) " ] && echo y"; c | getline x; close(c); return x == "y" }
function depthof(p,   n) { return split(p, DPT, "/") }
# candidate paths of an object with filepath, or path + filename. 1 = fine, 0 = not supported
function listpaths(o, types,   i, j, n, m, v, f, l, how, rec, maxd, base, q, d, c, nm, np, fop, nd) {
  FLN = 0; FGEN++; DLN = 0
  how = (o, "recurse_file_system") in OB ? OB[o, "recurse_file_system"] : "all"
  if (hasobj(o, "filepath")) {
    n = entn(o, "filepath")
    for (i = 1; i <= n; i++) {
      v = entv(o, "filepath", i)
      if (OEP[o, "filepath"] == "equals") { if (v != "") addpath(v); continue }
      if (OEP[o, "filepath"] != "pattern match") return 0
      m = starts(v)
      if (m < 0) return 0
      for (j = 1; j <= m; j++) { Q1[j] = PS[j]; Q2[j] = PE[j] }
      for (j = 1; j <= m; j++) {
        if (Q2[j]) { addpath(Q1[j]); continue }
        f = walk(Q1[j], how, types)
        while ((getline l < f) > 0) { l = slashes(l); if (rematch(v, l, "") == "true") addpath(l) }
        close(f)
      }
    }
    if (n > 1 && OEV[o, "filepath"] == "all") for (i = 1; i <= FLN; i++) if (!objmatch(o, "filepath", FL[i])) FL[i] = ""
    return 1
  }
  if (!hasobj(o, "path")) return 0
  n = entn(o, "path")
  for (i = 1; i <= n; i++) {
    v = entv(o, "path", i)
    if (OEP[o, "path"] == "equals") { if (v != "") adddir(v); continue }
    if (OEP[o, "path"] != "pattern match") return 0
    m = starts(v)
    if (m < 0) return 0
    for (j = 1; j <= m; j++) { Q1[j] = PS[j]; Q2[j] = PE[j] }
    for (j = 1; j <= m; j++) {
      if (Q2[j]) { adddir(Q1[j]); continue }
      f = walk(Q1[j], how, "d")
      while ((getline l < f) > 0) { l = slashes(l); if (length(l) > 1 && substr(l, length(l), 1) == "/") l = substr(l, 1, length(l) - 1); if (rematch(v, l, "") == "true") adddir(l) }
      close(f)
    }
  }
  rec = OB[o, "recurse_direction"]; maxd = (o, "max_depth") in OB ? OB[o, "max_depth"] + 0 : -1
  if (rec == "up") return 0
  fop = hasobj(o, "filename") ? (OEX[o, "filename"] == "nil" ? "nil" : OEP[o, "filename"]) : "nil"
  nd = DLN
  for (i = 1; i <= nd; i++) {
    d = DL[i]
    if (rec == "down") {
      base = depthof(d == "/" ? "" : d)
      f = walk(d, how, fop == "nil" ? "d" : types)
      while ((getline l < f) > 0) {
        l = slashes(l)
        if (length(l) > 1 && substr(l, length(l), 1) == "/") l = substr(l, 1, length(l) - 1)
        if (fop == "nil") { if (maxd < 0 || depthof(l) - base <= maxd) addpath(l); continue }
        if (l == d) continue
        if (maxd >= 0 && depthof(l) - 1 - base > maxd) continue
        if (objmatch(o, "filename", basepart(l))) addpath(l)
      }
      close(f)
    } else if (fop == "nil") addpath(d)
    else if (fop == "equals") { np = entn(o, "filename"); for (j = 1; j <= np; j++) addpath(joinpath(d, entv(o, "filename", j))) }
    else {
      c = "ls -a " sq(d == "/" ? d : d "/") " 2>/dev/null"
      while ((c | getline l) > 0) if (l != "." && l != ".." && objmatch(o, "filename", l)) addpath(joinpath(d, l))
      close(c)
    }
  }
  return 1
}
# whole file into BUF (BLEN). 1 read, 0 can't be read, -1 is not there
function slurp(p,   l, n, b, m, r, i) {
  if (p == LASTF) { BUF = LASTB; BLEN = length(BUF); return LASTR }
  n = 0; m = 0; b = ""
  r = -1
  if (isthere(p, "-f")) {
    if (!isthere(p, "-r")) r = 0
    else {
      r = 1
      while ((getline l < p) > 0) {
        b = b l "\n"
        if (++n == 100) { SLB[++m] = b; b = ""; n = 0 }
      }
      close(p)
    }
  }
  BUF = ""
  if (m) {   # joined in pairs: much faster than one growing string
    SLB[++m] = b
    while (m > 1) { n = 0; for (i = 1; i <= m; i += 2) { n++; SLB[n] = SLB[i] (i < m ? SLB[i + 1] : "") } m = n }
    BUF = SLB[1]
  } else BUF = b
  LASTF = p; LASTB = BUF; LASTR = r; BLEN = length(BUF)
  return r
}
function p_text(o,   i, j, k, n, p, v, fl, r, f, from, inst, it, s, iop, stopat, np, got) {
  if (!listpaths(o, "f")) return "error"
  for (i = 1; i <= FLN; i++) TFL[o, i] = FL[i]
  n = FLN
  fl = (OB[o, "multiline"] == "false" ? "" : "m") (OB[o, "singleline"] == "true" ? "s" : "") (OB[o, "ignore_case"] == "true" ? "i" : "")
  np = entn(o, "pattern")
  if (OEP[o, "pattern"] != "pattern match") return "error"
  stopat = (hasobj(o, "instance") && OEX[o, "instance"] == "lit" && OEP[o, "instance"] == "equals") ? OEA[o, "instance"] + 0 : 0
  for (i = 1; i <= n; i++) {
    f = TFL[o, i]
    if (f == "") continue
    r = slurp(f)
    if (r < 0) continue
    if (r == 0) { OBAD[o] = 1; note("cannot read " f); continue }
    for (j = 1; j <= np; j++) {
      p = re(entv(o, "pattern", j), fl)
      if (!p) { note("pattern not supported (" RERR "): " oneline(entv(o, "pattern", j))); return "error" }
      from = 1; inst = 0
      slurp(f)
      while (from <= BLEN + 1 && search(p, from)) {
        inst++
        k = MEND > MBEG ? MEND : MEND + 1
        if (!hasobj(o, "instance") || objmatch(o, "instance", inst)) {
          it = newitem("textfilecontent54")
          put(it, "filepath", f); put(it, "path", dirpart(f)); put(it, "filename", basepart(f))
          put(it, "pattern", entv(o, "pattern", j)); put(it, "instance", inst)
          put(it, "text", substr(BUF, MBEG, MEND - MBEG))
          s = ""
          for (r = 1; r <= RCAPS[p]; r++) if (CAP[r * 2 + 1] > 0) s = s (s == "" && r == 1 ? "" : SEP) substr(BUF, CAP[r * 2], CAP[r * 2 + 1] - CAP[r * 2])
          if (RCAPS[p] > 0) put(it, "subexpression", s)
          from = k
          if (OFN[o]) { addto(o, it); slurp(f) } else addto(o, it)
        } else from = k
        if (stopat && inst >= stopat) break
      }
      if (RERR != "") { note(RERR ": " f); return "error" }
    }
  }
  return "ok"
}
# one "ls -ldn" line -> item NI+1 (kept only when the caller keeps it)
function lsitem(l, kind,   i, m, uid, gid, sz, rest, n, it, t, p) {
  rest = l
  for (n = 1; n <= 8; n++) {
    sub(/^[ \t]+/, "", rest); i = match(rest, /[ \t]/)
    if (!i) return 0
    t = substr(rest, 1, i - 1); rest = substr(rest, i)
    if (n == 1) m = t; else if (n == 3) uid = t; else if (n == 4) gid = t
    else if (n == 5) { sz = t; if (substr(t, length(t), 1) == ",") { sub(/^[ \t]+/, "", rest); i = match(rest, /[ \t]/); rest = substr(rest, i); sz = 0 } }
  }
  p = substr(rest, 2)
  t = substr(m, 1, 1)
  if (t == "l") { i = index(p, " -> "); if (i) p = substr(p, 1, i - 1) }
  if (substr(p, 1, 1) != "/") return 0
  p = slashes(p)
  it = NI + 1; IK[it] = kind
  put(it, "filepath", p); put(it, "path", dirpart(p)); put(it, "filename", basepart(p))
  put(it, "mode", m); put(it, "user_id", uid); put(it, "group_id", gid); put(it, "size", sz)
  put(it, "type", t == "-" ? "regular" : t == "d" ? "directory" : t == "l" ? "symbolic link" : t == "c" ? "character special" : t == "b" ? "block special" : t == "p" ? "fifo" : t == "s" ? "socket" : "unknown")
  if (t == "d" && OFILENIL) { put(it, "path", p); put(it, "filename", "") }
  return it
}
function p_file(o,   i, n, c, l, it, how, st, f, rec, maxd, base, r, b, batch) {
  OFILENIL = hasobj(o, "filename") && OEX[o, "filename"] == "nil"
  # a whole tree: let find run ls, instead of one ls per file
  if (hasobj(o, "path") && OEP[o, "path"] == "equals" && OB[o, "recurse_direction"] == "down") {
    how = (o, "recurse_file_system") in OB ? OB[o, "recurse_file_system"] : "all"
    maxd = (o, "max_depth") in OB ? OB[o, "max_depth"] + 0 : -1
    n = entn(o, "path")
    for (i = 1; i <= n; i++) {
      st = entv(o, "path", i)
      if (length(st) > 1 && substr(st, length(st), 1) == "/") st = substr(st, 1, length(st) - 1)
      if (st == "") continue
      base = depthof(st == "/" ? "" : st)
      f = cached("find " sq(st == "/" ? "/" : st "/") " " fsprune(st, how) (OFILENIL ? "-type d " : "") "-exec ls -ldn {} +")
      while ((getline l < f) > 0) {
        it = lsitem(l, "file")
        if (!it) continue
        l = IV[it, "filepath"]
        if (length(l) > 1 && substr(l, length(l), 1) == "/") { l = substr(l, 1, length(l) - 1); put(it, "filepath", l); put(it, "path", OFILENIL ? l : dirpart(l)); put(it, "filename", OFILENIL ? "" : basepart(l)) }
        if (OFILENIL) { if (maxd >= 0 && depthof(l) - base > maxd) continue }
        else {
          if (l == st) continue
          if (maxd >= 0 && depthof(l) - 1 - base > maxd) continue
          if (IV[it, "type"] == "directory" || !objmatch(o, "filename", basepart(l))) continue   # a file name never means a directory
        }
        if (addto(o, it)) NI = it
      }
      close(f)
    }
    return "ok"
  }
  if (!listpaths(o, "")) return "error"
  n = FLN; batch = ""
  for (i = 1; i <= n; i++) if (FL[i] != "") {
    batch = batch " " sq(FL[i])
    if (length(batch) > 6000) { lsbatch(o, batch); batch = "" }
  }
  if (batch != "") lsbatch(o, batch)
  return "ok"
}
function lsbatch(o, b,   c, l, it, n, i) {
  c = "ls -ldn" b " 2>/dev/null"; n = 0
  while ((c | getline l) > 0) { n++; LSL[n] = l }
  close(c)
  for (i = 1; i <= n; i++) { it = lsitem(LSL[i], "file"); if (it && (OFILENIL || IV[it, "type"] != "directory") && addto(o, it)) NI = it }
}
function p_symlink(o,   n, i, v, c, l, it) {
  n = entn(o, "filepath")
  for (i = 1; i <= n; i++) {
    v = entv(o, "filepath", i)
    if (!isthere(v, "-h")) continue
    l = ""
    if (has("readlink")) { c = "readlink -f " sq(v) " 2>/dev/null"; c | getline l; close(c) }
    if (l == "") return "error"
    it = newitem("symlink"); put(it, "filepath", v); put(it, "canonical_path", l); addto(o, it)
  }
  return "ok"
}
function p_hash(o,   n, i, m, j, t, c, l, it, cmd) {
  if (!listpaths(o, "f")) return "error"
  n = FLN
  for (i = 1; i <= n; i++) HFL[i] = FL[i]
  for (i = 1; i <= n; i++) {
    if (HFL[i] == "" || !isthere(HFL[i], "-f")) continue
    m = split("MD5 SHA-1 SHA-224 SHA-256 SHA-384 SHA-512", HTY, " ")
    for (j = 1; j <= m; j++) {
      t = HTY[j]
      if (!objmatch(o, "hash_type", t)) continue
      cmd = tolower(t); sub(/-/, "", cmd)
      if (has(cmd "sum")) c = cmd "sum " sq(HFL[i])
      else if (has("openssl")) c = "openssl dgst -" cmd " -r " sq(HFL[i])
      else return "error"
      l = ""; (c " 2>/dev/null") | getline l; close(c " 2>/dev/null")
      sub(/[ \t].*$/, "", l)
      if (l == "") { OBAD[o] = 1; continue }
      it = newitem("filehash58"); put(it, "filepath", HFL[i]); put(it, "path", dirpart(HFL[i])); put(it, "filename", basepart(HFL[i]))
      put(it, "hash_type", t); put(it, "hash", l); addto(o, it)
    }
  }
  return "ok"
}

# ---------------------------------------------------------------- packages
# a tool that fails must never look like "nothing installed": the last line proves it finished
function p_dpkg(o,   f, l, it, i, e, v, r, ok) {
  if (!has("dpkg-query")) return "na"
  f = cached("dpkg-query -W -f='${Package}\\t${Architecture}\\t${Version}\\t${Status}\\n' && echo __sx_ok__")
  ok = 0
  while ((getline l < f) > 0) {
    if (l == "__sx_ok__") { ok = 1; continue }
    if (split(l, DPK, "\t") < 4 || DPK[4] !~ / installed$/) continue
    if (!objmatch(o, "name", DPK[1])) continue
    it = newitem("dpkginfo"); v = DPK[3]
    put(it, "name", DPK[1]); put(it, "arch", DPK[2])
    i = index(v, ":"); e = 0
    if (i) { e = substr(v, 1, i - 1); v = substr(v, i + 1) }
    r = ""; i = 0
    while (match(substr(v, i + 1), /-/)) i += RSTART
    if (i) { r = substr(v, i + 1); v = substr(v, 1, i - 1) }
    put(it, "epoch", e); put(it, "version", v); put(it, "release", r)
    put(it, "evr", e ":" v "-" r)
    addto(o, it)
  }
  close(f)
  if (!ok) note("dpkg-query failed: the package database can not be read")
  return ok ? "ok" : "error"
}
function p_rpm(o,   f, l, it, n, e, k, ok) {
  if (!has("rpm")) return has("dpkg-query") ? "ok" : "na"
  f = cached("rpm -qa --qf '%{NAME}\\t%{ARCH}\\t%{EPOCH}\\t%{VERSION}\\t%{RELEASE}\\t%{SIGPGP:pgpsig} %{RSAHEADER:pgpsig}\\n' && echo __sx_ok__")
  ok = 0
  while ((getline l < f) > 0) {
    if (l == "__sx_ok__") { ok = 1; continue }
    n = split(l, RPK, "\t")
    if (n < 5 || !objmatch(o, "name", RPK[1])) continue
    it = newitem("rpminfo")
    put(it, "name", RPK[1]); put(it, "arch", RPK[2]); put(it, "epoch", RPK[3]); put(it, "version", RPK[4]); put(it, "release", RPK[5])
    e = RPK[3] == "(none)" ? "0" : RPK[3]
    put(it, "evr", e ":" RPK[4] "-" RPK[5])
    k = "0"
    if (match(RPK[6], /Key ID [0-9a-fA-F]+/)) { k = tolower(substr(RPK[6], RSTART + 7, RLENGTH - 7)); k = substr(k, length(k) - 15) }
    put(it, "signature_keyid", k)
    put(it, "extended_name", RPK[1] "-" e ":" RPK[4] "-" RPK[5] "." RPK[2])
    addto(o, it)
  }
  close(f)
  if (!ok) note("rpm failed: the package database can not be read")
  return ok ? "ok" : "error"
}

# ---------------------------------------------------------------- system
function p_family(o,   it) { it = newitem("family"); put(it, "family", "unix"); addto(o, it); return "ok" }
function cmd1(c,   l) { l = ""; (c " 2>/dev/null") | getline l; close(c " 2>/dev/null"); return l }
function p_uname(o,   it) {
  it = newitem("uname")
  put(it, "machine_class", cmd1("uname -m")); put(it, "node_name", cmd1("uname -n")); put(it, "os_name", cmd1("uname -s"))
  put(it, "os_release", cmd1("uname -r")); put(it, "os_version", cmd1("uname -v"))
  put(it, "processor_type", cmd1("uname -p"))
  if (IV[it, "processor_type"] == "unknown" || IV[it, "processor_type"] == "") put(it, "processor_type", cmd1("uname -m"))
  addto(o, it)
  return "ok"
}
function unoct(s,   o, i) {   # \040 in /proc/mounts
  o = ""
  while ((i = index(s, "\\")) > 0 && substr(s, i + 1, 3) ~ /^[0-7][0-7][0-7]$/) {
    o = o substr(s, 1, i - 1) CHR[substr(s, i + 1, 1) * 64 + substr(s, i + 2, 1) * 8 + substr(s, i + 3, 1)]
    s = substr(s, i + 4)
  }
  return o s
}
function p_partition(o,   f, l, n, it, mp, r) {
  if (SYS == "Linux") f = "/proc/mounts"
  else if (SYS == "AIX") f = cached("mount | awk 'NR > 2 { if (substr($0, 1, 1) == \" \") print $1, $2, $3, $NF; else print $1 \":\" $2, $3, $4, $NF }'")
  else return "error"
  r = 0
  while ((getline l < f) > 0) {
    r = 1
    n = split(l, MNT, " "); mp = unoct(MNT[2])
    if (n < 3 || MNT[1] == "rootfs" || MNT[3] == "autofs" || !objmatch(o, "mount_point", mp)) continue
    it = newitem("partition")
    put(it, "mount_point", mp); put(it, "device", unoct(MNT[1])); put(it, "fs_type", MNT[3])
    l = MNT[4]; gsub(/,/, SEP, l); put(it, "mount_options", l)
    addto(o, it)
  }
  close(f)
  return r ? "ok" : "error"
}
function p_sysctl(o,   f, l, i, n, it, nm, v, c) {
  if (!has("sysctl")) return "na"
  if (OEP[o, "name"] == "equals") {
    n = entn(o, "name")
    for (i = 1; i <= n; i++) {
      nm = entv(o, "name", i); v = ""; c = 0
      f = cached("sysctl -n " sq(nm) " && echo __sx_ok__")
      while ((getline l < f) > 0) { if (l == "__sx_ok__") { c = 1; break } v = v (v == "" ? "" : "\n") l }
      close(f)
      if (!c) continue
      gsub(/[ \t]+/, "\t", v)
      it = newitem("sysctl"); put(it, "name", nm); put(it, "value", v); addto(o, it)
    }
    return "ok"
  }
  f = cached("sysctl -a")
  while ((getline l < f) > 0) {
    i = index(l, "=")
    if (!i) continue
    nm = substr(l, 1, i - 1); v = substr(l, i + 1)
    gsub(/[ \t]/, "", nm); sub(/^[ \t]+/, "", v); gsub(/[ \t]+/, "\t", v)
    if (!objmatch(o, "name", nm)) continue
    it = newitem("sysctl"); put(it, "name", nm); put(it, "value", v); addto(o, it)
  }
  close(f)
  return "ok"
}
function units(   f, l) {
  if (UNITSOK) return
  UNITSOK = 1; UN = 0
  f = cached("{ systemctl list-unit-files --no-legend --no-pager; systemctl list-units --all --no-legend --no-pager --plain || echo SX-NO-SYSTEMD; } | awk '{ u = $1; if (u !~ /[A-Za-z0-9]/) u = $2; if (!(u in s)) { s[u] = 1; print u } }'")
  while ((getline l < f) > 0) { if (l == "SX-NO-SYSTEMD") UNBAD = 1; else { UN++; UNIT[UN] = l } }
  close(f)
}
function p_unitprop(o,   i, f, l, it, nm, v, k, m, j) {
  if (!has("systemctl")) return "na"
  units()
  if (UNBAD) { note("systemd is not running, or cannot be asked"); return "error" }
  if (UN == 0) { note("systemctl gave no units"); return "error" }
  for (i = 1; i <= UN; i++) {
    if (!objmatch(o, "unit", UNIT[i])) continue
    f = cached("systemctl show --no-pager " sq(UNIT[i])); m = 0
    while ((getline l < f) > 0) {
      m++; k = index(l, "="); nm = substr(l, 1, k - 1)
      if (!k || !objmatch(o, "property", nm)) continue
      v = substr(l, k + 1)
      if (v == "yes") v = "true"; else if (v == "no") v = "false"
      if (nm ~ /^(Names|Wants|Requires|Requisite|RequiredBy|WantedBy|Before|After|Conflicts|BindsTo|PartOf|ConsistsOf|TriggeredBy|Triggers|Documentation|DropInPaths)$/) gsub(/ /, SEP, v)
      it = newitem("systemdunitproperty")
      put(it, "unit", UNIT[i]); put(it, "property", nm); put(it, "value", v)
      addto(o, it)
    }
    close(f)
    if (!m) { note("systemctl show failed"); return "error" }
  }
  return "ok"
}
function p_unitdep(o,   i, f, l, it, d) {
  if (!has("systemctl")) return "na"
  units()
  if (UNBAD) { note("systemd is not running, or cannot be asked"); return "error" }
  if (UN == 0) { note("systemctl gave no units"); return "error" }
  for (i = 1; i <= UN; i++) {
    if (!objmatch(o, "unit", UNIT[i])) continue
    f = cached("systemctl list-dependencies --plain --no-pager " sq(UNIT[i]))
    d = ""
    while ((getline l < f) > 0) {
      gsub(/[^A-Za-z0-9_.@:\\-]/, "", l)
      if (l == "" || l == UNIT[i]) continue
      d = d (d == "" ? "" : SEP) l
    }
    close(f)
    it = newitem("systemdunitdependency"); put(it, "unit", UNIT[i]); put(it, "dependency", d); addto(o, it)
  }
  return "ok"
}
function p_password(o,   f, l, n, it) {
  f = has("getent") ? cached("getent passwd") : "/etc/passwd"
  while ((getline l < f) > 0) {
    n = split(l, PWD, ":")
    if (n < 7 || !objmatch(o, "username", PWD[1])) continue
    it = newitem("password")
    put(it, "username", PWD[1]); put(it, "password", PWD[2]); put(it, "user_id", PWD[3]); put(it, "group_id", PWD[4])
    put(it, "gcos", PWD[5]); put(it, "home_dir", PWD[6]); put(it, "login_shell", PWD[7])
    addto(o, it)
  }
  close(f)
  return "ok"
}
function p_shadow(o,   l, n, it, r, i, e) {
  if (!isthere("/etc/shadow", "-f")) return "na"
  if (!isthere("/etc/shadow", "-r")) { note("cannot read /etc/shadow (run as root)"); return "error" }
  while ((getline l < "/etc/shadow") > 0) {
    n = split(l, SHD, ":")
    if (n < 8 || !objmatch(o, "username", SHD[1])) continue
    it = newitem("shadow")
    put(it, "username", SHD[1]); put(it, "password", SHD[2]); put(it, "chg_lst", SHD[3]); put(it, "chg_allow", SHD[4]); put(it, "chg_req", SHD[5])
    put(it, "exp_warn", SHD[6]); put(it, "exp_inact", SHD[7]); put(it, "exp_date", SHD[8]); put(it, "flag", SHD[9])
    e = substr(SHD[2], 1, 3)
    put(it, "encrypt_method", e == "$1$" ? "MD5" : substr(e, 1, 2) == "$2" ? "Blowfish" : e == "$5$" ? "SHA-256" : e == "$6$" ? "SHA-512" : e == "$y$" ? "Yescrypt" : "DES")
    addto(o, it)
  }
  close("/etc/shadow")
  return "ok"
}
function p_env(o,   c, l, pid, i, it, any) {
  if (hasobj(o, "pid") && OEX[o, "pid"] != "nil") {
    if (!isthere("/proc/1", "-d") || SYS != "Linux") return "na"
    c = "for p in /proc/[0-9]*; do i=${p#/proc/}; if [ -r $p/environ ]; then tr '\\000\\012' '\\012 ' < $p/environ | sed \"s/^/$i /\"; else echo \"$i\"; fi; done 2>/dev/null"
    while ((c | getline l) > 0) {
      i = index(l, " "); pid = i ? substr(l, 1, i - 1) : l
      if (!i) { if (objmatch(o, "pid", pid)) OBAD[o] = 1; continue }
      if (!objmatch(o, "pid", pid)) continue
      l = substr(l, i + 1); i = index(l, "=")
      if (!i || !objmatch(o, "name", substr(l, 1, i - 1))) continue
      it = newitem("environmentvariable58"); put(it, "pid", pid); put(it, "name", substr(l, 1, i - 1)); put(it, "value", substr(l, i + 1)); addto(o, it)
    }
    close(c)
    return "ok"
  }
  for (l in ENVIRON) if (objmatch(o, "name", l)) { it = newitem("environmentvariable58"); put(it, "name", l); put(it, "value", ENVIRON[l]); addto(o, it) }
  return "ok"
}
function p_variable(o,   v, i, r, it, n) {
  v = OEA[o, "var_ref"]; r = val(v)
  if (r == "error") return "error"
  n = VN[v]
  for (i = 1; i <= n; i++) { it = newitem("variable"); put(it, "var_ref", v); put(it, "value", VV[v, i]); addto(o, it) }
  return "ok"
}
function p_interface(o,   c, l, n, it, i, fl, nm, a) {
  if (!has("ip")) return "na"
  if (cmd1("ip -o addr show >/dev/null && echo y") != "y") return "error"
  c = "ip -o addr show 2>/dev/null"
  while ((c | getline l) > 0) {
    n = split(l, IFX, " "); nm = IFX[2]; sub(/@.*$/, "", nm); sub(/:$/, "", nm)
    if (!objmatch(o, "name", nm)) continue
    it = newitem("interface"); put(it, "name", nm); a = IFX[4]; sub(/\/.*$/, "", a); put(it, "inet_addr", a)
    fl = cmd1("ip -o link show dev " sq(nm))
    put(it, "type", index(fl, "link/ether") ? "ARPHRD_ETHER" : index(fl, "link/loopback") ? "ARPHRD_LOOPBACK" : "")
    if (match(fl, /<[^>]*>/)) { fl = substr(fl, RSTART + 1, RLENGTH - 2); gsub(/,/, SEP, fl) } else fl = ""
    put(it, "flag", fl)
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_listen(o,   c, l, n, it, a, pr, ad, po, i) {
  if (!has("ss")) return "error"
  if (cmd1("ss -lnt >/dev/null && ss -lnu >/dev/null && echo y") != "y") return "error"
  c = "{ ss -lnt | sed -e 1d -e 's/^/tcp /'; ss -lnu | sed -e 1d -e 's/^/udp /'; } 2>/dev/null"
  while ((c | getline l) > 0) {
    n = split(l, SSX, " "); pr = SSX[1]; a = SSX[5]
    i = 0
    while (match(substr(a, i + 1), /:/)) i += RSTART
    ad = substr(a, 1, i - 1); po = substr(a, i + 1)
    sub(/%.*$/, "", ad); gsub(/[][]/, "", ad)
    if (ad == "*") ad = "::"
    if (!objmatch(o, "protocol", pr) || !objmatch(o, "local_address", ad) || !objmatch(o, "local_port", po)) continue
    it = newitem("inetlisteningservers"); put(it, "protocol", pr); put(it, "local_address", ad); put(it, "local_port", po); put(it, "local_full_address", ad ":" po)
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_process(o,   c, l, n, it, i, cl) {
  c = "ps -e -o pid= -o ppid= -o ruid= -o uid= -o args= 2>/dev/null"
  if (SYS != "Linux") return "error"
  while ((c | getline l) > 0) {
    n = split(l, PSX, " ")
    cl = l; for (i = 1; i <= 4; i++) sub(/^[ \t]*[^ \t]+[ \t]/, "", cl)
    if (hasobj(o, "command_line") && OEX[o, "command_line"] != "nil" && !objmatch(o, "command_line", cl)) continue
    if (hasobj(o, "pid") && OEX[o, "pid"] != "nil" && !objmatch(o, "pid", PSX[1])) continue
    it = newitem("process58"); put(it, "pid", PSX[1]); put(it, "ppid", PSX[2]); put(it, "ruid", PSX[3]); put(it, "user_id", PSX[4]); put(it, "command_line", cl)
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_runlevel(o,   c, l, n, it, s, rl, k) {
  c = "for d in /etc/rc[0-6].d /etc/rc.d/rc[0-6].d; do [ -d $d ] && ls $d | sed \"s|^|$d |\"; done 2>/dev/null"
  while ((c | getline l) > 0) {
    n = split(l, RLX, " ")
    if (RLX[2] !~ /^[SK][0-9][0-9]/) continue
    rl = RLX[1]; sub(/\.d$/, "", rl); rl = substr(rl, length(rl)); s = substr(RLX[2], 4); k = substr(RLX[2], 1, 1)
    if ((o, s, rl) in RLSEEN || !objmatch(o, "service_name", s) || !objmatch(o, "runlevel", rl)) continue
    RLSEEN[o, s, rl] = 1
    it = newitem("runlevel"); put(it, "service_name", s); put(it, "runlevel", rl); put(it, "start", k == "S" ? "true" : "false"); put(it, "kill", k == "K" ? "true" : "false")
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_sebool(o,   c, l, n, it) {
  if (!has("sestatus")) return "na"
  c = "sestatus -b 2>/dev/null | awk 'b { print $1, $2 } /booleans:/ { b = 1 }'"
  while ((c | getline l) > 0) {
    n = split(l, SEB, " ")
    if (n < 2 || !objmatch(o, "name", SEB[1])) continue
    it = newitem("selinuxboolean"); put(it, "name", SEB[1]); put(it, "current_status", SEB[2] == "on" ? "true" : "false")
    put(it, "pending_status", SEB[2] == "on" ? "true" : "false"); addto(o, it)
  }
  close(c)
  return "ok"
}
function p_secontext(o,   i, n, l, it, c) {
  if (!listpaths(o, "")) return "error"
  n = FLN
  for (i = 1; i <= n; i++) SCF[i] = FL[i]
  for (i = 1; i <= n; i++) {
    if (SCF[i] == "") continue
    l = cmd1("ls -dZ " sq(SCF[i]))
    if (l == "") continue
    if (!match(l, /[^ \t:]+:[^ \t:]+:[^ \t:]+(:[^ \t]+)?/)) return "na"
    split(substr(l, RSTART, RLENGTH), SCX, ":")
    it = newitem("selinuxsecuritycontext"); put(it, "filepath", SCF[i]); put(it, "path", dirpart(SCF[i])); put(it, "filename", basepart(SCF[i]))
    put(it, "user", SCX[1]); put(it, "role", SCX[2]); put(it, "type", SCX[3]); addto(o, it)
  }
  return "ok"
}

# ---------------------------------------------------------------- AIX
function p_fileset(o,   f, l, n, it, s, ok) {
  if (!has("lslpp")) return "na"
  f = cached("lslpp -Lcq all")
  ok = 0
  while ((getline l < f) > 0) {
    n = split(l, LPP, ":")
    if (n >= 6) ok = 1
    if (n < 6 || !objmatch(o, "flstinst", LPP[2])) continue
    it = newitem("fileset"); put(it, "flstinst", LPP[2]); put(it, "level", LPP[3]); put(it, "description", LPP[8])
    s = LPP[6]
    put(it, "state", s ~ /^A/ ? "APPLIED" : s ~ /^C/ ? "COMMITTED" : s ~ /^B/ ? "BROKEN" : s ~ /^E/ ? "LOCKED" : s ~ /^O/ ? "OBSOLETE" : s)
    addto(o, it)
  }
  close(f)
  return ok ? "ok" : "error"
}
function p_oslevel(o,   l, it) {
  if (!has("oslevel")) return "na"
  l = cmd1("oslevel"); if (l == "") return "error"
  it = newitem("oslevel"); put(it, "maintenance_level", l); addto(o, it)
  return "ok"
}
function p_no(o,   f, l, i, nm, v, it, ok) {
  if (SYS != "AIX") return "na"
  f = cached("no -a")
  while ((getline l < f) > 0) {
    i = index(l, "="); if (!i) continue
    ok = 1
    nm = substr(l, 1, i - 1); v = substr(l, i + 1); gsub(/[ \t]/, "", nm); sub(/^[ \t]+/, "", v)
    if (!objmatch(o, "tunable", nm)) continue
    it = newitem("no"); put(it, "tunable", nm); put(it, "value", v); addto(o, it)
  }
  close(f)
  return ok ? "ok" : "error"
}
function p_ifix(o,   f, l, n, it) {
  if (!has("emgr")) return "na"
  f = cached("emgr -l; echo __sx_rc__ $?")   # "no efix data" may come with any exit code, but says so
  while ((getline l < f) > 0) {
    n = split(l, EMG, " ")
    if (EMG[1] !~ /^[0-9]+$/ || n < 3 || !objmatch(o, "vuid", EMG[3])) continue
    it = newitem("interim_fix"); put(it, "state", EMG[2]); put(it, "label", EMG[3]); put(it, "vuid", EMG[3]); addto(o, it)
  }
  close(f)
  return "ok"
}

# ---------------------------------------------------------------- states, tests, definitions
function statent(s, i, v,   e, n, j, r, w, t) {   # one item value against one state entity
  if (SEX[s, i] != "var") return cmpval(SEP_[s, i], SED[s, i], v, SEA[s, i])
  w = SEA[s, i]; r = val(w)
  if (r != "ok") return r == "none" ? "unknown" : "error"
  # every variable value counts, joined by var_check
  n = VN[w]
  CT = CF = CE = CU = CV = CA = 0
  for (j = 1; j <= n; j++) tally(cmpval(SEP_[s, i], SED[s, i], v, VV[w, j]))
  return bycheck(SEV[s, i], CT, CF, CE, CU, CV, CA)
}
function evalstate(s, it,   i, j, n, e, r, t, f, er, u, v, a, t2, f2, e2, u2, v2, a2, vals) {
  t = f = er = u = v = a = 0
  if (!(s in SOPR)) return "error"
  for (i = 1; i <= SEN[s]; i++) {
    e = SEL[s, i]
    if (SEX[s, i] == "var") val(SEA[s, i])   # may run probes: do it before the loops below
    if (!hasent(it, e)) r = "false"
    else {
      vals = getent(it, e)
      n = 0
      if (index(vals, SEP)) {
        t2 = f2 = e2 = u2 = v2 = a2 = 0
        while (1) {
          j = index(vals, SEP)
          r = statent(s, i, j ? substr(vals, 1, j - 1) : vals)
          if (r == "true") t2++; else if (r == "false") f2++; else if (r == "error") e2++; else if (r == "unknown") u2++; else v2++
          if (!j) break
          vals = substr(vals, j + 1)
        }
        r = bycheck(SEC[s, i], t2, f2, e2, u2, v2, a2)
      } else {
        r = statent(s, i, vals)
        if (SEC[s, i] ~ /^none/) r = flip(r)
      }
    }
    if (r == "true") t++; else if (r == "false") f++; else if (r == "error") er++; else if (r == "unknown") u++; else if (r == "not evaluated") v++; else a++
  }
  if (SEN[s] == 0) return "true"
  return byop(SOPR[s], t, f, er, u, v, a)
}
function existence(ce, n) {
  if (ce == "none_exist") return n == 0
  if (ce == "only_one_exists") return n == 1
  if (ce == "any_exist") return 1
  return n > 0   # at_least_one_exists, all_exist
}
function evaltest(t,   o, f, r, i, j, n, st, sf, se, su, sv, sa, t1, f1, e1, u1, v1, a1) {
  if (t in TR) return TR[t]
  TR[t] = "error"
  if (TK[t] == "?") { TR[t] = "not evaluated"; trace(t, 0); return TR[t] }
  if (TK[t] == "unknown") { TR[t] = "unknown"; return TR[t] }
  o = TO[t]; collect(o); f = OF_[o]
  if (f == "error") r = "error"
  else if (f == "na") r = "not applicable"
  else if (f == "nc") r = "not evaluated"
  else if (f == "none") r = existence(TE[t], 0) ? "true" : "false"
  else {
    n = OIN[o]
    r = existence(TE[t], n) ? "true" : "false"
    if (r == "true" && TN[t] > 0 && n > 0) {
      t1 = f1 = e1 = u1 = v1 = a1 = 0
      for (i = 1; i <= n; i++) {
        st = sf = se = su = sv = sa = 0
        for (j = 1; j <= TN[t]; j++) {
          r = evalstate(TST[t, j], OI[o, i])
          if (r == "true") st++; else if (r == "false") sf++; else if (r == "error") se++; else if (r == "unknown") su++; else if (r == "not evaluated") sv++; else sa++
        }
        r = TN[t] == 1 ? r : byop(TSO[t], st, sf, se, su, sv, sa)
        if (r == "true") t1++; else if (r == "false") f1++; else if (r == "error") e1++; else if (r == "unknown") u1++; else if (r == "not evaluated") v1++; else a1++
      }
      r = bycheck(TC[t], t1, f1, e1, u1, v1, a1)
    }
  }
  TR[t] = r
  trace(t, f == "complete" ? OIN[o] : 0)
  return r
}
function trace(t, n,   i, o) {
  if (QUIET || NTR >= 14) return
  NTR++
  if (TK[t] == "?") { print "not evaluated: " TCM[t] " (" TO[t] ")"; return }
  print TR[t] ": " oneline(TCM[t]) " [" TK[t] ", " n " found]"
  o = TO[t]
  for (i = 1; i <= n && i <= 3; i++) print "   " show(OI[o, i])
}
function note(s) { if (!QUIET && NNOTE < 5) { NNOTE++; print "note: " s } }
function evaldef(d) {
  if (d in DRES) return DRES[d]
  DRES[d] = "error"
  if (!(d in DROOT)) return "error"
  if (DROOT[d] == "") { DRES[d] = "not evaluated"; return DRES[d] }
  DRES[d] = evalref(DROOT[d])
  return DRES[d]
}
function evalref(ref,   neg, k, id, r) {
  neg = 0
  if (substr(ref, 1, 1) == "!") { neg = 1; ref = substr(ref, 2) }
  k = substr(ref, 1, 1); id = substr(ref, 2)
  if (k == "T") r = evaltest(id)
  else if (k == "D") r = evaldef(id)
  else r = evalcrit(id)
  return neg ? flip(r) : r
}
function evalcrit(c,   i, r, t, f, e, u, v, a) {
  t = f = e = u = v = a = 0
  for (i = 1; i <= CN[c]; i++) {
    r = evalref(CC[c, i])
    if (r == "true") t++; else if (r == "false") f++; else if (r == "error") e++; else if (r == "unknown") u++; else if (r == "not evaluated") v++; else a++
  }
  r = byop(CO[c], t, f, e, u, v, a)
  return CG[c] == "1" ? flip(r) : r
}
# XCCDF result of a check reference: E<definition> or K<complex check>
function evalx(ref,   k, id, r, i, n, p) {
  k = substr(ref, 1, 1); id = substr(ref, 2)
  if (k == "E") {
    r = evaldef(id)
    if (DCL[id] == "vulnerability" || DCL[id] == "patch") r = flip(r)
    if (r == "true") return "pass"
    if (r == "false") return "fail"
    if (r == "not evaluated") return "notchecked"
    if (r == "not applicable") return "notapplicable"
    return r
  }
  if (k != "K") return "notchecked"
  for (i = 1; i <= CN[id]; i++) { r = evalx(CC[id, i]); XCNT[id, r]++ }
  if (CO[id] == "OR") p = "pass unknown error fail notchecked notapplicable"
  else p = "fail unknown error notchecked pass notapplicable"   # a part nobody checked is never a pass
  n = split(p, XPR, " "); r = "notchecked"
  for (i = 1; i <= n; i++) if (XCNT[id, XPR[i]] > 0) { r = XPR[i]; break }
  if (CG[id] == "1") { if (r == "pass") r = "fail"; else if (r == "fail") r = "pass" }
  return r
}

# ---------------------------------------------------------------- main
BEGIN {
  FS = "\t"
  srand(); NOW = srand()
  SEP = "\035"; PFALL = "\003"; MAXSTEPS = 3000000
  for (i = 1; i < 256; i++) { c = sprintf("%c", i); CHR[i] = c; ORD[c] = i }
  DIG = "0123456789"; LOW = "abcdefghijklmnopqrstuvwxyz"; UPP = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  WRD = LOW UPP DIG "_"; SPC = " \t\n\013\f\r"; PUN = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
  FPERM["uread"] = 2; FPERM["uwrite"] = 3; FPERM["uexec"] = 4; FPERM["suid"] = 4
  FPERM["gread"] = 5; FPERM["gwrite"] = 6; FPERM["gexec"] = 7; FPERM["sgid"] = 7
  FPERM["oread"] = 8; FPERM["owrite"] = 9; FPERM["oexec"] = 10; FPERM["sticky"] = 10; FPERM["has_extended_acl"] = 11
  NI = NN = NRE = NTR = NNOTE = NTMP = SP = 0; FGEN = 0; LASTF = ""
}
$1 == "R" { ROOT = $2; next }
$1 == "P" { PLAT = $2; next }
$1 == "C" || $1 == "K" { CO[$2] = $3; CG[$2] = $4; for (i = 5; i <= NF; i++) { CN[$2]++; CC[$2, CN[$2]] = $i } next }
$1 == "D" { DCL[$2] = $3; DROOT[$2] = $4; next }
$1 == "T" { TK[$2] = $3; TE[$2] = $4; TC[$2] = $5; TSO[$2] = $6; TO[$2] = $7; TCM[$2] = unesc($8); TN[$2] = 0; for (i = 9; i <= NF; i++) { TN[$2]++; TST[$2, TN[$2]] = $i } next }
$1 == "O" { OKIND[$2] = $3; OEN[$2] = 0; OFN[$2] = 0; OBAD[$2] = 0; next }
$1 == "OE" { OEN[$2]++; OEL[$2, OEN[$2]] = $3; OEP[$2, $3] = $4; OED[$2, $3] = $5; OEV[$2, $3] = $6; OEX[$2, $3] = $7; OEA[$2, $3] = unesc($8); next }
$1 == "OB" { OB[$2, $3] = $4; next }
$1 == "OS" { SOP[$2] = $3; SNUM[$2] = 0; for (i = 4; i <= NF; i++) { SNUM[$2]++; SOB[$2, SNUM[$2]] = $i } next }
$1 == "OF" { OFN[$2]++; OFA[$2, OFN[$2]] = $3; OFL[$2, OFN[$2]] = $4; next }
$1 == "S" { SOPR[$2] = $3; SEN[$2] = 0; next }
$1 == "SE" { SEN[$2]++; i = SEN[$2]; SEL[$2, i] = $3; SEP_[$2, i] = $4; SED[$2, i] = $5; SEC[$2, i] = $6; SEV[$2, i] = $7; SEX[$2, i] = $8; SEA[$2, i] = unesc($9); next }
$1 == "V" { VK[$2] = $3; VX[$2] = $4; VN[$2] = 0; next }
$1 == "VV" { VN[$2]++; VV[$2, VN[$2]] = unesc($3); next }
$1 == "X" { XK[$2] = $3; XC[$2] = NF - 3; for (i = 4; i <= NF; i++) XA[$2, i - 3] = unesc($i); next }
END {
  if (ROOT == "") exit 252
  if (PLAT != "") {
    QUIET = 1
    if (evalref(PLAT) != "true") { print "Not applicable on this server."; exit 250 }
    QUIET = 0
    for (t in TR) if (TR[t] == "error") delete TR[t]
  }
  r = evalx(ROOT)
  print "result: " r
  if (r == "pass") exit 0
  if (r == "fail") exit 1
  if (r == "notapplicable") exit 250
  if (r == "notchecked") exit 251
  if (r == "unknown") exit 253
  exit 252
}
SCRIPTIX_END_OF_FILE
chmod 644 './usr/share/scriptix/lib/oval.awk' || fail "chmod ./usr/share/scriptix/lib/oval.awk"
cat > './usr/share/scriptix/lib/runtime.sh' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write ./usr/share/scriptix/lib/runtime.sh"
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
SCRIPTIX_END_OF_FILE
chmod 644 './usr/share/scriptix/lib/runtime.sh' || fail "chmod ./usr/share/scriptix/lib/runtime.sh"
cat > './usr/share/scriptix/lib/scap.pl' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write ./usr/share/scriptix/lib/scap.pl"
#!/usr/bin/perl
# scriptix 2.6.0-20261124.230156 - reads SCAP files (data streams, XCCDF, OVAL) for the scriptix command.
# Plain Perl 5.8 or newer, no modules: AIX and most Linux systems have it already.
# It makes the same scripts as the ScriptIX app. The checks themselves run in sh and awk.
use strict;

my $VERSION = '2.6.0';
my $NS12 = 'http://checklists.nist.gov/xccdf/1.2';
my $OVALSYS = 'http://oval.mitre.org/XMLSchema/oval-definitions-5';
my $MAX = 400 * 1024 * 1024;
my $TAB = "\t";

sub fail { my $m = join('', @_); utf8::encode($m) if utf8::is_utf8($m); print STDERR "scriptix: $m\n"; exit 1 }

# ================================================================ XML
# node: [0 local name, 1 namespace, 2 attributes (text, then hash), 3 children, 4 start, 5 end, 6 raw name, 7 attribute order, 8 scope, 9 file]
my %FILES;   # file -> its bytes
my %ENT = (lt => '<', gt => '>', amp => '&', quot => '"', apos => "'");

sub ent {
  my ($s) = @_;
  utf8::decode($s) if $s =~ /[\x80-\xff]/;
  if (index($s, '&') >= 0) {
    $s =~ s/&(#x[0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]+);/
      my $e = $1;
      $e =~ m{^#x(.*)} ? pack('U', hex($1)) : $e =~ m{^#(.*)} ? pack('U', $1) : exists $ENT{$e} ? $ENT{$e} : die "unknown entity &$e;\n"/ge;
  }
  return $s;
}

sub parse_xml {
  my ($file) = @_;
  open(my $h, '<', $file) or die "cannot read $file: $!\n";
  binmode($h);
  die "$file is too big\n" if -s $h > $MAX;
  my $t; { local $/; $t = <$h>; } close($h);
  $t = '' unless defined $t;
  $t =~ s/^\xef\xbb\xbf//;
  die "$file: UTF-16 files are not supported\n" if $t =~ /^(?:\xff\xfe|\xfe\xff)/;
  if ($t =~ /^<\?xml[^>]*?encoding\s*=\s*["']([^"']+)["']/) {
    my $e = lc $1;
    if ($e eq 'iso-8859-1' || $e eq 'latin1') { utf8::encode($t) }
    elsif ($e ne 'utf-8' && $e ne 'utf8' && $e ne 'us-ascii' && $e ne 'ascii') { die "$file: encoding $1 is not supported\n" }
  }
  $t =~ s/\r\n?/\n/g;
  $FILES{$file} = \$t;
  my ($root, @stack);
  my $cur;
  my %top = (xml => 'http://www.w3.org/XML/1998/namespace', '' => '');
  my $scope = \%top;
  my $len = length $t;
  pos($t) = 0;
  while (pos($t) < $len) {
    if ($t =~ /\G([^<]+)/gc) {
      if ($cur) { push @{$cur->[3]}, $1 } else { die "$file: not an XML file\n" if $1 =~ /\S/ }
    }
    elsif ($t =~ /\G<\/([^\s>]+)\s*>/gc) {
      die "$file: bad XML near </$1>\n" unless $cur && $cur->[6] eq $1;
      $cur->[5] = pos($t);
      pop @stack; $cur = $stack[-1]; $scope = $cur ? $cur->[8] : \%top;
    }
    elsif ($t =~ /\G<!--/gc) { $t =~ /\G.*?-->/gcs or die "$file: bad XML (comment)\n" }
    elsif ($t =~ /\G<!\[CDATA\[(.*?)\]\]>/gcs) { my $c = $1; $c =~ s/&/&amp;/g; push @{$cur->[3]}, $c if $cur }
    elsif ($t =~ /\G<\?/gc) { $t =~ /\G.*?\?>/gcs or die "$file: bad XML\n" }
    elsif ($t =~ /\G<!DOCTYPE/gc) { die "$file: files with a DTD are refused\n" }
    elsif ($t =~ /\G<([^\s>\/!?]+)((?:[^>"'\/]+|"[^"]*"|'[^']*'|\/(?!>))*)(\/?)>/gc) {
      my ($raw, $at, $empty, $start) = ($1, $2, $3, $-[0]);
      my $sc = $scope;
      if (index($at, 'xmlns') >= 0) {
        $sc = { %$scope };
        while ($at =~ /(?:^|\s)xmlns(?::([^\s=]+))?\s*=\s*(?:"([^"]*)"|'([^']*)')/g) {
          $sc->{defined $1 ? $1 : ''} = ent(defined $2 ? $2 : $3);
        }
      }
      my ($pre, $name) = $raw =~ /^([^:]*):(.*)$/ ? ($1, $2) : ('', $raw);
      die "$file: unknown prefix $pre\n" unless exists $sc->{$pre};
      my $n = [$name, $sc->{$pre}, $at, [], $start, 0, $raw, undef, $sc, $file];
      if ($cur) { push @{$cur->[3]}, $n } elsif ($root) { die "$file: two root elements\n" } else { $root = $n }
      if ($empty) { $n->[5] = pos($t) }
      else { push @stack, $n; $cur = $n; $scope = $sc; die "$file: nested too deep\n" if @stack > 500 }
    }
    else { die "$file: bad XML at byte " . pos($t) . "\n" }
  }
  die "$file: the file is cut off\n" if $cur;
  die "$file: not an XML file\n" unless $root;
  return $root;
}

sub attrs {
  my ($n) = @_;
  return $n->[2] if ref $n->[2];
  my (%h, @o);
  my $s = $n->[2];
  while ($s =~ /([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g) {
    my ($k, $v) = ($1, defined $2 ? $2 : $3);
    $v =~ tr/\t\n/  /;
    $h{$k} = ent($v); push @o, $k;
  }
  $n->[2] = \%h; $n->[7] = \@o;
  return \%h;
}
sub at { my ($n, $a) = @_; my $h = ref $n->[2] ? $n->[2] : attrs($n); return defined $h->{$a} ? $h->{$a} : '' }
sub at_ns { my ($n, $local) = @_; my $h = attrs($n); for my $k (@{$n->[7]}) { return $h->{$k} if $k =~ /:\Q$local\E$/ && $k !~ /^xmlns:/ } return '' }
sub kids { return grep { ref $_ } @{$_[0][3]} }
sub els { my ($n, $name) = @_; return grep { ref $_ && $_->[0] eq $name } @{$n->[3]} }
sub el { my ($n, $name) = @_; return undef unless $n; for (@{$n->[3]}) { return $_ if ref $_ && $_->[0] eq $name } return undef }
sub val { my ($n) = @_; return '' unless $n; my $s = ''; for (@{$n->[3]}) { $s .= ref $_ ? val($_) : ent($_) } return $s }
sub trim { my ($s) = @_; $s =~ s/^\s+//; $s =~ s/\s+$//; return $s }
sub text { my ($n) = @_; return '' unless $n; my $s = val($n); $s =~ s/\s+/ /g; return trim($s) }
sub walk { my ($n, $f) = @_; $f->($n); for (@{$n->[3]}) { walk($_, $f) if ref $_ } }   # the node itself and everything below
sub is_true { return $_[0] eq 'true' || $_[0] eq '1' }
sub is_false { return $_[0] eq 'false' || $_[0] eq '0' }
sub cut { my ($s, $n) = @_; return length($s) > $n ? substr($s, 0, $n) . '...' : $s }
sub short_id { my ($id, $m) = @_; my $i = rindex($id, $m); return $i >= 0 ? substr($id, $i + length $m) : $id }
sub strip_hash { my ($s) = @_; $s =~ s/^#+//; return $s }

# the source text of a node, with the namespace declarations it inherits
sub raw_node {
  my ($n) = @_;
  my $s = substr(${$FILES{$n->[9]}}, $n->[4], $n->[5] - $n->[4]);
  my ($head) = $s =~ /^(<[^\s>\/]+(?:[^>"']|"[^"]*"|'[^']*')*>)/;
  my $add = '';
  for my $p (sort keys %{$n->[8]}) {
    next if $p eq 'xml' || ($p eq '' && $n->[8]{''} eq '');
    my $a = $p eq '' ? 'xmlns' : "xmlns:$p";
    next if $head =~ /\s\Q$a\E\s*=/;
    my $u = $n->[8]{$p}; utf8::encode($u) if utf8::is_utf8($u);
    $u =~ s/&/&amp;/g; $u =~ s/"/&quot;/g; $u =~ s/</&lt;/g;
    $add .= " $a=\"$u\"";
  }
  $s =~ s/^(<[^\s>\/]+)/$1$add/;
  utf8::decode($s);
  return $s;
}

# ================================================================ the files of a source
my %S;   # kind version root bench oval dicts ocil benchmarks by tried dir

sub oval_version { my $g = el($_[0], 'generator'); my $v = $g ? el($g, 'schema_version') : undef; return $v ? trim(val($v)) : '' }

sub load_source {
  my ($file, $bid) = @_;
  %S = (kind => '', version => '', oval => [], dicts => [], ocil => [], benchmarks => [], by => {}, tried => {});
  $S{dir} = $file =~ m{^(.*)/[^/]*$} ? ($1 eq '' ? '/' : $1) : '.';
  my $r = $S{root} = parse_xml($file);
  if ($r->[0] eq 'asset-report-collection') {   # ARF: the scanned file is inside
    my ($ds, $b);
    walk($r, sub { my ($n) = @_; $ds = $n if !$ds && $n->[0] eq 'data-stream-collection'; $b = $n if !$b && $n->[0] eq 'Benchmark' && $n->[1] eq $NS12 });
    $r = $S{root} = $ds || $b || $r;
  }
  my $k = $r->[0];
  if ($k eq 'data-stream-collection') { read_ds($r, $bid) }
  elsif ($k eq 'Benchmark') { $S{kind} = 'XCCDF benchmark'; $S{bench} = $r; my $i = index($r->[1], 'xccdf/'); $S{version} = $i < 0 ? '' : substr($r->[1], $i + 6) }
  elsif ($k eq 'oval_definitions') { $S{kind} = 'OVAL definitions'; push @{$S{oval}}, $r; $S{version} = oval_version($r) }
  elsif ($k eq 'Tailoring') { $S{kind} = 'XCCDF tailoring' }
  elsif ($k eq 'TestResult') { $S{kind} = 'XCCDF results' }
  elsif ($k eq 'asset-report-collection') { $S{kind} = 'ARF results' }
  elsif ($k eq 'oval_results') { $S{kind} = 'OVAL results' }
  elsif ($k eq 'cpe-list') { $S{kind} = 'CPE dictionary'; push @{$S{dicts}}, $r }
  elsif ($k eq 'ocil') { $S{kind} = 'OCIL questionnaires'; push @{$S{ocil}}, $r }
  elsif ($k eq 'cvrfdoc') { $S{kind} = 'CVRF advisory' }
  else { $S{kind} = $k }
  if ($S{bench} && $S{kind} eq 'XCCDF benchmark') {
    my $oval;   # ssg-x-xccdf.xml comes with ssg-x-cpe-dictionary.xml
    walk($S{bench}, sub { $oval = at($_[0], 'href') if !defined $oval && $_[0][0] eq 'check-content-ref' && at($_[0], 'href') =~ /-oval\.xml$/ });
    if (defined $oval) { $oval =~ s/-oval\.xml/-cpe-dictionary.xml/g; find_file($oval) }
  }
}

sub has_node { my ($l, $n) = @_; for (@$l) { return 1 if $_ == $n } return 0 }

sub read_ds {
  my ($root, $bid) = @_;
  $S{kind} = 'SCAP data stream';
  my (%parts, @order);
  for my $c (kids($root)) {
    next unless $c->[0] eq 'component' || $c->[0] eq 'extended-component';
    my ($body) = kids($c);
    if ($body) { push @order, at($c, 'id') unless $parts{at($c, 'id')}; $parts{at($c, 'id')} = $body }
  }
  for my $ds (els($root, 'data-stream')) {
    $S{version} = at($ds, 'scap-version') if $S{version} eq '';
    my (@refs, %body);
    walk($ds, sub { push @refs, $_[0] if $_[0][0] eq 'component-ref' });
    for my $r (@refs) { my $t = strip_hash(at_ns($r, 'href')); $body{at($r, 'id')} = $parts{$t} if $parts{$t} }
    for my $r (@refs) {
      walk($r, sub {
        my ($u) = @_; return unless $u->[0] eq 'uri';
        my $b = $body{strip_hash(at($u, 'uri'))};
        $S{by}{at($u, 'name')} = $b if $b && !$S{by}{at($u, 'name')};
      });
      my $b = $body{at($r, 'id')} or next;
      if ($b->[0] eq 'Benchmark') {
        my $id = at($b, 'id');
        push @{$S{benchmarks}}, $id unless grep { $_ eq $id } @{$S{benchmarks}};
        $S{bench} = $b if !$S{bench} || (defined $bid && $id eq $bid);
      }
      elsif ($b->[0] eq 'oval_definitions') { push @{$S{oval}}, $b unless has_node($S{oval}, $b) }
      elsif ($b->[0] eq 'cpe-list') { push @{$S{dicts}}, $b unless has_node($S{dicts}, $b) }
      elsif ($b->[0] eq 'ocil') { push @{$S{ocil}}, $b unless has_node($S{ocil}, $b) }
    }
  }
  for my $k (@order) {
    my $v = $parts{$k};
    next unless $v->[0] eq 'oval_definitions' && !has_node($S{oval}, $v);
    push @{$S{oval}}, $v; $S{by}{$k} = $v unless $S{by}{$k};
  }
}

# the document a check refers to: from the data stream, or a file in the same folder
sub find_file {
  my ($href) = @_;
  $href = strip_hash($href);
  return @{$S{oval}} == 1 ? $S{oval}[0] : undef if $href eq '';
  return $S{by}{$href} if $S{by}{$href};
  return undef if $S{tried}{lc $href}++;
  return undef if $href =~ m{[/\\]} || $href eq '..' || $href eq '.';
  my $p = "$S{dir}/$href";
  return undef unless -f $p && -s $p <= $MAX;
  my $r = eval { parse_xml($p) } or return undef;
  $S{by}{$href} = $r;
  if ($r->[0] eq 'oval_definitions') { push @{$S{oval}}, $r }
  elsif ($r->[0] eq 'cpe-list') { push @{$S{dicts}}, $r }
  elsif ($r->[0] eq 'ocil') { push @{$S{ocil}}, $r }
  return $r;
}

# ================================================================ OVAL library
my (%OV, @OVIDS, $OVFILES, $OVDEFS);
sub refresh_oval {
  return if defined $OVFILES && $OVFILES == @{$S{oval}};
  $OVFILES = @{$S{oval}}; %OV = (); @OVIDS = (); $OVDEFS = 0;
  for my $root (@{$S{oval}}) {
    for my $sec (kids($root)) {
      next unless $sec->[0] =~ /^(?:definitions|tests|objects|states|variables)$/;
      for my $e (kids($sec)) {
        my $id = at($e, 'id');
        next if $id eq '' || $OV{$id};
        $OV{$id} = $e; push @OVIDS, $id;
        $OVDEFS++ if $sec->[0] eq 'definitions';
      }
    }
  }
}

# ================================================================ OVAL -> the lines the awk engine reads (the app's OvalCompiler)
my %KINDS = map { my ($k, $o, $s) = split /\|/; $k => [$o, $s] } grep { /\S/ } split /\n/, <<'EOF';
independent:textfilecontent54|filepath path filename pattern instance|filepath path filename pattern instance text subexpression
independent:family||family
independent:environmentvariable58|pid name|pid name value
independent:environmentvariable|name|name value
independent:variable|var_ref|var_ref value
independent:filehash58|filepath path filename hash_type|filepath path filename hash_type hash
unix:file|filepath path filename|filepath path filename type user_id group_id size suid sgid sticky uread uwrite uexec gread gwrite gexec oread owrite oexec has_extended_acl
unix:uname||machine_class node_name os_name os_release os_version processor_type
unix:password|username|username password user_id group_id gcos home_dir login_shell
unix:shadow|username|username password chg_lst chg_allow chg_req exp_warn exp_inact exp_date flag encrypt_method
unix:sysctl|name|name value
unix:symlink|filepath|filepath canonical_path
unix:interface|name|name type inet_addr flag
unix:process58|command_line pid|command_line pid ppid ruid user_id
unix:runlevel|service_name runlevel|service_name runlevel start kill
linux:dpkginfo|name|name arch epoch version release evr
linux:rpminfo|name|name arch epoch version release evr signature_keyid extended_name
linux:partition|mount_point|mount_point device fs_type mount_options
linux:systemdunitproperty|unit property|unit property value
linux:systemdunitdependency|unit|unit dependency
linux:inetlisteningservers|protocol local_address local_port|protocol local_address local_port local_full_address
linux:selinuxboolean|name|name current_status pending_status
linux:selinuxsecuritycontext|filepath path filename|filepath path filename user role type
aix:fileset|flstinst|flstinst level state description
aix:oslevel||maintenance_level
aix:no|tunable|tunable value
aix:interim_fix|vuid|vuid label state
EOF
my %OPS = map { $_ => 1 } ('', 'equals', 'not equal', 'case insensitive equals', 'case insensitive not equal', 'greater than', 'greater than or equal',
  'less than', 'less than or equal', 'pattern match', 'bitwise and', 'bitwise or', 'subset of');
my %TYPES = map { $_ => 1 } ('', qw(string int float boolean evr_string debian_evr_string version fileset_revision ios_version ipv4_address binary));

my (@IR, %DONE, @TODO, $NODES, $EXT);

sub oesc { my ($s) = @_; return $s unless $s =~ /[\\\t\n\r]/; $s =~ s/\\/\\\\/g; $s =~ s/\t/\\t/g; $s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; return $s }
sub line { push @IR, join("\t", @_) }
sub safe { my ($s) = @_; $s =~ tr/\t\n /___/; return $s }
sub use_id { my ($id) = @_; push @TODO, $id if $id ne '' && !$DONE{$id}++; return safe($id) }
sub new_node {
  my ($type, $op, $neg, @c) = @_;
  my $id = 'n' . ++$NODES;
  line($type, $id, $op, $neg ? '1' : '0') unless @c;
  while (@c) { line($type, $id, $op, $neg ? '1' : '0', splice(@c, 0, 20)) }
  return $id;
}
# check and platform trees: [definition, operator, negate, children]
sub ir_check { my ($n) = @_; if (defined $n->[0]) { use_id($n->[0]); return 'E' . safe($n->[0]) } my @k = map { ir_check($_) } @{$n->[3]}; return 'K' . new_node('K', $n->[1], $n->[2], @k) }
sub ir_platform { my ($n) = @_; if (defined $n->[0]) { use_id($n->[0]); return ($n->[2] ? '!' : '') . 'D' . safe($n->[0]) } my @k = map { ir_platform($_) } @{$n->[3]}; return 'C' . new_node('C', $n->[1], $n->[2], @k) }

sub compile_oval {
  my ($root, $plat, $ext) = @_;
  @IR = (); %DONE = (); @TODO = (); $NODES = 0; $EXT = $ext;
  if ($plat) { my $p = ir_platform($plat); line('P', $p) }
  if ($root) { my $c = ir_check($root); line('R', $c) } else { line('R', 'M') }
  while (@TODO) { ir_entity(shift @TODO) }
  return join('', map { "$_\n" } @IR);
}
sub ir_entity {
  my ($id) = @_;
  my $e = $OV{$id} or return;
  my $n = $e->[0];
  if ($n eq 'definition') { my $c = el($e, 'criteria'); my $k = $c ? 'C' . ir_criteria($c) : ''; line('D', safe($id), at($e, 'class'), $k) }
  elsif ($n =~ /_test$/) { ir_test($id, $e) }
  elsif ($n =~ /_object$/) { ir_object($id, $e) }
  elsif ($n =~ /_state$/) { ir_state($id, $e) }
  elsif ($n =~ /_variable$/) { ir_variable($id, $e) }
}
sub ir_criteria {
  my ($e) = @_;
  my @k;
  for my $k (kids($e)) {
    my $neg = is_true(at($k, 'negate')) ? '!' : '';
    if ($k->[0] eq 'criteria') { push @k, 'C' . ir_criteria($k) }
    elsif ($k->[0] eq 'criterion') { push @k, $neg . 'T' . use_id(at($k, 'test_ref')) }
    elsif ($k->[0] eq 'extend_definition') { push @k, $neg . 'D' . use_id(at($k, 'definition_ref')) }
  }
  my $op = at($e, 'operator');
  return new_node('C', $op eq '' ? 'AND' : $op, is_true(at($e, 'negate')), @k);
}
sub or_else { return $_[0] eq '' ? $_[1] : $_[0] }
sub ir_test {
  my ($id, $e) = @_;
  my $kind = substr($e->[0], 0, -5);
  my $comment = oesc(substr(at($e, 'comment'), 0, 200));
  if ($kind eq 'unknown') { line('T', safe($id), 'unknown', '', '', '', '', $comment); return }
  my $p = test_problem($e, $kind);
  if (defined $p) { line('T', safe($id), '?', '', '', '', $p, $comment); return }
  my $o = el($e, 'object');
  my @f = ('T', safe($id), $kind, or_else(at($e, 'check_existence'), 'at_least_one_exists'), at($e, 'check'), or_else(at($e, 'state_operator'), 'AND'),
    use_id($o ? at($o, 'object_ref') : ''), $comment);
  push @f, use_id(at($_, 'state_ref')) for els($e, 'state');
  line(@f);
}
sub test_problem {
  my ($t, $kind) = @_;
  my $fam = $t->[1] =~ /^[^#]*#(.*)$/ ? $1 : '';
  my $known = $KINDS{"$fam:$kind"} or return $kind;
  my $or = el($t, 'object');
  my $o = $OV{$or ? at($or, 'object_ref') : ''} or return "$kind (object missing)";
  my %oe = map { $_ => 1 } split / /, $known->[0];
  my %se = map { $_ => 1 } split / /, $known->[1];
  my $p = object_problem($o, $kind, \%oe, \%se, 0);
  return $p if defined $p;
  for (els($t, 'state')) { $p = state_problem(at($_, 'state_ref'), $kind, \%se); return $p if defined $p }
  return undef;
}
sub state_problem {
  my ($id, $kind, $ents) = @_;
  my $s = $OV{$id} or return "$kind (state missing)";
  for my $e (kids($s)) {
    next if $e->[0] eq 'notes' || $e->[0] eq 'Signature';
    return "$kind.$e->[0]" unless $ents->{$e->[0]};
    my $p = entity_problem($e);
    return "$kind.$e->[0] $p" if defined $p;
  }
  return undef;
}
sub entity_problem { my ($e) = @_; return at($e, 'operation') unless $OPS{at($e, 'operation')}; return at($e, 'datatype') unless $TYPES{at($e, 'datatype')}; return undef }
sub object_problem {
  my ($o, $kind, $oe, $se, $depth) = @_;
  return "$kind (nested too deep)" if $depth > 8;
  return "$kind (wrong object)" if $o->[0] ne "${kind}_object";
  my $set = el($o, 'set');
  return set_problem($set, $kind, $oe, $se, $depth) if $set;
  for my $e (kids($o)) {
    my $n = $e->[0];
    next if $n eq 'notes' || $n eq 'Signature';
    if ($n eq 'filter') { my $p = state_problem(trim(val($e)), $kind, $se); return $p if defined $p; next }
    if ($n eq 'behaviors') { return "$kind recurse up" if at($e, 'recurse_direction') eq 'up'; next }
    return "$kind.$n" unless $oe->{$n};
    my $p = entity_problem($e);
    return "$kind.$n $p" if defined $p;
    my $op = at($e, 'operation');
    return "$kind.$n $op" if ($n eq 'filepath' || $n eq 'path') && $op !~ /^(?:|equals|pattern match)$/;
    return "$kind.pattern $op" if $n eq 'pattern' && $op ne 'pattern match';
  }
  return undef;
}
sub set_problem {
  my ($set, $kind, $oe, $se, $depth) = @_;
  for my $c (kids($set)) {
    my $p;
    if ($c->[0] eq 'set') { $p = set_problem($c, $kind, $oe, $se, $depth + 1) }
    elsif ($c->[0] eq 'filter') { $p = state_problem(trim(val($c)), $kind, $se) }
    elsif ($c->[0] eq 'object_reference') { my $o = $OV{trim(val($c))}; $p = $o ? object_problem($o, $kind, $oe, $se, $depth + 1) : "$kind (object missing)" }
    return $p if defined $p;
  }
  return undef;
}
sub ir_object {
  my ($id, $e) = @_;
  my $kind = substr($e->[0], 0, -7);
  my $set = el($e, 'set');
  if ($set) { ir_set(safe($id), $kind, $set); return }
  line('O', safe($id), $kind);
  for my $x (kids($e)) {
    my $n = $x->[0];
    if ($n eq 'notes' || $n eq 'Signature') { next }
    elsif ($n eq 'behaviors') { my $h = attrs($x); for my $k (@{$x->[7]}) { my $l = $k; $l =~ s/^.*://; line('OB', safe($id), $l, $h->{$k}) } }
    elsif ($n eq 'filter') { line('OF', safe($id), or_else(at($x, 'action'), 'exclude'), use_id(trim(val($x)))) }
    elsif ($n eq 'var_ref') { line('OE', safe($id), $n, 'equals', 'string', 'all', 'lit', use_id(trim(val($x)))) }
    else { my ($src, $v) = ir_source($x); line('OE', safe($id), $n, or_else(at($x, 'operation'), 'equals'), at($x, 'datatype'), or_else(at($x, 'var_check'), 'all'), $src, $v) }
  }
}
sub ir_set {
  my ($id, $kind, $set) = @_;
  line('O', $id, $kind);
  my (@m, $k);
  for my $c (kids($set)) {
    if ($c->[0] eq 'object_reference') { push @m, use_id(trim(val($c))) }
    elsif ($c->[0] eq 'set') { my $sub = "$id." . ++$k; ir_set($sub, $kind, $c); push @m, $sub }
  }
  line('OF', $id, or_else(at($_, 'action'), 'exclude'), use_id(trim(val($_)))) for els($set, 'filter');
  line('OS', $id, or_else(at($set, 'set_operator'), 'UNION'), @m);
}
sub ir_state {
  my ($id, $e) = @_;
  line('S', safe($id), or_else(at($e, 'operator'), 'AND'));
  for my $x (kids($e)) {
    next if $x->[0] eq 'notes' || $x->[0] eq 'Signature';
    my ($src, $v) = ir_source($x);
    line('SE', safe($id), $x->[0], or_else(at($x, 'operation'), 'equals'), at($x, 'datatype'), or_else(at($x, 'entity_check'), 'all'), or_else(at($x, 'var_check'), 'all'), $src, $v);
  }
}
sub ir_source {
  my ($x) = @_;
  my $v = at($x, 'var_ref');
  return ('var', use_id($v)) if $v ne '';
  return ('nil', '') if is_true(at_ns($x, 'nil'));
  return ('lit', oesc(val($x)));
}
sub ir_variable {
  my ($id, $e) = @_;
  my $sid = safe($id);
  if ($e->[0] eq 'constant_variable') { line('V', $sid, 'const', ''); line('VV', $sid, oesc(val($_))) for els($e, 'value') }
  elsif ($e->[0] eq 'external_variable') { line('V', $sid, 'ext', ''); if ($EXT->{$id}) { line('VV', $sid, oesc($_)) for @{$EXT->{$id}} } }
  elsif ($e->[0] eq 'local_variable') {
    my ($b) = grep { $_->[0] ne 'notes' && $_->[0] ne 'Signature' } kids($e);
    my $c = $b ? ir_component($b) : ir_bad();
    line('V', $sid, 'local', $c);
  }
  else { my $c = ir_bad(); line('V', $sid, 'local', $c) }
}
sub ir_bad { my $id = 'x' . ++$NODES; line('X', $id, 'bad'); return $id }
sub ir_component {
  my ($e) = @_;
  my $id = 'x' . ++$NODES;
  my $n = $e->[0];
  my $k = sub { return map { ir_component($_) } grep { $_->[0] ne 'notes' } kids($e) };
  my $put = sub { line('X', $id, @_) };
  if ($n eq 'literal_component') { $put->('lit', oesc(val($e))) }
  elsif ($n eq 'variable_component') { $put->('var', use_id(at($e, 'var_ref'))) }
  elsif ($n eq 'object_component') { if (at($e, 'record_field') ne '') { $put->('bad') } else { $put->('obj', use_id(at($e, 'object_ref')), at($e, 'item_field')) } }
  elsif ($n =~ /^(?:concat|unique|count|merge|escape_regex|glob_to_regex)$/) { $put->($n, $k->()) }
  elsif ($n eq 'arithmetic') { $put->($n, at($e, 'arithmetic_operation'), $k->()) }
  elsif ($n eq 'split') { $put->($n, $k->(), oesc(at($e, 'delimiter'))) }
  elsif ($n eq 'regex_capture') { $put->($n, $k->(), oesc(at($e, 'pattern'))) }
  elsif ($n eq 'substring') { $put->($n, $k->(), at($e, 'substring_start'), at($e, 'substring_length')) }
  elsif ($n eq 'begin' || $n eq 'end') { $put->($n, $k->(), oesc(at($e, 'character'))) }
  elsif ($n eq 'time_difference' && at($e, 'format_2') eq 'seconds_since_epoch') { $put->($n, or_else(at($e, 'format_1'), 'year_month_day'), at($e, 'format_2'), $k->()) }
  else { $put->('bad') }
  return $id;
}

# ================================================================ XCCDF
my %D;   # id title description version status file target rules groups profiles platforms values valueorder plain overrides prebuilt

sub weight { my $w = at($_[0], 'weight'); return $w =~ /^\s*\+?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\s*$/ ? $w + 0 : 1 }

sub load_doc {
  my ($o) = @_;
  load_source($o->{file}, $o->{benchmark});
  my ($base) = $o->{file} =~ m{([^/]*)$};
  %D = (id => '', title => '', description => '', version => '', status => '', file => $base, target => 'any', rules => [], groups => [],
    profiles => [], platforms => [], values => {}, valueorder => [], plain => {}, overrides => {});
  if ($S{bench}) { load_benchmark() }
  elsif (@{$S{oval}}) { load_oval($base) }
  else {
    die "this is a tailoring file. Give the benchmark, and this one with --tailoring\n" if $S{kind} eq 'XCCDF tailoring';
    die "this is a results file\n" if $S{kind} =~ / results$/;
    die "no XCCDF rules in this file. Use a SCAP data stream (ssg-*-ds.xml), an XCCDF benchmark or an OVAL file\n";
  }
  load_tailoring($o->{tailoring}) if defined $o->{tailoring};
  if (defined $o->{tailoring} && !defined $o->{profile}) { my @t = grep { $_->{tailored} } @{$D{profiles}}; $o->{profile} = $t[0]{id} if @t == 1 }
  for my $pair (@{$o->{set} || []}) {
    $pair =~ /^([^=]+)=(.*)$/s or die "--set needs NAME=VALUE\n";
    my ($n, $v) = ($1, $2);
    my ($id) = grep { $_ eq $n || /_value_\Q$n\E$/ } @{$D{valueorder}};
    die "value not found: $n\n" unless defined $id;
    $D{overrides}{$id} = $v;
  }
}

sub load_benchmark {
  my $b = $S{bench};
  $D{id} = at($b, 'id'); $D{title} = text(el($b, 'title')); $D{description} = cut(text(el($b, 'description')), 1500); $D{version} = text(el($b, 'version'));
  $D{status} = join(', ', map { text($_) . (at($_, 'date') ne '' ? ' ' . at($_, 'date') : '') } els($b, 'status'));
  $D{platforms} = [grep { $_ ne '' } map { at($_, 'idref') } els($b, 'platform')];
  $D{plain}{at($_, 'id')} = val($_) for els($b, 'plain-text');
  read_items($b, undef);
  die "no XCCDF rules were found in this benchmark\n" unless @{$D{rules}};
  my %seen;
  for my $r (@{$D{rules}}) { for my $c (@{$r->{checks}}) { walk($c, sub { if ($_[0][0] eq 'check-content-ref') { my $h = at($_[0], 'href'); find_file($h) unless $seen{$h}++ } }) } }
  refresh_oval();
  $D{profiles} = [map { read_profile($_, 0) } els($b, 'Profile')];
  resolve($_) for @{$D{profiles}};
  my %abs = map { at($_, 'id') => is_true(at($_, 'abstract')) } reverse els($b, 'Profile');
  $D{profiles} = [grep { !$abs{$_->{id}} } @{$D{profiles}}];
  my %p; my @rp = grep { !$p{$_}++ } map { @{$_->{platforms}} } @{$D{rules}};
  splice(@rp, 50) if @rp > 50;
  my $s = lc(join(' ', @{$D{platforms}}) . ' ' . join(' ', @rp));
  $D{target} = $s =~ /:ibm:aix/ ? 'AIX' : $s =~ /:sun:|:oracle:solaris/ ? 'SunOS' : $s =~ /:hp:hp-ux/ ? 'HP-UX' : $s =~ /freebsd|openbsd|netbsd/ ? 'BSD'
    : $s =~ /linux|cpe:\/o:/ || $D{title} =~ /linux/i ? 'Linux' : $D{title} =~ /AIX/ ? 'AIX' : 'any';
}

sub read_items {
  my ($parent, $group) = @_;
  for my $e (kids($parent)) {
    if ($e->[0] eq 'Group') {
      my $g = { id => at($e, 'id'), title => text(el($e, 'title')), on => !is_false(at($e, 'selected')), weight => weight($e), parent => $group,
        platforms => [map { at($_, 'idref') } els($e, 'platform')], cluster => at($e, 'cluster-id') };
      push @{$D{groups}}, $g;
      read_items($e, $g);
    }
    elsif ($e->[0] eq 'Rule') {
      next if is_true(at($e, 'abstract')) || is_true(at($e, 'hidden'));
      my $id = at($e, 'id');
      my $t = text(el($e, 'title'));
      push @{$D{rules}}, { id => $id, short => short_id($id, '_rule_'), title => $t ne '' ? $t : $id, severity => at($e, 'severity'), role => at($e, 'role'),
        on => !is_false(at($e, 'selected')), weight => weight($e), parent => $group, node => $e, cluster => at($e, 'cluster-id'),
        platforms => [map { at($_, 'idref') } els($e, 'platform')], requires => [map { [split ' ', at($_, 'idref')] } els($e, 'requires')],
        conflicts => [map { at($_, 'idref') } els($e, 'conflicts')], checks => [grep { $_->[0] eq 'check' || $_->[0] eq 'complex-check' } kids($e)],
        fixes => [els($e, 'fix')], idents => [els($e, 'ident')] };
    }
    elsif ($e->[0] eq 'Value') {
      my $v = { id => at($e, 'id'), sel => {}, selorder => [], lists => {} };
      for my $x (els($e, 'value')) {
        my $s = at($x, 'selector');
        if ($s eq '') { $v->{def} = val($x) } else { push @{$v->{selorder}}, $s unless exists $v->{sel}{$s}; $v->{sel}{$s} = val($x) }
      }
      $v->{lists}{at($_, 'selector')} = [map { val($_) } els($_, 'item')] for els($e, 'complex-value');
      push @{$D{valueorder}}, $v->{id} unless $D{values}{$v->{id}};
      $D{values}{$v->{id}} = $v;
    }
  }
}

sub read_profile {
  my ($x, $tailored) = @_;
  my $id = at($x, 'id'); my $t = text(el($x, 'title'));
  my $p = { id => $id, tailored => $tailored, title => $t ne '' ? $t : short_id($id, '_profile_'), description => cut(text(el($x, 'description')), 1500), extends => at($x, 'extends'), ops => [] };
  for my $e (kids($x)) {
    my $n = $e->[0];
    if ($n eq 'select') { push @{$p->{ops}}, ['select', at($e, 'idref'), or_else(at($e, 'selected'), 'true')] }
    elsif ($n eq 'set-value') { push @{$p->{ops}}, [$n, at($e, 'idref'), val($e)] }
    elsif ($n eq 'refine-value') { push @{$p->{ops}}, [$n, at($e, 'idref'), at($e, 'selector')] }
    elsif ($n eq 'refine-rule') { push @{$p->{ops}}, [$n, at($e, 'idref'), at($e, 'severity'), at($e, 'selector'), at($e, 'weight')] }
  }
  return $p;
}

sub resolve {
  my ($p) = @_;
  my @chain;
  for (my $x = $p; $x;) {
    unshift @chain, $x;
    my $bid = strip_hash($x->{extends});
    my $next;
    if ($bid ne '') { for my $q (@{$D{profiles}}) { if ($q->{id} eq $bid && !grep { $_ == $q } @chain) { $next = $q; last } } }
    $x = $next;
  }
  my %st;
  $st{$_->{id}} = $_->{on} for @{$D{groups}};
  $st{$_->{id}} = $_->{on} for @{$D{rules}};
  $p->{selected} = {}; $p->{refine} = {}; $p->{sets} = {}; $p->{rr} = {};
  for my $o (map { @{$_->{ops}} } @chain) {
    my ($k, $id, $v) = @$o;
    if ($k eq 'select') {
      my $on = is_true($v);
      if (exists $st{$id}) { $st{$id} = $on }
      else { for (@{$D{rules}}, @{$D{groups}}) { $st{$_->{id}} = $on if $_->{cluster} ne '' && $_->{cluster} eq $id } }
    }
    elsif ($k eq 'set-value') { $p->{sets}{$id} = $v }
    elsif ($k eq 'refine-value') { $p->{refine}{$id} = $v; delete $p->{sets}{$id} }
    else { $p->{rr}{$id} = $o }
  }
  RULE: for my $r (@{$D{rules}}) {
    next unless $st{$r->{id}};
    for (my $g = $r->{parent}; $g; $g = $g->{parent}) { next RULE unless $st{$g->{id}} }
    $p->{selected}{$r->{id}} = 1;
  }
  my %g = map { $_->{id} => 1 } @{$D{groups}};
  my $on = sub { return $p->{selected}{$_[0]} || ($g{$_[0]} && $st{$_[0]}) };
  my @drop;
  for my $r (@{$D{rules}}) {
    next unless $p->{selected}{$r->{id}};
    my $bad = 0;
    for my $any (@{$r->{requires}}) { $bad = 1 unless grep { $on->($_) } @$any }
    for (@{$r->{conflicts}}) { $bad = 1 if $on->($_) }
    push @drop, $r->{id} if $bad;
  }
  delete $p->{selected}{$_} for @drop;
}

sub default_profile { my $p = { id => '', title => '', extends => '', ops => [], description => '' }; resolve($p); return $p }

sub find_profile {
  my ($n) = @_;
  return undef unless defined $n;
  for (@{$D{profiles}}) { return $_ if $_->{id} eq $n || lc $_->{title} eq lc $n || $_->{id} =~ /_profile_\Q$n\E$/ }
  die "profile not found: $n (see: scriptix info)\n";
}

sub load_tailoring {
  my ($file) = @_;
  my $root = parse_xml($file);
  die "$file isn't an XCCDF tailoring file\n" unless $root->[0] eq 'Tailoring';
  my $b = el($root, 'benchmark');
  my $t = $b ? at($b, 'id') : '';
  die "this tailoring file belongs to another benchmark ($t)\n" if $t ne '' && $D{id} ne '' && $t ne $D{id};
  my @add = map { read_profile($_, 1) } els($root, 'Profile');
  die "the tailoring file has no profile\n" unless @add;
  for my $p (@add) {
    my $x = strip_hash($p->{extends});
    die "the tailoring extends profile $x, which isn't in this benchmark\n" if $x ne '' && !grep { $_->{id} eq $x } @{$D{profiles}}, @add;
    $D{profiles} = [grep { !($_->{id} eq $p->{id} && ($_->{tailored} || $x ne $p->{id})) } @{$D{profiles}}];
  }
  unshift @{$D{profiles}}, @add;
  resolve($_) for @{$D{profiles}};
}

sub profile_value {
  my ($id, $p) = @_;
  return $p->{sets}{$id} if $p && exists $p->{sets}{$id};
  my $v = $D{values}{$id};
  return $D{plain}{$id} unless $v;
  return $v->{sel}{$p->{refine}{$id}} if $p && exists $p->{refine}{$id} && exists $v->{sel}{$p->{refine}{$id}};
  return $v->{def} if defined $v->{def};
  return @{$v->{selorder}} ? $v->{sel}{$v->{selorder}[0]} : undef;
}
sub value { my ($id, $p) = @_; return exists $D{overrides}{$id} ? $D{overrides}{$id} : profile_value($id, $p) }
sub value_list {
  my ($id, $p) = @_;
  my $v = $D{values}{$id};
  if (!exists $D{overrides}{$id} && $v && %{$v->{lists}}) {
    my $s = $p && exists $p->{refine}{$id} ? $p->{refine}{$id} : '';
    return $v->{lists}{$s} if $v->{lists}{$s};
    return $v->{lists}{''} if $v->{lists}{''};
  }
  my $one = value($id, $p);
  return defined $one ? [$one] : [];
}

sub fix_kind {
  my ($s) = @_;
  for my $k (['script:ansible', 'ansible'], ['script:puppet', 'puppet'], ['kickstart', 'kickstart'], ['kubernetes', 'kubernetes'], ['ignition', 'ignition'],
    ['blueprint', 'blueprint'], ['bootc', 'bootc'], ['powershell', 'powershell']) { return $k->[1] if $s =~ /\Q$k->[0]\E/i }
  return 'bash' if $s =~ /script:sh|bash|system:commands/i || $s eq '';
  return 'other';
}
sub fix_of { my ($r, $kind) = @_; for (@{$r->{fixes}}) { return $_ if fix_kind(at($_, 'system')) eq $kind } return undef }
sub fix_text {
  my ($f, $p) = @_;
  my $s = '';
  for my $n (@{$f->[3]}) {
    if (!ref $n) { $s .= ent($n) }
    elsif ($n->[0] eq 'sub') { my $id = at($n, 'idref'); my $v = value($id, $p); $s .= defined $v ? $v : '<SET ' . short_id($id, '_value_') . '>' }
    elsif ($n->[0] ne 'instance') { $s .= val($n) }
  }
  return trim($s);
}

# ---------------------------------------------------------------- checks
sub first_def { my ($n) = @_; return $n->[0] if defined $n->[0]; for (@{$n->[3]}) { my $d = first_def($_); return $d if defined $d } return undef }

sub oval_node {
  my ($check, $p, $ext) = @_;
  $ext->{at($_, 'export-name')} = value_list(at($_, 'value-id'), $p) for els($check, 'check-export');
  for my $c (els($check, 'check-content-ref')) {
    my $file = find_file(at($c, 'href'));
    my $name = at($c, 'name');
    if ($name ne '') {
      return [$name, 'AND', 0, []] if $OV{$name};
      if ($file) { refresh_oval(); return [$name, 'AND', 0, []] if $OV{$name} }
      next;
    }
    next unless $file && $file->[0] eq 'oval_definitions';
    refresh_oval();
    my @d = grep { $_ ne '' } map { at($_, 'id') } map { kids($_) } grep { $_ } el($file, 'definitions');
    next unless @d;
    return [undef, 'AND', 0, [map { [$_, 'AND', 0, []] } @d]];
  }
  return undef;
}
sub complex_node {
  my ($e, $p, $ext) = @_;
  my @k;
  for my $c (kids($e)) {
    my $k = $c->[0] eq 'complex-check' ? complex_node($c, $p, $ext) : $c->[0] eq 'check' && at($c, 'system') eq $OVALSYS ? oval_node($c, $p, $ext) : undef;
    push @k, $k || [undef, 'AND', 0, []] if $c->[0] eq 'check' || $c->[0] eq 'complex-check';
  }
  return undef unless grep { defined $_->[0] || @{$_->[3]} } @k;
  return [undef, at($e, 'operator') eq 'OR' ? 'OR' : 'AND', is_true(at($e, 'negate')), \@k];
}
sub q_sh { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'" }
sub sce_script {
  my ($check, $p) = @_;
  for my $c (els($check, 'check-content-ref')) {
    my $b = find_file(at($c, 'href'));
    next unless $b && $b->[0] eq 'script';
    my $s = "XCCDF_RESULT_PASS=101 XCCDF_RESULT_FAIL=102 XCCDF_RESULT_ERROR=103 XCCDF_RESULT_UNKNOWN=104 XCCDF_RESULT_NOT_APPLICABLE=105 XCCDF_RESULT_NOT_CHECKED=106 XCCDF_RESULT_NOT_SELECTED=107 XCCDF_RESULT_INFORMATIONAL=108 XCCDF_RESULT_FIXED=109\n"
      . "export XCCDF_RESULT_PASS XCCDF_RESULT_FAIL XCCDF_RESULT_ERROR XCCDF_RESULT_UNKNOWN XCCDF_RESULT_NOT_APPLICABLE XCCDF_RESULT_NOT_CHECKED XCCDF_RESULT_NOT_SELECTED XCCDF_RESULT_INFORMATIONAL XCCDF_RESULT_FIXED\n";
    for my $e (els($check, 'check-export')) {
      my $n = at($e, 'export-name'); $n =~ s/[^A-Za-z0-9_]/_/g;
      my $v = value(at($e, 'value-id'), $p); $v = '' unless defined $v;
      $s .= "XCCDF_VALUE_$n=" . q_sh($v) . "; export XCCDF_VALUE_$n\n" if $n ne '';
    }
    return $s . trim(val($b));
  }
  return undef;
}
my %OCIL;
sub question {
  my (@checks) = @_;
  for my $c (@checks) {
    my $x = el($c, 'check-content');
    return cut(text($x), 1000) if $x && trim(val($x)) ne '';
    next unless at($c, 'system') =~ /ocil/i;
    for my $rf (els($c, 'check-content-ref')) {
      find_file(at($rf, 'href'));
      for my $o (@{$S{ocil}}) {
        my $ix = $OCIL{$o} ||= do {
          my %h = (q => {}, a => {}, t => {});
          walk($o, sub {
            my ($n) = @_; my $l = $n->[0];
            my $s = $l eq 'questionnaire' ? 'q' : $l =~ /_test_action$/ ? 'a' : $l =~ /_question$/ ? 't' : return;
            my $id = at($n, 'id'); $h{$s}{$id} = $n unless $h{$s}{$id};
          });
          \%h;
        };
        my $q = $ix->{q}{at($rf, 'name')} or next;
        my $act;
        walk($q, sub { $act = trim(val($_[0])) if !defined $act && $_[0][0] eq 'test_action_ref' });
        my $a = defined $act ? $ix->{a}{$act} : undef;
        my $t = $a ? $ix->{t}{at($a, 'question_ref')} : undef;
        my $qt = $t ? text(el($t, 'question_text')) : '';
        return cut($qt, 1000) if $qt ne '';
      }
    }
  }
  return undef;
}

# ---------------------------------------------------------------- platforms
my (%PCACHE, $PSPEC);
sub platform_for {
  my ($r) = @_;
  my @lv;
  my $add = sub {
    my ($names) = @_;
    return unless @$names;
    my @n = map { platform($_) } @$names;
    return if grep { !$_ } @n;   # unknown platform: don't hide the rule because of it
    push @lv, @n == 1 ? $n[0] : [undef, 'OR', 0, \@n];
  };
  $add->($r->{platforms});
  for (my $g = $r->{parent}; $g; $g = $g->{parent}) { $add->($g->{platforms}) }
  $add->($D{platforms});
  return @lv == 0 ? undef : @lv == 1 ? $lv[0] : [undef, 'AND', 0, \@lv];
}
sub platform { my ($id) = @_; $PCACHE{$id} = [find_platform($id)] unless $PCACHE{$id}; return $PCACHE{$id}[0] }
sub find_platform {
  my ($idref) = @_;
  if ($idref =~ /^#(.*)$/s) {
    my $id = $1;
    unless ($PSPEC) { $PSPEC = {}; walk($S{bench}, sub { my ($n) = @_; return unless $n->[0] eq 'platform'; my $i = at($n, 'id'); $PSPEC->{$i} = $n unless $PSPEC->{$i} }) }
    my $t = $PSPEC->{$id} ? el($PSPEC->{$id}, 'logical-test') : undef;
    return $t ? logical($t) : undef;
  }
  for my $d (@{$S{dicts}}) {
    my @it = els($d, 'cpe-item');
    my ($item) = grep { at($_, 'name') eq $idref } @it;
    ($item) = grep { cpe_match($idref, at($_, 'name')) } @it unless $item;
    my $check = $item ? el($item, 'check') : undef;
    next unless $check;
    my $def = trim(val($check));
    find_file(at($check, 'href')); refresh_oval();
    return [$def, 'AND', 0, []] if $OV{$def};
  }
  return undef;
}
sub logical {
  my ($t) = @_;
  my @k;
  for my $c (kids($t)) {
    my $k;
    if ($c->[0] eq 'logical-test') { $k = logical($c) }
    elsif ($c->[0] eq 'fact-ref') { $k = platform(at($c, 'name')) }
    elsif ($c->[0] eq 'check-fact-ref') { find_file(at($c, 'href')); refresh_oval(); my $i = at($c, 'id-ref'); $k = [$i, 'AND', 0, []] if $OV{$i} }
    else { next }
    return undef unless $k;
    push @k, $k;
  }
  return undef unless @k;
  return [undef, at($t, 'operator') eq 'OR' ? 'OR' : 'AND', is_true(at($t, 'negate')), \@k];
}
sub cpe_match {
  my ($a, $b) = @_;
  return 0 unless $a =~ s{^cpe:/}{} && $b =~ s{^cpe:/}{};
  my @x = split /:/, $a, -1; my @y = split /:/, $b, -1;
  for (my $i = 0; $i < @x && $i < @y; $i++) { return 0 if $x[$i] ne '' && $y[$i] ne '' && $x[$i] ne '-' && $y[$i] ne '-' && lc $x[$i] ne lc $y[$i] }
  return @x >= 3 && @y >= 3;
}

# ---------------------------------------------------------------- OVAL files (CVE feeds, patch advisories)
sub load_oval {
  my ($base) = @_;
  refresh_oval();
  $D{title} = $base; $D{prebuilt} = [];
  for my $id (@OVIDS) {
    my $d = $OV{$id};
    next if $d->[0] ne 'definition' || is_true(at($d, 'deprecated')) || !el($d, 'criteria');
    my $m = el($d, 'metadata');
    my $sev = '';
    if ($m) { my $s; walk($m, sub { $s = $_[0] if !$s && $_[0] != $m && $_[0][0] eq 'severity' }); $sev = lc text($s) }
    my $t = $m ? text(el($m, 'title')) : $id;
    push @{$D{prebuilt}}, { id => $id, title => $t ne '' ? $t : $id, severity => $sev =~ /^(?:critical|important|high)$/ ? 'high' : $sev =~ /^(?:low|negligible)$/ ? 'low' : 'medium' };
  }
  die "this OVAL file has no definitions with criteria\n" unless @{$D{prebuilt}};
}

# ================================================================ script items and the script (the app's ScriptBuilder)
sub severity { my $s = lc trim($_[0]); return $s =~ /^(?:low|info|informational)$/ ? 'low' : $s =~ /^(?:high|critical)$/ ? 'high' : 'medium' }
sub safe_id { my ($id, $n) = @_; $id = trim($id); $id =~ s/[^A-Za-z0-9._:-]/_/g; $id = substr($id, 0, 100) if length $id > 100; return $id eq '' ? sprintf('ITEM-%03d', $n) : $id }
sub wanted { my ($r, $l) = @_; return grep { $_ eq $r->{id} || (defined $r->{short} && $_ eq $r->{short}) } @$l }

sub rule_names {   # the id a rule has in scripts and results
  my %n; $n{$_->{short}}++ for @{$D{rules}};
  return { map { $_->{id} => ($n{$_->{short}} > 1 ? $_->{id} : $_->{short}) } @{$D{rules}} };
}

sub check_items {
  my ($p, $only, $skip) = @_;
  my @it;
  if ($D{prebuilt}) {
    for my $r (@{$D{prebuilt}}) {
      next if (@$only && !wanted($r, $only)) || wanted($r, $skip);
      push @it, { id => $r->{id}, title => $r->{title}, sev => $r->{severity}, os => 'any', mode => 'oval', cmd => "oval $r->{id}", tmo => 900, data => compile_oval([$r->{id}, 'AND', 0, []], undef, {}) };
    }
    return @it;
  }
  my $names = rule_names();
  for my $x (@{$D{rules}}) {
    next unless $p->{selected}{$x->{id}};
    next if (@$only && !wanted($x, $only)) || wanted($x, $skip);
    my $rr = $p->{rr}{$x->{id}};
    my $sel = $rr ? $rr->[3] : '';
    my %i = (id => $names->{$x->{id}}, title => $x->{title}, sev => severity($rr && $rr->[2] ne '' ? $rr->[2] : $x->{severity}), os => $D{target}, tmo => 900, data => '');
    my $plat = platform_for($x);
    my %ext; my $node;
    my ($complex) = grep { $_->[0] eq 'complex-check' } @{$x->{checks}};
    $node = complex_node($complex, $p, \%ext) if $complex;
    my @simple = grep { $_->[0] eq 'check' } @{$x->{checks}};
    if (!$node) {
      my @ov = grep { at($_, 'system') eq $OVALSYS } @simple;
      my ($pick) = grep { at($_, 'selector') eq $sel } @ov;
      ($pick) = grep { at($_, 'selector') eq '' } @ov unless $pick;
      $node = oval_node($pick, $p, \%ext) if $pick;
    }
    if ($node) {
      my $d = first_def($node);
      $i{data} = compile_oval($node, $plat, \%ext);
      $i{mode} = 'oval'; $i{os} = 'any'; $i{cmd} = 'oval ' . (defined $d ? $d : $x->{short});
    }
    else {
      my ($sce) = grep { at($_, 'system') eq 'http://open-scap.org/page/SCE' } @simple;
      my $s = $sce ? sce_script($sce, $p) : undef;
      if (defined $s) { $i{mode} = 'sce'; $i{cmd} = $s; $i{tmo} = 0; $i{bash} = $s =~ /bash/ }
      else {
        my $q = question(@simple);
        $i{mode} = 'manual'; $i{cmd} = defined $q ? $q : 'Check this rule by hand.';
        $i{data} = compile_oval(undef, $plat, {}) if $plat;
      }
    }
    push @it, \%i;
  }
  return @it;
}

# fixes of the failed rules (or of every rule of the profile); those that still need a value are left out
sub fix_items {
  my ($p, $failed) = @_;
  my @it;
  my $names = rule_names();
  for my $x (@{$D{rules}}) {
    next unless $p->{selected}{$x->{id}};
    next if $failed && !$failed->{safe_id($x->{id}, 0)} && !$failed->{safe_id($x->{short}, 0)};
    my $f = fix_of($x, 'bash') or next;
    my $t = fix_text($f, $p);
    next if $t eq '' || $t =~ /<[A-Za-z_][A-Za-z0-9_.:-]*( [A-Za-z0-9_.:-]+)*>|xccdf_value/;
    my $rr = $p->{rr}{$x->{id}};
    push @it, { id => $names->{$x->{id}}, title => $x->{title}, sev => severity($rr && $rr->[2] ne '' ? $rr->[2] : $x->{severity}), os => $D{target}, mode => 'rc0', cmd => $t, tmo => 0, data => '', bash => $D{target} ne 'AIX' };
  }
  return @it;
}

my @RISK = (qr/\brm\s+-[a-zA-Z]*[rR]/, qr/\bmkfs|\bdd\s+if=|\bwipefs\b|\bfdisk\b|\bparted\b/, qr/\bshutdown\b|\breboot\b|\bhalt\b|\binit\s+[06]\b|\bpoweroff\b/,
  qr/\buserdel\b|\busermod\b|\bpasswd\b|\bchpasswd\b|\brmuser\b|\bpwdadm\b/, qr/\biptables\b|\bip6tables\b|\bnft\b|firewall-cmd|\bufw\b|\bgenfilt\b|\bmkfilt\b/,
  qr/sshd_config|PermitRootLogin|\bAllowUsers\b|\bAllowGroups\b/i, qr/pam\.d|\bpam_|faillock|\/etc\/security\/login\.cfg/i, qr/fstab|\bmount\b|remount|\/etc\/filesystems/,
  qr/grub|bootlist|\bbosboot\b/i, qr/\b(chmod|chown|chgrp)\s+-R\s+\//, qr/\b(yum|dnf|zypper)\s+(-y\s+)?(remove|erase)|\bapt(-get)?\s+(-y\s+)?(remove|purge)|\brpm\s+-e|\binstallp\s+-u/,
  qr/systemctl\s+(disable|mask|stop)|\bstopsrc\b|chsubserver\s+-d|\bsvc_disable\b|\bchrctcp\b/, qr/\bcurl\b|\bwget\b|\bftp\b|\bscp\b|\btftp\b/,
  qr/\bchmod\s+(-[a-zA-Z]+\s+)*0?777\b/, qr/\bselinux\b|\bsetenforce\b/i);

sub slurp { my ($f) = @_; open(my $h, '<', $f) or die "cannot read $f: $!\n"; binmode($h); local $/; my $t = <$h>; close($h); $t = '' unless defined $t; utf8::decode($t); $t =~ s/\r\n/\n/g; return $t }
sub spew { my ($f, $t) = @_; open(my $h, '>', $f) or die "cannot write $f: $!\n"; binmode($h); utf8::encode($t) if utf8::is_utf8($t); print $h $t or die "cannot write $f: $!\n"; close($h) or die "cannot write $f: $!\n" }
sub out { my ($f, $t) = @_; if (defined $f && $f ne '-') { spew($f, $t) } else { binmode(STDOUT); utf8::encode($t) if utf8::is_utf8($t); print $t } }

# SHA-256 with the system's own tool, as the scripts do it
sub sha {
  my ($text, $tmp) = @_;
  spew($tmp, $text);
  my $q = q_sh($tmp);
  for my $c ("sha256sum $q", "shasum -a 256 $q", "openssl dgst -sha256 $q", "digest -a sha256 $q", "sha256 -q $q", "csum -h SHA256 $q") {
    my ($tool) = $c =~ /^(\S+)/;
    next unless grep { -x "$_/$tool" } split /:/, $ENV{PATH};
    my $o = `$c 2>/dev/null`;
    if ($o =~ /\b([0-9a-f]{64})\b/) { unlink $tmp; return $1 }
  }
  unlink $tmp;
  die "no SHA-256 tool found (sha256sum, shasum, openssl, digest, csum)\n";
}

sub build_script {
  my ($lib, $outfile, $kind, $readonly, @items) = @_;
  die "a script needs at least one command\n" unless @items;
  my (%seen, $lines, $risky, $n) = ();
  $lines = ''; $risky = 0; $n = 0;
  for my $i (@items) {
    my $id = safe_id($i->{id}, ++$n);
    my $u = $id;
    for (my $k = 2; $seen{$u}++; $k++) { $u = "${id}_$k" }
    $i->{id} = $u;
    $i->{title} =~ s/[\x00-\x1f\x7f]/ /g; $i->{title} = trim($i->{title}); $i->{title} = substr($i->{title}, 0, 200);
    $i->{cmd} =~ s/\r\n/\n/g; $i->{cmd} = trim($i->{cmd});
    die "$i->{id}: contains a NUL character\n" if "$i->{cmd}$i->{title}$i->{data}" =~ /\0/;
    if (!$readonly) { for my $r (@RISK) { if ($i->{cmd} =~ $r) { $risky++; last } } }
    my $h = $i->{cmd} =~ /^\s*(?:setcfg|sysctl_set|fperm|fowner|line_add|line_del|svc_disable|aix_chsec|aix_chuser|aix_no)\s[^;&|<>`\$\n\r\\]*$/ && !$i->{bash};
    my $flags = ($h ? 'h' : '') . ($i->{bash} ? 'b' : '') . ($i->{mode} eq 'oval' ? 'o' : $i->{mode} eq 'sce' ? 's' : $i->{mode} eq 'manual' ? 'm' : '');
    $lines .= join(' ', 'run_item', map { q_sh($_) } $u, $i->{title}, $i->{sev}, $i->{os}, $i->{mode}, '', $i->{tmo}, $flags, $i->{cmd}) . "\n";
  }
  my $body = slurp("$lib/runtime.sh");
  my $count = @items;
  my $ro = $readonly ? '1' : '0';
  my $root = $readonly ? '0' : '1';
  my %v = (KIND => $kind, VERSION => $VERSION, TOTAL => $count, RISKY => $risky, STOP => '0', NEEDROOT => $root, TIMEOUT => '60', REDACT => '1', READONLY => $ro);
  $body =~ s/\{\{(KIND|VERSION|TOTAL|RISKY|STOP|NEEDROOT|TIMEOUT|REDACT|READONLY)\}\}/$v{$1}/g;
  $body .= "\n" unless $body =~ /\n\z/;
  my $oval = '';
  if (grep { $_->{data} ne '' } @items) {
    $oval = "mkdir \"\$WORK/ir\" \"\$WORK/c\" || { err \"Cannot create \$WORK/ir\"; exit 3; }\ncat > \"\$WORK/oval.awk\" <<'SX_END_OF_ENGINE'\n" . slurp("$lib/oval.awk");
    $oval .= "\n" unless $oval =~ /\n\z/;
    $oval .= "SX_END_OF_ENGINE\ncat > \"\$WORK/oval.ir\" <<'SX_END_OF_CHECKS'\n";
    for my $i (grep { $_->{data} ne '' } @items) { my $d = $i->{data}; $d =~ tr/\r//d; $d =~ s/\n+\z//; $oval .= "#ID\t$i->{id}\n$d\n" }
    $oval .= "SX_END_OF_CHECKS\nawk -v D=\"\$WORK/ir\" '/^#ID\\t/ { if (f != \"\") close(f); f = D \"/\" substr(\$0, 5); next } { print > f }' \"\$WORK/oval.ir\"\n";
  }
  my ($a, $b) = split /\{\{ITEMS\}\}\n/, $body, 2;
  my ($c, $d) = split /\{\{OVAL\}\}\n/, $b, 2;
  $body = $a . $lines . $c . $oval . $d;
  my $opt = "ScriptOptions { Kind = $kind, StopOnFail = False, RequireRoot = " . ($readonly ? 'False' : 'True') . ", TimeoutSeconds = 60, Redact = True, ReadOnly = " . ($readonly ? 'True' : 'False') . ' }';
  my $sha = sha($body, "$outfile.tmp");
  my $input = substr(sha($lines . $oval . '|' . $opt, "$outfile.tmp"), 0, 16);
  my $head = "#!/bin/sh\n# ScriptIX $VERSION - $kind script for Linux and AIX (POSIX sh)\n# Commands: $count   Flagged risky: $risky   Input hash: $input\n"
    . "# Help: sh THIS_FILE --help    Preview: --dry-run    Integrity: --verify\n# Do not edit anything below the BODY marker, or --verify will report a change.\n"
    . "# Solaris: use the POSIX shell when /bin/sh is the old Bourne shell.\n"
    . "if [ -z \"\${SX_REEXEC:-}\" ] && [ -x /usr/xpg4/bin/sh ] && [ \"`uname -s`\" = SunOS ]; then\n  SX_REEXEC=1; export SX_REEXEC; exec /usr/xpg4/bin/sh \"\$0\" \"\$@\"\nfi\n"
    . "SX_SHA256='$sha'\n#__SCRIPTIX_BODY__\n";
  spew($outfile, $head . $body);
  return $count;
}

# ================================================================ results
sub read_csv {
  my ($file) = @_;
  my $t = slurp($file);
  $t =~ s/^\x{feff}//; $t =~ s/^#scriptix [^\n]*\n//;
  my (@rows, @f);
  pos($t) = 0;
  while (pos($t) < length $t) {
    my $v;
    if ($t =~ /\G"((?:[^"]|"")*)"/gc) { $v = $1; $v =~ s/""/"/g } else { $t =~ /\G([^,\n]*)/gc; $v = $1 }
    push @f, $v;
    if ($t =~ /\G,/gc) { push @f, '' if pos($t) == length $t; next }
    $t =~ /\G[^\n]*\n?/gc;
    push @rows, [@f]; @f = ();
  }
  push @rows, [@f] if @f;
  my $h = shift @rows or die "the results file is empty\n";
  my %c; for (my $i = 0; $i < @$h; $i++) { $c{lc trim($h->[$i])} = $i }
  die "$file isn't a ScriptIX results file\n" unless defined $c{seq} && defined $c{result};
  my @out;
  for my $r (@rows) {
    next unless grep { /\S/ } @$r;
    my %o;
    for my $n (keys %c) { my $v = defined $r->[$c{$n}] ? $r->[$c{$n}] : ''; $v =~ s/^'(?=[=+\@-])//; $o{$n} = $v }
    for (qw(id title severity time detail rc seconds command expected output mode os)) { $o{$_} = '' unless defined $o{$_} }
    $o{result} = uc trim($o{result});
    push @out, \%o;
  }
  return \@out;
}

sub from_xccdf { my ($x) = @_; my %m = (pass => ['PASS', ''], fixed => ['PASS', 'FIXED'], fail => ['FAIL', ''], error => ['SKIPPED', 'ERROR'], unknown => ['SKIPPED', 'UNKNOWN'],
  notapplicable => ['SKIPPED', 'NOT-APPLICABLE'], informational => ['SKIPPED', 'INFORMATIONAL'], notselected => ['SKIPPED', 'FILTERED']); return @{$m{$x} || ['SKIPPED', 'NOT-CHECKED']} }
# XCCDF results or ARF, as oscap writes them
my $RESPROF;
sub read_xml_results {
  my ($file) = @_;
  my $root = parse_xml($file);
  my ($tr, %rules);
  walk($root, sub { my ($n) = @_; if ($n->[0] eq 'TestResult') { $tr = $n } elsif ($n->[0] eq 'Rule') { $rules{at($n, 'id')} = $n unless $rules{at($n, 'id')} } });
  die "$file holds no XCCDF results\n" unless $tr;
  my $pr = el($tr, 'profile'); $RESPROF = $pr ? at($pr, 'idref') : undef;
  my @rows;
  for my $rr (els($tr, 'rule-result')) {
    my $res = text(el($rr, 'result'));
    next if $res eq 'notselected';
    my $id = at($rr, 'idref'); my $rule = $rules{$id};
    my ($r, $d) = from_xccdf($res);
    my $check = '';
    walk($rr, sub { $check = at($_[0], 'name') if $check eq '' && $_[0][0] eq 'check-content-ref' });
    push @rows, { seq => @rows + 1, id => short_id($id, '_rule_'), title => $rule ? text(el($rule, 'title')) : '', severity => at($rr, 'severity') ne '' ? at($rr, 'severity') : $rule ? at($rule, 'severity') : '',
      time => '', result => $r, detail => $d, rc => '', seconds => '', command => $check ne '' ? "oval $check" : '', expected => '', output => join("\n", map { trim(val($_)) } els($rr, 'message')), mode => '', os => '' };
  }
  die "$file holds no rule results\n" unless @rows;
  my $when = at($tr, 'start-time') ne '' ? at($tr, 'start-time') : at($tr, 'end-time');
  $when = substr($when, 0, 19); $when =~ s/T/ /;
  return (\@rows, text(el($tr, 'target')), $when);
}
sub load_rows { my ($f) = @_; return $f =~ /\.xml$/i ? (read_xml_results($f)) : (read_csv($f), describe($f)) }
sub describe { my ($f) = @_; return $f =~ m{(?:^|/)results_([^/]+)_(\d{4})(\d\d)(\d\d)_(\d\d)(\d\d)(\d\d)\.csv$} ? ($1, "$2-$3-$4 $5:$6:$7") : ('', '') }

sub to_xccdf {
  my ($r) = @_; my $d = $r->{detail};
  return $d eq 'FIXED' ? 'fixed' : 'pass' if $r->{result} eq 'PASS';
  return $d eq 'TIMEOUT' || $d eq 'INTERRUPTED' ? 'error' : 'fail' if $r->{result} eq 'FAIL';
  return $d eq 'NOT-APPLICABLE' || $d eq 'OTHER-OS' ? 'notapplicable' : $d eq 'FILTERED' ? 'notselected' : $d =~ /^(?:ERROR|TIMEOUT|PREVIEW-FAILED)$/ ? 'error'
    : $d eq 'UNKNOWN' ? 'unknown' : $d eq 'INFORMATIONAL' || $d eq 'WAIVED' ? 'informational' : 'notchecked';
}

# [row, rule] pairs; rule is undef without content
sub match_rows {
  my ($rows) = @_;
  my (%f, %s);
  for my $r (@{$D{rules} || []}) { my $a = safe_id($r->{id}, 0); $f{$a} = $r unless $f{$a}; my $b = safe_id($r->{short}, 0); $s{$b} = $r unless $s{$b} }
  return map { [$_, $f{$_->{id}} || $s{$_->{id}}] } @$rows;
}

sub scores {
  my ($rows, $p) = @_;
  my @l = grep { $_->[2] =~ /^(?:pass|fixed|fail|error|unknown)$/ } map { [$_->[0], $_->[1], to_xccdf($_->[0])] } match_rows($rows);
  my $w = sub { my ($r) = @_; return 1 unless $r; my $o = $p ? $p->{rr}{$r->{id}} : undef; return $o && defined $o->[4] && $o->[4] =~ /^\s*[-+]?(?:\d+\.?\d*|\.\d+)\s*$/ ? $o->[4] + 0 : $r->{weight} };
  my $ok = sub { return $_[0] eq 'pass' || $_[0] eq 'fixed' };
  my ($flat, $max, $n) = (0, 0, 0);
  for (@l) { my $x = $w->($_->[1]); $max += $x; if ($ok->($_->[2])) { $flat += $x; $n++ } }
  my $def;
  if (!grep { $_->[1] } @l) { $def = $max > 0 ? $flat / $max * 100 : 0 }
  else {
    my %by; for (@l) { $by{$_->[1]{id}} = $_->[2] if $_->[1] && !defined $by{$_->[1]{id}} }
    my (%kg, %kr);
    push @{$kg{$_->{parent} || ''}}, $_ for @{$D{groups}};
    push @{$kr{$_->{parent} || ''}}, $_ for @{$D{rules}};
    my $item;
    $item = sub {
      my ($key) = @_;
      my ($sum, $acc, $any) = (0, 0, 0);
      for my $r (@{$kr{$key} || []}) { my $res = $by{$r->{id}}; next unless defined $res; $any = 1; $sum += ($ok->($res) ? 100 : 0) * $w->($r); $acc += $w->($r) }
      for my $g (@{$kg{$key} || []}) { my ($s, $has) = $item->($g); next unless $has; $any = 1; $sum += $s * $g->{weight}; $acc += $g->{weight} }
      return ($acc > 0 ? $sum / $acc : 0, $any);
    };
    ($def) = $item->('');
  }
  return (['urn:xccdf:scoring:default', sprintf('%.6f', $def), 100], ['urn:xccdf:scoring:flat', $flat, $max], ['urn:xccdf:scoring:flat-unweighted', $n, scalar @l],
    ['urn:xccdf:scoring:absolute', @l && $n == @l ? 1 : 0, 1]);
}

sub xe { my ($s) = @_; $s = '' unless defined $s; $s =~ s/[^\t\n\x20-\x{d7ff}\x{e000}-\x{fffd}\x{10000}-\x{10ffff}]//g; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s }
sub xa { my $s = xe($_[0]); $s =~ s/"/&quot;/g; $s =~ s/\n/&#10;/g; $s =~ s/\t/&#9;/g; return $s }
sub ncname { my ($s) = @_; $s =~ s/[^A-Za-z0-9._-]/_/g; return $s }
sub now_iso { my @t = localtime; return sprintf('%04d-%02d-%02dT%02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) }
sub sev4 { my ($s) = @_; return $s =~ /^(?:info|low|medium|high)$/ ? $s : 'unknown' }

# seconds added to YYYY-MM-DDThh:mm:ss
sub add_secs {
  my ($t, $s) = @_;
  $t =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)$/ or return $t;
  my ($y, $m, $d, $x) = ($1, $2, $3, $4 * 3600 + $5 * 60 + $6 + int($s));
  while ($x >= 86400) {
    $x -= 86400; $d++;
    my @md = (31, $y % 4 == 0 && ($y % 100 || $y % 400 == 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    if ($d > $md[$m - 1]) { $d = 1; $m++; if ($m > 12) { $m = 1; $y++ } }
  }
  return sprintf('%04d-%02d-%02dT%02d:%02d:%02d', $y, $m, $d, int($x / 3600), int($x / 60) % 60, $x % 60);
}

sub test_result {
  my ($rows, $p, $host, $when) = @_;
  my $has = defined $D{id};
  my $start = $when =~ /^(\S+) (\S+)$/ ? "$1T$2" : now_iso();
  my $secs = 0; for (@$rows) { $secs += $_->{seconds} if $_->{seconds} =~ /^\d+(?:\.\d+)?$/ }
  my $end = add_secs($start, $secs);
  my $hid = $host ne '' ? "${host}_" : ''; my $st = $start; $st =~ s/\D//g;
  my $h = $host ne '' ? $host : 'unknown';
  my $x = "<TestResult xmlns=\"$NS12\" id=\"" . xa('xccdf_org.scriptix.content_testresult_' . ncname($hid . $st)) . "\" start-time=\"$start\" end-time=\"$end\" version=\""
    . xa($has && $D{version} ne '' ? $D{version} : '1') . "\" test-system=\"cpe:/a:scriptix:scriptix:$VERSION\">\n";
  $x .= '<benchmark href="' . xa($D{file}) . '" id="' . xa($D{id}) . "\"/>\n" if $has && $D{id} ne '';
  $x .= "<title>ScriptIX scan result</title>\n";
  $x .= '<profile idref="' . xa($p->{id}) . "\"/>\n" if $p && $p->{id} ne '';
  $x .= '<target>' . xe($h) . "</target>\n<target-facts>\n<fact name=\"urn:xccdf:fact:scanner:name\" type=\"string\">ScriptIX</fact>\n<fact name=\"urn:xccdf:fact:scanner:version\" type=\"string\">$VERSION</fact>\n"
    . '<fact name="urn:xccdf:fact:asset:identifier:host_name" type="string">' . xe($h) . "</fact>\n</target-facts>\n";
  if ($has) {
    $x .= '<platform idref="' . xa($_) . "\"/>\n" for @{$D{platforms}};
    for my $id (@{$D{valueorder}}) { my $v = value($id, $p); $x .= '<set-value idref="' . xa($id) . '">' . xe($v) . "</set-value>\n" if defined $v }
  }
  my %done;
  for my $m (match_rows($rows)) {
    my ($row, $rule) = @$m;
    my $id = $rule ? $rule->{id} : $row->{id} =~ /^xccdf_[^_]+_rule_.+$/ ? $row->{id} : 'xccdf_org.scriptix.content_rule_' . ncname($row->{id});
    next if $done{$id}++;
    my $res = to_xccdf($row);
    my $sev = $rule && $rule->{severity} ne '' ? $rule->{severity} : lc $row->{severity};
    $x .= '<rule-result idref="' . xa($id) . '"' . ($rule && $rule->{role} ne '' ? ' role="' . xa($rule->{role}) . '"' : '') . " time=\"$start\" severity=\"" . sev4($sev) . '" weight="'
      . sprintf('%.6f', $rule ? $rule->{weight} : 1) . "\">\n<result>$res</result>\n";
    if ($rule) { $x .= '<ident system="' . xa(at($_, 'system')) . '">' . xe(text($_)) . "</ident>\n" for @{$rule->{idents}} }
    $x .= '<message severity="info">' . xe($row->{output}) . "</message>\n" if $row->{output} ne '' && $res =~ /^(?:fail|error|unknown)$/;
    my ($chk) = $rule ? grep { $_->[0] eq 'check' } @{$rule->{checks}} : ();
    my $rf = $chk ? el($chk, 'check-content-ref') : undef;
    if ($rf) { $x .= '<check system="' . xa(at($chk, 'system')) . '"><check-content-ref' . (at($rf, 'name') ne '' ? ' name="' . xa(at($rf, 'name')) . '"' : '') . ' href="' . xa(at($rf, 'href')) . "\"/></check>\n" }
    elsif ($row->{command} =~ /^oval (oval:\S+)/) { $x .= "<check system=\"$OVALSYS\"><check-content-ref name=\"" . xa($1) . "\" href=\"#oval\"/></check>\n" }
    $x .= "</rule-result>\n";
  }
  if ($has) {
    for my $r (grep { !$done{$_->{id}} } @{$D{rules}}) {
      $x .= '<rule-result idref="' . xa($r->{id}) . "\" time=\"$start\" severity=\"" . sev4($r->{severity}) . '" weight="' . sprintf('%.6f', $r->{weight}) . "\"><result>notselected</result></rule-result>\n";
    }
  }
  $x .= "<score system=\"$_->[0]\" maximum=\"" . sprintf('%.6f', $_->[2]) . '">' . sprintf('%.6f', $_->[1]) . "</score>\n" for scores($rows, $p);
  return $x . "</TestResult>\n";
}

my $XMLHEAD = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
# the benchmark as text, without old results and signatures, with a tailored profile added
sub bench_copy {
  my ($p) = @_;
  my $b = $S{bench};
  return undef unless $b && $b->[1] eq $NS12;
  my $s = raw_node($b);
  for my $n (reverse grep { $_->[0] eq 'TestResult' || $_->[0] eq 'signature' } kids($b)) {
    my $t = substr(${$FILES{$n->[9]}}, $n->[4], $n->[5] - $n->[4]); utf8::decode($t);
    my $i = rindex($s, $t);
    substr($s, $i, length $t) = '' if $i >= 0;
  }
  if ($p && $p->{tailored}) {
    my ($last) = reverse els($b, 'Profile');
    if ($last) {
      my $t = substr(${$FILES{$last->[9]}}, $last->[4], $last->[5] - $last->[4]); utf8::decode($t);
      my $x = "\n<Profile xmlns=\"$NS12\" id=\"" . xa($p->{id}) . '"' . ($p->{extends} ne '' ? ' extends="' . xa(strip_hash($p->{extends})) . '"' : '') . '><title>' . xe($p->{title}) . "</title>\n";
      for my $o (@{$p->{ops}}) {
        if ($o->[0] eq 'select') { $x .= '<select idref="' . xa($o->[1]) . '" selected="' . xa($o->[2]) . "\"/>\n" }
        elsif ($o->[0] eq 'set-value') { $x .= '<set-value idref="' . xa($o->[1]) . '">' . xe($o->[2]) . "</set-value>\n" }
        elsif ($o->[0] eq 'refine-value') { $x .= '<refine-value idref="' . xa($o->[1]) . '" selector="' . xa($o->[2]) . "\"/>\n" }
      }
      my $i = index($s, $t);
      substr($s, $i + length $t, 0) = "$x</Profile>\n" if $i >= 0;
    }
  }
  return $s;
}
sub xccdf_text {
  my ($rows, $p, $host, $when) = @_;
  my $tr = test_result($rows, $p, $host, $when);
  my $b = bench_copy($p);
  return $XMLHEAD . $tr unless defined $b;
  $b =~ s/(<\/[^<>]+>)\s*\z/$tr$1/;
  return "$XMLHEAD$b\n";
}
sub arf_text {
  my ($rows, $p, $host, $when) = @_;
  my $tr = test_result($rows, $p, $host, $when);
  my $h = $host; $h =~ s/[^A-Za-z0-9.-]/-/g; $h =~ s/^[-.]+//; $h =~ s/[-.]+$//; $h = 'unknown' if $h eq '';
  my $c = $S{root} && $S{root}[0] eq 'data-stream-collection' ? raw_node($S{root}) : bench_copy($p);
  $c = "<Benchmark xmlns=\"$NS12\" id=\"xccdf_org.scriptix.content_benchmark_none\"><status>incomplete</status><title>Own checks</title><version>1</version></Benchmark>" unless defined $c;
  return $XMLHEAD . '<arf:asset-report-collection xmlns:arf="http://scap.nist.gov/schema/asset-reporting-format/1.1" xmlns:core="http://scap.nist.gov/schema/reporting-core/1.1" xmlns:ai="http://scap.nist.gov/schema/asset-identification/1.1">'
    . '<core:relationships xmlns:arfvocab="http://scap.nist.gov/specifications/arf/vocabulary/relationships/1.0#"><core:relationship type="arfvocab:createdFor" subject="xccdf1"><core:ref>collection1</core:ref></core:relationship>'
    . '<core:relationship type="arfvocab:isAbout" subject="xccdf1"><core:ref>asset0</core:ref></core:relationship></core:relationships>'
    . "<arf:report-requests><arf:report-request id=\"collection1\"><arf:content>$c</arf:content></arf:report-request></arf:report-requests>"
    . "<arf:assets><arf:asset id=\"asset0\"><ai:computing-device><ai:fqdn>$h</ai:fqdn><ai:hostname>$h</ai:hostname></ai:computing-device></arf:asset></arf:assets>"
    . "<arf:reports><arf:report id=\"xccdf1\"><arf:content>$tr</arf:content></arf:report></arf:reports></arf:asset-report-collection>\n";
}

# ================================================================ HTML
sub he { my ($s) = @_; $s = '' unless defined $s; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; $s =~ s/'/&#39;/g; $s =~ s/([\x{a0}-\x{ff}])/'&#' . ord($1) . ';'/ge; return $s }
sub now_text { my $t = now_iso(); $t =~ s/T/ /; return substr($t, 0, 16) }

sub html_report {
  my ($rows, $p, $host, $when, $source) = @_;
  my %n = (PASS => 0, FAIL => 0, SKIPPED => 0);
  $n{$_->{result} eq 'PASS' || $_->{result} eq 'FAIL' ? $_->{result} : 'SKIPPED'}++ for @$rows;
  my $rate = $n{PASS} + $n{FAIL} ? int(100 * $n{PASS} / ($n{PASS} + $n{FAIL})) : 0;
  my ($def) = scores($rows, $p);
  my $score = sprintf('%.1f', $def->[1]);
  my $title = defined $D{title} && $D{title} ne '' ? $D{title} : 'ScriptIX report';
  my $o = <<'EOF';
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#f6f7fb;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--pass:#15803d;--passbg:#dcfce7;--fail:#b91c1c;--failbg:#fee2e2;--skip:#475569;--skipbg:#f1f5f9;--accent:#4f46e5}
@media screen and (prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#131a2e;--text:#e2e8f0;--muted:#94a3b8;--line:#243049;--passbg:#0f2e1c;--pass:#4ade80;--failbg:#3a1414;--fail:#f87171;--skipbg:#1e293b;--skip:#cbd5e1;--accent:#a5b4fc}}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1200px;margin:0 auto;padding:28px 16px}h1{margin:0;font-size:24px}.sub{color:var(--muted);margin:4px 0 22px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:22px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.tile .n{font-size:28px;font-weight:700}.tile .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
.bar{height:10px;border-radius:6px;background:var(--failbg);overflow:hidden;margin-top:8px}.bar i{display:block;height:100%;background:var(--pass)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
code,pre{font:12px/1.45 "Cascadia Mono",Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;margin:0}
.b{display:inline-block;padding:2px 8px;border-radius:999px;font-weight:700;font-size:12px;white-space:nowrap}
.PASS{background:var(--passbg);color:var(--pass)}.FAIL{background:var(--failbg);color:var(--fail)}.SKIPPED{background:var(--skipbg);color:var(--skip)}
.muted{color:var(--muted);overflow-wrap:anywhere}.foot{color:var(--muted);font-size:12px;margin-top:18px}
details{margin-top:6px}summary{cursor:pointer;color:var(--accent);font-weight:600}details p{margin:6px 0}details pre{background:var(--skipbg);border-radius:8px;padding:10px}
@page{size:A4 landscape;margin:12mm}
@media print{*{print-color-adjust:exact;-webkit-print-color-adjust:exact}body{background:#fff;font-size:12px}.wrap{max-width:none;padding:0}tr{break-inside:avoid}}
</style>
EOF
  $o .= '<title>' . he($title) . '</title></head><body><div class="wrap"><h1>' . he($title) . '</h1><p class="sub">';
  $o .= 'Profile <strong>' . he($p->{title}) . '</strong> &middot; ' if $p && $p->{title} ne '';
  $o .= 'Host <strong>' . he($host) . '</strong> &middot; ' if $host ne '';
  $o .= 'run ' . he($when) . ' &middot; ' if $when ne '';
  $o .= 'source ' . he($source) . '</p><div class="tiles">';
  $o .= "<div class=\"tile\"><div class=\"n\">$_->[1]</div><div class=\"l\">$_->[0]</div></div>" for (['Total', scalar @$rows], ["Passed \x{2713}", $n{PASS}], ["Failed \x{2715}", $n{FAIL}], ['Skipped', $n{SKIPPED}]);
  $o .= "<div class=\"tile\"><div class=\"n\">$rate%</div><div class=\"l\">Pass rate</div><div class=\"bar\"><i style=\"width:$rate%\"></i></div></div>";
  $o .= "<div class=\"tile\"><div class=\"n\">$score</div><div class=\"l\">Score of 100</div></div></div>";
  $o .= '<table><thead><tr><th>#</th><th>Result</th><th>Severity</th><th>Rule</th><th>Output</th></tr></thead><tbody>';
  for my $m (match_rows($rows)) {
    my ($r, $x) = @$m;
    my $cls = $r->{result} eq 'PASS' || $r->{result} eq 'FAIL' ? $r->{result} : 'SKIPPED';
    my $lab = $cls eq 'PASS' ? "\x{2713} PASS" : $cls eq 'FAIL' ? "\x{2715} FAIL" : "\x{2013} $r->{result}";
    $o .= '<tr><td>' . he($r->{seq}) . "</td><td><span class=\"b $cls\">" . he($lab) . '</span>' . ($r->{detail} ne '' ? '<div class="muted">' . he($r->{detail}) . '</div>' : '') . '</td><td>' . he($r->{severity})
      . '</td><td><strong>' . he($r->{title} ne '' ? $r->{title} : $r->{id}) . '</strong><div class="muted">' . he($r->{id}) . '</div>';
    if ($x) {
      my ($d, $w) = (cut(text(el($x->{node}, 'description')), 1500), cut(text(el($x->{node}, 'rationale')), 1500));
      my $f = fix_of($x, 'bash');
      $o .= '<details><summary>Details</summary>' . ($d ne '' ? '<p>' . he($d) . '</p>' : '') . ($w ne '' ? '<p><strong>Why:</strong> ' . he($w) . '</p>' : '')
        . (@{$x->{idents}} ? '<p class="muted">' . he(join(', ', map { text($_) } @{$x->{idents}})) . '</p>' : '')
        . ($f && $cls eq 'FAIL' ? '<p><strong>Fix:</strong></p><pre>' . he(fix_text($f, $p)) . '</pre>' : '') . '</details>';
    }
    elsif ($r->{command} ne '') { $o .= '<details><summary>Command</summary><pre>' . he($r->{command}) . '</pre>' . ($r->{expected} ne '' ? '<p class="muted">expected: ' . he($r->{expected}) . '</p>' : '') . '</details>' }
    $o .= '</td><td><pre>' . he($r->{output}) . "</pre></td></tr>\n";
  }
  return $o . "</tbody></table><p class=\"foot\">Made by ScriptIX $VERSION on " . now_text() . ". Output is cut to the first 200 characters; the full log is in run_*.txt next to the results.</p></div></body></html>\n";
}

sub guide {
  my ($p, $sel) = @_;
  my $o = <<'EOF';
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#f6f7fb;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--accent:#4f46e5;--hi:#b91c1c;--me:#b45309;--lo:#15803d;--code:#f1f5f9}
@media screen and (prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#131a2e;--text:#e2e8f0;--muted:#94a3b8;--line:#243049;--accent:#a5b4fc;--hi:#f87171;--me:#fbbf24;--lo:#4ade80;--code:#0f172a}}
*{box-sizing:border-box}body{margin:0;font:14px/1.55 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1000px;margin:0 auto;padding:28px 16px}h1{margin:0 0 4px;font-size:24px}.sub{color:var(--muted);margin:0 0 20px}
h2{font-size:17px;margin:26px 0 8px;color:var(--accent)}
.rule{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:0 0 12px;break-inside:avoid-page}
.rule h3{margin:0 0 6px;font-size:15px}.id{color:var(--muted);font:12px Consolas,monospace;overflow-wrap:anywhere}
.sev{font-size:12px;font-weight:700;margin-left:8px}.high{color:var(--hi)}.medium{color:var(--me)}.low{color:var(--lo)}
p{margin:6px 0}pre{background:var(--code);border-radius:8px;padding:10px;white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.45 Consolas,monospace;margin:8px 0 0}
details{margin-top:8px}summary{cursor:pointer;color:var(--accent);font-weight:600}.toc{columns:2;margin:0 0 20px;padding-left:18px}.toc a{color:var(--accent);text-decoration:none}
.foot{color:var(--muted);font-size:12px;margin-top:18px}
</style>
EOF
  chomp $o;
  my @r = grep { $sel->{$_->{id}} } @{$D{rules}};
  $o .= '<title>' . he($D{title}) . '</title></head><body><div class="wrap"><h1>' . he($D{title}) . '</h1><p class="sub">' . ($p->{title} ne '' ? 'Profile <strong>' . he($p->{title}) . '</strong> &middot; ' : '')
    . @r . ' rules' . ($D{version} ne '' ? ' &middot; version ' . he($D{version}) : '') . '</p>';
  if ($p->{description} ne '') { $o .= '<p>' . he($p->{description}) . '</p>' } elsif ($D{description} ne '') { $o .= '<p>' . he($D{description}) . '</p>' }
  my (@g, %g);
  for (@r) { my $k = $_->{parent} || ''; push @g, $k unless $g{$k}; push @{$g{$k}}, $_ }
  my $name = sub { my ($x) = @_; my @n; for (; $x && @n < 3; $x = $x->{parent}) { unshift @n, $x->{title} if $x->{title} ne '' } return @n ? join(" \x{203a} ", @n) : 'Rules' };
  $o .= '<ul class="toc">';
  for (my $i = 0; $i < @g; $i++) { $o .= "<li><a href=\"#g$i\">" . he($name->($g[$i])) . '</a> (' . @{$g{$g[$i]}} . ')</li>' }
  $o .= '</ul>';
  for (my $i = 0; $i < @g; $i++) {
    $o .= "<h2 id=\"g$i\">" . he($name->($g[$i])) . '</h2>';
    for my $r (@{$g{$g[$i]}}) {
      my $sev = he(lc $r->{severity});
      my ($d, $w) = (cut(text(el($r->{node}, 'description')), 1500), cut(text(el($r->{node}, 'rationale')), 1500));
      $o .= '<div class="rule"><h3>' . he($r->{title}) . "<span class=\"sev $sev\">$sev</span></h3><div class=\"id\">" . he($r->{id}) . '</div>';
      $o .= '<p>' . he($d) . '</p>' if $d ne '';
      $o .= '<p><strong>Why:</strong> ' . he($w) . '</p>' if $w ne '';
      $o .= '<p class="id">' . he(join(', ', map { text($_) } @{$r->{idents}})) . '</p>' if @{$r->{idents}};
      $o .= '<details><summary>Fix (' . he(fix_kind(at($_, 'system'))) . ')</summary><pre>' . he(fix_text($_, $p)) . '</pre></details>' for @{$r->{fixes}};
      $o .= '</div>';
    }
  }
  return $o . "<p class=\"foot\">Made by ScriptIX $VERSION on " . now_text() . '.</p></div></body></html>';
}

# ================================================================ info, fix, tailor, validate
sub info {
  platform_for($_) for @{$D{rules}};   # loads the platform checks, so they are counted too
  refresh_oval();
  my $o = "$S{kind}" . ($S{version} ne '' ? " $S{version}" : '') . ": $D{file}\n\n";
  $o .= "Title: $D{title}\n" if $D{title} ne '';
  $o .= "Id: $D{id}\n" if $D{id} ne '';
  $o .= "Version: $D{version}\n" if $D{version} ne '';
  $o .= "Status: $D{status}\n" if $D{status} ne '';
  $o .= 'Platform: ' . join(', ', @{$D{platforms}}) . "\n" if @{$D{platforms}};
  $o .= 'Benchmarks: ' . join(', ', @{$S{benchmarks}}) . "\n" if @{$S{benchmarks}} > 1;
  $o .= 'Rules: ' . @{$D{rules}} . ' in ' . @{$D{groups}} . ' groups, ' . @{$D{valueorder}} . " values\n" if @{$D{rules}};
  my $count = sub { my (%n, @k); for (@_) { push @k, $_ unless $n{$_}++ } my $i = 0; my %o = map { $_ => $i++ } @k; return join(', ', map { "$_ $n{$_}" } sort { $n{$b} <=> $n{$a} || $o{$a} <=> $o{$b} } @k) };
  $o .= "OVAL definitions: $OVDEFS\nOVAL tests: " . $count->(map { substr($_->[0], 0, -5) } grep { $_->[0] =~ /_test$/ } map { $OV{$_} } @OVIDS) . "\n";
  my @fk; for my $r (@{$D{rules}}) { my %s; push @fk, grep { !$s{$_}++ } map { fix_kind(at($_, 'system')) } @{$r->{fixes}} }
  $o .= 'Fixes: ' . $count->(@fk) . "\n" if @fk;
  if (@{$D{profiles}}) { $o .= "\nProfiles:\n"; $o .= "  $_->{title}  (" . scalar(keys %{$_->{selected}}) . " rules)\n    $_->{id}\n" for @{$D{profiles}} }
  return $o;
}

sub one_line { my ($s) = @_; $s =~ s/[\r\n]+/ /g; return $s }
sub fixes {
  my ($p, $kind, $sel) = @_;
  my @l = grep { $_->[1] } map { [$_, fix_of($_, $kind)] } grep { $sel->{$_->{id}} } @{$D{rules}};
  die "none of these rules has a $kind fix\n" unless @l;
  my $o = $kind eq 'bash' ? "#!/usr/bin/env bash\n" : $kind eq 'ansible' ? "---\n" : '';
  $o .= '# ' . one_line($D{title}) . "\n# Profile: " . one_line($p->{title} ne '' ? $p->{title} : '(none)') . "\n# " . @l . " fixes, made by ScriptIX $VERSION. Test on a spare server first.\n\n";
  if ($kind eq 'ansible') {
    $o .= "- hosts: all\n  tasks:\n";
    for (@l) {
      $o .= "\n    # " . one_line($_->[0]{title}) . "  ($_->[0]{id})\n";
      for my $x (split /\n/, fix_text($_->[1], $p), -1) { if ($x =~ /\S/) { $x =~ s/\s+$//; $o .= "    $x\n" } else { $o .= "\n" } }
    }
    return $o;
  }
  my $n = 0;
  for (@l) {
    my $id = $_->[0]{id}; $n++;
    $o .= "\n" . '#' x 79 . "\n# $n/" . @l . '  ' . one_line($_->[0]{title}) . "\n# $id\n";
    if ($kind eq 'bash') { $id =~ s/[^A-Za-z0-9._-]/_/g; $o .= "(>&2 echo \"$n/" . @l . ": $id\")\n" }
    my $t = fix_text($_->[1], $p); $t =~ tr/\r//d;
    $o .= "$t\n";
  }
  return $o;
}

sub find_rule { my ($n) = @_; for (@{$D{rules}}) { return $_ if $_->{id} eq $n } for (@{$D{rules}}) { return $_ if $_->{short} eq $n } die "rule not found: $n\n" }
sub tailor {
  my ($p, $o) = @_;
  my $sel = { %{($p || default_profile())->{selected}} };
  $sel->{find_rule($_)->{id}} = 1 for map { split /,/ } @{$o->{select} || []};
  delete $sel->{find_rule($_)->{id}} for map { split /,/ } @{$o->{unselect} || []};
  my $start = $p;
  while ($start && $start->{tailored}) { my $x = strip_hash($start->{extends}); my $s = $start; ($start) = grep { $_->{id} eq $x && $_ != $s && !$_->{tailored} } @{$D{profiles}} }
  my $work = { id => 'work', extends => $start ? $start->{id} : '', ops => [], title => '', description => '' };
  resolve($work);
  my %gs;
  for my $r (grep { $sel->{$_->{id}} && !$work->{selected}{$_->{id}} } @{$D{rules}}) { for (my $g = $r->{parent}; $g; $g = $g->{parent}) { push @{$work->{ops}}, ['select', $g->{id}, 'true'] unless $gs{$g->{id}}++ } }
  resolve($work);
  for my $r (@{$D{rules}}) { my $want = $sel->{$r->{id}} ? 1 : 0; push @{$work->{ops}}, ['select', $r->{id}, $want ? 'true' : 'false'] if ($work->{selected}{$r->{id}} ? 1 : 0) != $want }
  my $title = defined $o->{title} ? trim($o->{title}) : $p ? "$p->{title} (tailored)" : 'Custom profile';
  my $name = lc $title; $name =~ s/[^a-z0-9.-]+/-/g; $name =~ s/^-+//; $name =~ s/-+$//; $name = 'custom' if $name eq '';
  my $x = "$XMLHEAD<xccdf:Tailoring xmlns:xccdf=\"$NS12\" id=\"xccdf_org.scriptix.content_tailoring_$name\">\n  <xccdf:benchmark href=\"" . xa($D{file}) . "\"/>\n  <xccdf:version time=\"" . now_iso() . "\">1</xccdf:version>\n"
    . "  <xccdf:Profile id=\"xccdf_org.scriptix.content_profile_$name\"" . ($start ? ' extends="' . xa($start->{id}) . '"' : '') . ">\n    <xccdf:title xml:lang=\"en-US\" override=\"true\">" . xe($title)
    . "</xccdf:title>\n    <xccdf:description xml:lang=\"en-US\" override=\"true\">Made with ScriptIX $VERSION.</xccdf:description>\n";
  $x .= '    <xccdf:select idref="' . xa($_->[1]) . "\" selected=\"$_->[2]\"/>\n" for @{$work->{ops}};
  for my $id (@{$D{valueorder}}) {
    my ($w, $s) = (value($id, $p), profile_value($id, $start));
    next if !defined $w || (defined $s && $w eq $s);
    my $v = $D{values}{$id};
    my ($k) = grep { $v->{sel}{$_} eq $w } @{$v->{selorder}};
    $x .= defined $k ? '    <xccdf:refine-value idref="' . xa($id) . '" selector="' . xa($k) . "\"/>\n" : '    <xccdf:set-value idref="' . xa($id) . '">' . xe($w) . "</xccdf:set-value>\n";
  }
  return "$x  </xccdf:Profile>\n</xccdf:Tailoring>\n";
}

# structure checks, not a schema validation
sub validate {
  my ($file) = @_;
  load_source($file);
  my (@p, %seen);
  my $bad = sub { push @p, $_[0] unless $seen{$_[0]}++ };
  $bad->("Unknown SCAP file type: <$S{root}[0]>.") if !$S{bench} && !@{$S{oval}} && $S{root}[0] !~ /^(?:Tailoring|TestResult|asset-report-collection|oval_results|cpe-list|ocil)$/;
  for my $root (@{$S{oval}}) {
    my %ids;
    for my $sec (grep { $_->[0] =~ /^(?:definitions|tests|objects|states|variables)$/ } kids($root)) {
      for my $e (kids($sec)) { my $id = at($e, 'id'); if ($id eq '') { $bad->("OVAL <$e->[0]> without an id.") } elsif ($ids{$id}++) { $bad->("Duplicate OVAL id: $id") } }
    }
    walk($root, sub {
      my ($n) = @_; my $h = attrs($n);
      for (qw(test_ref definition_ref object_ref state_ref var_ref)) { $bad->("OVAL $_ points to missing $h->{$_}") if defined $h->{$_} && !$ids{$h->{$_}} }
      if (($n->[0] eq 'object_reference' || $n->[0] eq 'filter') && !kids($n)) { my $v = trim(val($n)); $bad->("OVAL $n->[0] points to missing $v") if $v =~ /^oval:/ && !$ids{$v} }
    });
    $bad->('The OVAL file does not say its schema version.') if oval_version($root) eq '';
  }
  if (my $b = $S{bench}) {
    my (%ids, %cl, @rules);
    walk($b, sub {
      my ($e) = @_; my $n = $e->[0];
      my $c = at($e, 'cluster-id'); $cl{$c} = 1 if $c ne '';
      push @rules, $e if $n eq 'Rule';
      return unless $n =~ /^(?:Benchmark|Group|Rule|Value|Profile)$/;
      my $id = at($e, 'id'); my $l = lc $n;
      if ($id eq '') { $bad->("<$n> without an id.") } elsif ($ids{$id}++) { $bad->("Duplicate id: $id") }
      $bad->("XCCDF 1.2 ids must look like xccdf_NAMESPACE_${l}_NAME: $id") if $b->[1] =~ /\/1\.2$/ && $id ne '' && $id !~ /^xccdf_[^_]+_${l}_.+$/;
    });
    $bad->('The benchmark has no <status>.') unless el($b, 'status');
    $bad->('The benchmark has no <version>.') unless el($b, 'version');
    for my $pr (els($b, 'Profile')) {
      my $x = at($pr, 'extends');
      $bad->(at($pr, 'id') . " extends a missing profile: $x") if $x ne '' && !$ids{strip_hash($x)};
      for my $r (grep { $_->[0] =~ /^(?:select|refine-value|set-value|refine-rule)$/ } kids($pr)) { my $i = at($r, 'idref'); $bad->(at($pr, 'id') . ": <$r->[0]> refers to missing $i") unless $ids{$i} || $cl{$i} }
    }
    my %texts = map { at($_, 'id') => 1 } els($b, 'plain-text');
    my %defs;
    for my $r (@rules) {
      my $rid = at($r, 'id');
      walk($r, sub {
        my ($c) = @_; my $n = $c->[0];
        if ($n eq 'check-export') { my $v = at($c, 'value-id'); $bad->("$rid: check-export of missing value $v") unless $ids{$v} }
        elsif ($n eq 'sub') { my $v = at($c, 'idref'); $bad->("$rid: <sub> of missing value $v") unless $ids{$v} || $texts{$v} }
        elsif ($n eq 'check-content-ref') {
          my $h = at($c, 'href'); return if $h =~ m{://};
          my $f = find_file($h);
          if (!$f) { $bad->("$rid: check file not found: $h"); return }
          my $name = at($c, 'name');
          if ($f->[0] eq 'oval_definitions' && $name ne '') {
            my $d = $defs{$f} ||= { map { at($_, 'id') => 1 } map { kids($_) } els($f, 'definitions') };
            $bad->("$rid: OVAL definition not found: $name") unless $d->{$name};
          }
        }
      });
    }
  }
  return @p;
}

# ================================================================ main
my $cmd = shift @ARGV;
fail('scap.pl is run by the scriptix command') unless defined $cmd;
my %o;
while (@ARGV) {
  my $k = shift @ARGV;
  fail("unknown option: $k") unless $k =~ /^--(file|profile|tailoring|set|benchmark|lib|out|rule|skip-rule|csv|type|html|xccdf|arf|select|unselect|title|source)$/;
  my $n = $1;
  fail("$k needs a value") unless @ARGV;
  my $v = shift @ARGV;
  utf8::decode($v) unless $n =~ /^(?:file|tailoring|lib|out|csv|html|xccdf|arf)$/;
  if ($n =~ /^(?:set|rule|skip-rule|select|unselect)$/) { push @{$o{$n}}, $v } else { $o{$n} = $v }
}
my $done = eval {
  if ($cmd eq 'validate') {
    my @p = validate($o{file});
    out(undef, join('', map { "$_\n" } @p));
    print STDERR @p ? scalar(@p) . " problem(s)\n" : "OK\n";
    exit(@p ? 1 : 0);
  }
  if ($cmd eq 'report') {
    my ($rows, $host, $when) = load_rows($o{csv});
    %D = ();
    if (!defined $o{file} && $o{csv} =~ /\.xml$/i) {   # results of XCCDF or ARF often hold the benchmark too
      $o{file} = $o{csv};
      eval { load_doc(\%o); 1 } or do { delete $o{file}; %D = (); %S = () };
      if (defined $o{file} && !defined $o{profile}) {
        ($o{profile}) = map { $_->{id} } grep { defined $RESPROF && $_->{id} eq $RESPROF } @{$D{profiles}};
      }
    }
    elsif (defined $o{file}) {      load_doc(\%o);
      my $n = grep { $_->[1] } match_rows($rows);
      if ($D{prebuilt} || $n * 2 <= @$rows) { my $t = $D{title}; %D = (title => $t); %S = () }
    }
    my $p = defined $D{id} ? find_profile($o{profile}) || default_profile() : undef;
    my ($src) = (defined $o{source} ? $o{source} : $o{csv}) =~ m{([^/]*)$};
    if (defined $o{html}) { my $h = html_report($rows, $p, $host, $when, $src); out($o{html}, $h) }
    spew($o{xccdf}, xccdf_text($rows, $p, $host, $when)) if defined $o{xccdf};
    spew($o{arf}, arf_text($rows, $p, $host, $when)) if defined $o{arf};
    my ($d) = scores($rows, $p);
    printf "%.2f\n", $d->[1] unless defined $o{html} && $o{html} eq '-';
    return 1;
  }
  load_doc(\%o);
  if ($cmd eq 'info') { out($o{out}, info()) }
  elsif ($cmd eq 'compile') {
    my $p = find_profile($o{profile});
    my @it;
    if (!$p && !$D{prebuilt}) {
      $p = default_profile();
      die "pick a profile with --profile:\n" . join('', map { '  ' . short_id($_->{id}, '_profile_') . "  $_->{title}\n" } @{$D{profiles}}) if !%{$p->{selected}} && @{$D{profiles}};
    }
    @it = check_items($p, $o{rule} || [], $o{'skip-rule'} || []);
    die "no rule is selected\n" unless @it;
    my $n = build_script($o{lib}, $o{out}, 'check', 1, @it);
    my $b = $D{file}; $b =~ s/\.xml$//i; $b =~ s/^ssg-//; $b =~ s/-(?:ds(?:-1\.[0-9])?|xccdf|oval)$//;
    my $nm = $b . ($p && $p->{id} ne '' ? '_' . short_id($p->{id}, '_profile_') : '');
    $nm =~ s/[^A-Za-z0-9._-]/_/g; $nm =~ s/^[^A-Za-z0-9]+//; $nm = substr($nm, 0, 60); $nm = 'scap' if $nm eq '';
    out(undef, join("\t", $nm, $n, $p && $p->{title} ne '' ? one_line($p->{title}) : one_line($D{title})) . "\n");
  }
  else {
    my $p = find_profile($o{profile});
    my $q = $p || default_profile();
    if ($cmd eq 'guide') { out($o{out}, guide($q, $q->{selected})) }
    elsif ($cmd eq 'tailor') { out($o{out}, tailor($p, \%o)) }
    elsif ($cmd eq 'fix') {
      my ($failed, %sel);
      %sel = %{$q->{selected}};
      if (defined $o{csv}) {
        my ($rows) = load_rows($o{csv});
        $failed = { map { $_->{id} => 1 } grep { $_->{result} eq 'FAIL' } @$rows };
        for (@{$D{rules}}) { delete $sel{$_->{id}} unless $failed->{safe_id($_->{id}, 0)} || $failed->{safe_id($_->{short}, 0)} }
      }
      my $type = defined $o{type} ? $o{type} : 'bash';
      if ($type eq 'script') {
        my @it = fix_items($q, $failed);
        die "none of these rules has a shell fix\n" unless @it;
        my $n = build_script($o{lib}, $o{out}, 'apply', 0, @it);
        print "$n\n";
      }
      else { out($o{out}, fixes($q, $type, \%sel)) }
    }
    else { die "unknown command\n" }
  }
  1;
};
unless ($done) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n$/\n/ if $e !~ /\n.*\n/s; chomp $e; fail($e) }
exit 0;
SCRIPTIX_END_OF_FILE
chmod 644 './usr/share/scriptix/lib/scap.pl' || fail "chmod ./usr/share/scriptix/lib/scap.pl"
chmod 700 './usr/share/scriptix/scripts'
cat > './usr/share/scriptix/scripts/scriptix_basic.sh' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write ./usr/share/scriptix/scripts/scriptix_basic.sh"
#!/bin/sh
# ScriptIX 2.6.0 - check script for Linux and AIX (POSIX sh)
# Commands: 36   Flagged risky: 0   Input hash: 10d7c4b3fe13b817
# Help: sh THIS_FILE --help    Preview: --dry-run    Integrity: --verify
# Do not edit anything below the BODY marker, or --verify will report a change.
# Solaris: use the POSIX shell when /bin/sh is the old Bourne shell.
if [ -z "${SX_REEXEC:-}" ] && [ -x /usr/xpg4/bin/sh ] && [ "`uname -s`" = SunOS ]; then
  SX_REEXEC=1; export SX_REEXEC; exec /usr/xpg4/bin/sh "$0" "$@"
fi
SX_SHA256='d9db575978e59ddb11dd19eb5b1f60c1ebf6a86a327467764b60699d5bea09cf'
#__SCRIPTIX_BODY__
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
SX_KIND='check'
SX_VERSION='2.6.0'
SX_TOTAL=36
SX_RISKY=0
SX_SCHEMA=3
STOP=0
NEEDROOT=0
TIMEOUT=60
REDACT=1
READONLY=1

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
run_item 'BASIC-ACC-01' 'Only root has user ID 0' 'high' 'any' 'sce' '' '0' 's' 'awk -F: '\''$3 == "0" && $1 != "root" { print $1; n = 1 } END { exit n + 0 }'\'' /etc/passwd'
run_item 'BASIC-ACC-02' 'No account has an empty password' 'high' 'Linux' 'sce' '' '0' 's' '[ -f /etc/shadow ] || exit 105
[ -r /etc/shadow ] || { echo '\''needs root'\''; exit 107; }
awk -F: '\''NF > 1 && $2 == "" { print $1; n = 1 } END { exit n + 0 }'\'' /etc/shadow'
run_item 'BASIC-ACC-03' 'No account has an empty password' 'high' 'AIX' 'sce' '' '0' 's' '[ "$(id -u)" = 0 ] || { echo '\''needs root'\''; exit 107; }
a=$(awk -F: '\''NF > 1 && $2 == "" { print $1 }'\'' /etc/passwd)
b=$(awk '\''/^[^ \t*].*:/ { u = $1 } $1 == "password" && $2 == "=" && $3 == "" { print u }'\'' /etc/security/passwd)
[ -z "$a$b" ] && exit 0
printf '\''%s\n'\'' "$a" "$b"
exit 1'
run_item 'BASIC-ACC-04' 'No hosts are trusted without a password (hosts.equiv, .rhosts)' 'high' 'any' 'sce' '' '0' 's' 'n=0
for f in /etc/hosts.equiv /.rhosts /root/.rhosts; do
  [ -f $f ] || continue
  grep -v '\''^[[:space:]]*#'\'' $f | grep . && { echo "in $f"; n=1; }
done
exit $n'
run_item 'BASIC-FIL-01' 'Only root can write /etc/passwd' 'high' 'any' 'sce' '' '0' 's' '[ -f /etc/passwd ] || exit 105
l=$(ls -ldL /etc/passwd) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c6,9)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-FIL-02' 'Only root can write /etc/group' 'high' 'any' 'sce' '' '0' 's' '[ -f /etc/group ] || exit 105
l=$(ls -ldL /etc/group) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c6,9)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-FIL-03' 'Others have no access to /etc/shadow' 'high' 'Linux' 'sce' '' '0' 's' '[ -f /etc/shadow ] || exit 105
l=$(ls -ldL /etc/shadow) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c6,8-10)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-FIL-04' 'Others have no access to /etc/security/passwd' 'high' 'AIX' 'sce' '' '0' 's' '[ "$(id -u)" = 0 ] || { echo '\''needs root'\''; exit 107; }
[ -f /etc/security/passwd ] || exit 105
l=$(ls -ldL /etc/security/passwd) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c5-10)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-FIL-05' 'Only root can write /etc/ssh/sshd_config' 'high' 'any' 'sce' '' '0' 's' '[ -f /etc/ssh/sshd_config ] || exit 105
l=$(ls -ldL /etc/ssh/sshd_config) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c6,9)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-FIL-06' 'Only root can write /etc/crontab' 'medium' 'any' 'sce' '' '0' 's' '[ -f /etc/crontab ] || exit 105
l=$(ls -ldL /etc/crontab) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c6,9)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-FIL-07' 'Others have no access to /etc/sudoers' 'high' 'any' 'sce' '' '0' 's' '[ -f /etc/sudoers ] || exit 105
l=$(ls -ldL /etc/sudoers) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c6,8-10)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-FIL-08' 'No file in /etc can be written by everyone' 'high' 'any' 'sce' '' '0' 's' 'l=$(find /etc -xdev -type f -perm -0002 -print 2>/dev/null | head -n 20)
[ -z "$l" ] && exit 0
printf '\''%s\n'\'' "$l"
exit 1'
run_item 'BASIC-FIL-09' '/tmp has the sticky bit' 'medium' 'any' 'sce' '' '0' 's' 'l=$(ls -ldL /tmp) || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c10)" in t|T) exit 0 ;; esac
exit 1'
run_item 'BASIC-FIL-10' 'Only root can write in root'\''s home folder' 'high' 'any' 'sce' '' '0' 's' 'h=$(awk -F: '\''$1 == "root" { print $6; exit }'\'' /etc/passwd)
[ -d "$h" ] || exit 105
l=$(ls -ldL "$h") || exit 107
printf '\''%s\n'\'' "$l"
case "$(printf '\''%s\n'\'' "$l" | cut -c6,9)" in *[!-]*) exit 1 ;; esac
exit 0'
run_item 'BASIC-SSH-01' 'sshd: root can'\''t log in with a password' 'high' 'any' 'sce' '' '0' 's' 'f=/etc/ssh/sshd_config
[ -f $f ] || exit 105
v=$(sshd -T 2>/dev/null | awk '\''tolower($1) == "permitrootlogin" { print tolower($2); exit }'\'')
if [ -z "$v" ]; then
  [ -r $f ] || { echo "cannot read $f"; exit 107; }
  grep -i '\''^[[:space:]]*include[[:space:]]'\'' $f && exit 107
  v=$(awk '\''tolower($1) == "match" { exit } tolower($1) == "permitrootlogin" { print tolower($2); exit }'\'' $f)
fi
echo "permitrootlogin ${v:-(not set)}"
case "$v" in yes) exit 1 ;; '\'''\'') exit 107 ;; esac
exit 0'
run_item 'BASIC-SSH-02' 'sshd: no empty passwords' 'high' 'any' 'sce' '' '0' 's' 'f=/etc/ssh/sshd_config
[ -f $f ] || exit 105
v=$(sshd -T 2>/dev/null | awk '\''tolower($1) == "permitemptypasswords" { print tolower($2); exit }'\'')
if [ -z "$v" ]; then
  [ -r $f ] || { echo "cannot read $f"; exit 107; }
  grep -i '\''^[[:space:]]*include[[:space:]]'\'' $f && exit 107
  v=$(awk '\''tolower($1) == "match" { exit } tolower($1) == "permitemptypasswords" { print tolower($2); exit }'\'' $f)
fi
echo "permitemptypasswords ${v:-(not set)}"
case "$v" in yes) exit 1 ;; '\'''\'') exit 0 ;; esac
exit 0'
run_item 'BASIC-SSH-03' 'sshd: no host-based login' 'medium' 'any' 'sce' '' '0' 's' 'f=/etc/ssh/sshd_config
[ -f $f ] || exit 105
v=$(sshd -T 2>/dev/null | awk '\''tolower($1) == "hostbasedauthentication" { print tolower($2); exit }'\'')
if [ -z "$v" ]; then
  [ -r $f ] || { echo "cannot read $f"; exit 107; }
  grep -i '\''^[[:space:]]*include[[:space:]]'\'' $f && exit 107
  v=$(awk '\''tolower($1) == "match" { exit } tolower($1) == "hostbasedauthentication" { print tolower($2); exit }'\'' $f)
fi
echo "hostbasedauthentication ${v:-(not set)}"
case "$v" in yes) exit 1 ;; '\'''\'') exit 0 ;; esac
exit 0'
run_item 'BASIC-NET-01' 'Nothing listens on the telnet port' 'high' 'Linux' 'sce' '' '0' 's' 'l=$(netstat -an 2>/dev/null)
[ -n "$l" ] || l=$(ss -ltn 2>/dev/null)
[ -n "$l" ] || { echo '\''no netstat and no ss'\''; exit 107; }
printf '\''%s\n'\'' "$l" | awk '\''/LISTEN/ && $4 ~ /[.:](23)$/ { print; n = 1 } END { exit n + 0 }'\'''
run_item 'BASIC-NET-02' 'Nothing listens on the FTP port' 'medium' 'Linux' 'sce' '' '0' 's' 'l=$(netstat -an 2>/dev/null)
[ -n "$l" ] || l=$(ss -ltn 2>/dev/null)
[ -n "$l" ] || { echo '\''no netstat and no ss'\''; exit 107; }
printf '\''%s\n'\'' "$l" | awk '\''/LISTEN/ && $4 ~ /[.:](21)$/ { print; n = 1 } END { exit n + 0 }'\'''
run_item 'BASIC-NET-03' 'Nothing listens on the rexec and rlogin ports' 'high' 'Linux' 'sce' '' '0' 's' 'l=$(netstat -an 2>/dev/null)
[ -n "$l" ] || l=$(ss -ltn 2>/dev/null)
[ -n "$l" ] || { echo '\''no netstat and no ss'\''; exit 107; }
printf '\''%s\n'\'' "$l" | awk '\''/LISTEN/ && $4 ~ /[.:](512|513)$/ { print; n = 1 } END { exit n + 0 }'\'''
run_item 'BASIC-NET-04' 'Nothing listens on the telnet port' 'high' 'AIX' 'sce' '' '0' 's' 'l=$(netstat -an 2>/dev/null)
[ -n "$l" ] || l=$(ss -ltn 2>/dev/null)
[ -n "$l" ] || { echo '\''no netstat and no ss'\''; exit 107; }
printf '\''%s\n'\'' "$l" | awk '\''/LISTEN/ && $4 ~ /[.:](23)$/ { print; n = 1 } END { exit n + 0 }'\'''
run_item 'BASIC-NET-05' 'Nothing listens on the FTP port' 'medium' 'AIX' 'sce' '' '0' 's' 'l=$(netstat -an 2>/dev/null)
[ -n "$l" ] || l=$(ss -ltn 2>/dev/null)
[ -n "$l" ] || { echo '\''no netstat and no ss'\''; exit 107; }
printf '\''%s\n'\'' "$l" | awk '\''/LISTEN/ && $4 ~ /[.:](21)$/ { print; n = 1 } END { exit n + 0 }'\'''
run_item 'BASIC-NET-06' 'Nothing listens on the rexec and rlogin ports' 'high' 'AIX' 'sce' '' '0' 's' 'l=$(netstat -an 2>/dev/null)
[ -n "$l" ] || l=$(ss -ltn 2>/dev/null)
[ -n "$l" ] || { echo '\''no netstat and no ss'\''; exit 107; }
printf '\''%s\n'\'' "$l" | awk '\''/LISTEN/ && $4 ~ /[.:](512|513)$/ { print; n = 1 } END { exit n + 0 }'\'''
run_item 'BASIC-KRN-01' 'Memory addresses are randomised' 'medium' 'Linux' 'sce' '' '0' 's' '[ -r /proc/sys/kernel/randomize_va_space ] || exit 105
v=$(cat /proc/sys/kernel/randomize_va_space)
echo "kernel.randomize_va_space = $v"
case "$v" in 2) exit 0 ;; esac
exit 1'
run_item 'BASIC-KRN-02' 'SYN cookies are on' 'medium' 'Linux' 'sce' '' '0' 's' '[ -r /proc/sys/net/ipv4/tcp_syncookies ] || exit 105
v=$(cat /proc/sys/net/ipv4/tcp_syncookies)
echo "net.ipv4.tcp_syncookies = $v"
case "$v" in 1|2) exit 0 ;; esac
exit 1'
run_item 'BASIC-KRN-03' 'ICMP redirects are ignored' 'medium' 'Linux' 'sce' '' '0' 's' '[ -r /proc/sys/net/ipv4/conf/all/accept_redirects ] || exit 105
v=$(cat /proc/sys/net/ipv4/conf/all/accept_redirects)
echo "net.ipv4.conf.all.accept_redirects = $v"
case "$v" in 0) exit 0 ;; esac
exit 1'
run_item 'BASIC-KRN-04' 'Source-routed packets are dropped' 'medium' 'Linux' 'sce' '' '0' 's' '[ -r /proc/sys/net/ipv4/conf/all/accept_source_route ] || exit 105
v=$(cat /proc/sys/net/ipv4/conf/all/accept_source_route)
echo "net.ipv4.conf.all.accept_source_route = $v"
case "$v" in 0) exit 0 ;; esac
exit 1'
run_item 'BASIC-KRN-05' 'Links in shared folders are protected' 'medium' 'Linux' 'sce' '' '0' 's' '[ -r /proc/sys/fs/protected_symlinks ] || exit 105
v=$(cat /proc/sys/fs/protected_symlinks)
echo "fs.protected_symlinks = $v"
case "$v" in 1) exit 0 ;; esac
exit 1'
run_item 'BASIC-SVC-01' 'The clock is kept right (chrony, ntp)' 'low' 'any' 'sce' '' '0' 's' 'l=$(ps -ef 2>/dev/null) || l=$(ps 2>/dev/null)
[ -n "$l" ] || exit 107
printf '\''%s\n'\'' "$l" | grep -E '\''[n]tpd|[c]hronyd|[t]imesyncd|[t]imemaster'\'''
run_item 'BASIC-SVC-02' 'A system log is kept' 'medium' 'any' 'sce' '' '0' 's' 'l=$(ps -ef 2>/dev/null) || l=$(ps 2>/dev/null)
[ -n "$l" ] || exit 107
printf '\''%s\n'\'' "$l" | grep -E '\''[s]yslogd|[s]yslog-ng|[j]ournald'\'''
run_item 'BASIC-AIX-01' 'root can'\''t log in remotely' 'high' 'AIX' 'sce' '' '0' 's' 'l=$(lsuser -a rlogin root) || exit 107
echo "$l"
case "$l" in *rlogin=false*) exit 0 ;; esac
exit 1'
run_item 'BASIC-AIX-02' 'Passwords have at least 8 characters' 'medium' 'AIX' 'sce' '' '0' 's' '[ "$(id -u)" = 0 ] || { echo '\''needs root'\''; exit 107; }
l=$(lssec -f /etc/security/user -s default -a minlen) || exit 107
echo "$l"
v=${l##*=}
[ "$v" -ge 8 ] 2>/dev/null && exit 0
exit 1'
run_item 'BASIC-AIX-03' 'Accounts lock after at most 10 failed logins' 'medium' 'AIX' 'sce' '' '0' 's' '[ "$(id -u)" = 0 ] || { echo '\''needs root'\''; exit 107; }
l=$(lssec -f /etc/security/user -s default -a loginretries) || exit 107
echo "$l"
v=${l##*=}
[ "$v" -ge 1 ] 2>/dev/null && [ "$v" -le 10 ] && exit 0
exit 1'
run_item 'BASIC-AIX-04' 'Passwords are not stored with the old crypt' 'high' 'AIX' 'sce' '' '0' 's' '[ "$(id -u)" = 0 ] || { echo '\''needs root'\''; exit 107; }
l=$(lssec -f /etc/security/login.cfg -s usw -a pwd_algorithm) || exit 107
echo "$l"
v=${l##*=}
case "$v" in '\'''\''|crypt) exit 1 ;; esac
exit 0'
run_item 'BASIC-AIX-05' 'ICMP redirects are ignored' 'medium' 'AIX' 'sce' '' '0' 's' 'l=$(no -o ipignoreredirects) || exit 107
echo "$l"
case "$l" in *'\''= 1'\'') exit 0 ;; esac
exit 1'
run_item 'BASIC-AIX-06' 'Source-routed packets are not accepted' 'medium' 'AIX' 'sce' '' '0' 's' 'l=$(no -o ipsrcrouterecv) || exit 107
echo "$l"
case "$l" in *'\''= 0'\'') exit 0 ;; esac
exit 1'
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

run_all
finish
cleanup
trap - 0
[ "$INTERRUPTED" = 1 ] && exit 4
[ "$NFAIL" -gt 0 ] && exit 1
exit 0
SCRIPTIX_END_OF_FILE
chmod 700 './usr/share/scriptix/scripts/scriptix_basic.sh' || fail "chmod ./usr/share/scriptix/scripts/scriptix_basic.sh"
cat > 'lpp_name' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write lpp_name"
4 R I scriptix {
scriptix.rte 2.6.2519.1381 01 N U en_US ScriptIX checks and hardening
[
*prereq bos.rte 7.1.0.0
%
/usr/bin 104
/usr/share/man/man8 8
/usr/share/scriptix/lib 416
/usr/share/scriptix/scripts 112
/usr/lib/objrepos 8
INSTWORK 16 16
%
%
%
]
}
SCRIPTIX_END_OF_FILE
chmod 644 'lpp_name' || fail "chmod lpp_name"
mkdir -p ./usr/lpp/scriptix .ctl || fail "mkdir"
cat > '.ctl/scriptix.rte.copyright' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write .ctl/scriptix.rte.copyright"
ScriptIX. The scripts in this package were made with the ScriptIX app.
SCRIPTIX_END_OF_FILE
chmod 644 '.ctl/scriptix.rte.copyright' || fail "chmod .ctl/scriptix.rte.copyright"
cat > '.ctl/scriptix.rte.inventory' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write .ctl/scriptix.rte.inventory"
/usr/bin/scriptix:
          owner = root
          group = system
          mode = 755
          type = FILE
          class = apply,inventory,scriptix.rte
          size = VOLATILE
          checksum = VOLATILE

/usr/share/man/man8/scriptix.8:
          owner = root
          group = system
          mode = 644
          type = FILE
          class = apply,inventory,scriptix.rte
          size = VOLATILE
          checksum = VOLATILE

/usr/share/scriptix:
          owner = root
          group = system
          mode = 755
          type = DIRECTORY
          class = apply,inventory,scriptix.rte

/usr/share/scriptix/content:
          owner = root
          group = system
          mode = 755
          type = DIRECTORY
          class = apply,inventory,scriptix.rte

/usr/share/scriptix/lib:
          owner = root
          group = system
          mode = 755
          type = DIRECTORY
          class = apply,inventory,scriptix.rte

/usr/share/scriptix/lib/oval.awk:
          owner = root
          group = system
          mode = 644
          type = FILE
          class = apply,inventory,scriptix.rte
          size = VOLATILE
          checksum = VOLATILE

/usr/share/scriptix/lib/runtime.sh:
          owner = root
          group = system
          mode = 644
          type = FILE
          class = apply,inventory,scriptix.rte
          size = VOLATILE
          checksum = VOLATILE

/usr/share/scriptix/lib/scap.pl:
          owner = root
          group = system
          mode = 644
          type = FILE
          class = apply,inventory,scriptix.rte
          size = VOLATILE
          checksum = VOLATILE

/usr/share/scriptix/scripts:
          owner = root
          group = system
          mode = 700
          type = DIRECTORY
          class = apply,inventory,scriptix.rte

/usr/share/scriptix/scripts/scriptix_basic.sh:
          owner = root
          group = system
          mode = 700
          type = FILE
          class = apply,inventory,scriptix.rte
          size = VOLATILE
          checksum = VOLATILE

SCRIPTIX_END_OF_FILE
chmod 644 '.ctl/scriptix.rte.inventory' || fail "chmod .ctl/scriptix.rte.inventory"
cat > '.ctl/scriptix.rte.al' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write .ctl/scriptix.rte.al"
./usr/bin/scriptix
./usr/share/man/man8/scriptix.8
./usr/share/scriptix
./usr/share/scriptix/content
./usr/share/scriptix/lib
./usr/share/scriptix/lib/oval.awk
./usr/share/scriptix/lib/runtime.sh
./usr/share/scriptix/lib/scap.pl
./usr/share/scriptix/scripts
./usr/share/scriptix/scripts/scriptix_basic.sh
SCRIPTIX_END_OF_FILE
chmod 644 '.ctl/scriptix.rte.al' || fail "chmod .ctl/scriptix.rte.al"
cat > '.ctl/scriptix.rte.size' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write .ctl/scriptix.rte.size"
/usr/bin 104
/usr/share/man/man8 8
/usr/share/scriptix/lib 416
/usr/share/scriptix/scripts 112
/usr/lib/objrepos 8
SCRIPTIX_END_OF_FILE
chmod 644 '.ctl/scriptix.rte.size' || fail "chmod .ctl/scriptix.rte.size"
cat > '.ctl/scriptix.rte.unconfig' <<'SCRIPTIX_END_OF_FILE' || fail "cannot write .ctl/scriptix.rte.unconfig"
#!/bin/sh
# the package is being removed: stop the scheduled scan
if [ -x /usr/bin/scriptix ]; then /usr/bin/scriptix schedule off >/dev/null 2>&1 || :; fi
exit 0
SCRIPTIX_END_OF_FILE
chmod 755 '.ctl/scriptix.rte.unconfig' || fail "chmod .ctl/scriptix.rte.unconfig"

# ---- control library ------------------------------------------------------------
cd .ctl || fail "cannot use .ctl"
LIBS="scriptix.rte.copyright scriptix.rte.inventory scriptix.rte.al scriptix.rte.size scriptix.rte.unconfig"
ar -cqg ../usr/lpp/scriptix/liblpp.a $LIBS 2>/dev/null || { rm -f ../usr/lpp/scriptix/liblpp.a; ar -cq ../usr/lpp/scriptix/liblpp.a $LIBS; } || fail "ar failed"
[ "$(ar -t ../usr/lpp/scriptix/liblpp.a | grep -c '^scriptix.rte\.')" = 5 ] || fail "ar made a bad library"
mv scriptix.rte.al ../../list || fail "cannot use the file list"
cd .. && rm -rf .ctl
chmod 644 usr/lpp/scriptix/liblpp.a
chown -R 0:0 . || fail "chown failed"

# ---- the .bff: lpp_name must come first, then only our own files and folders -----
BFF="$T/scriptix.rte.2.6.2519.1381.bff"
{ printf './lpp_name\n./usr/lpp/scriptix/liblpp.a\n'
  cat "$T/list"; } | backup -iqf "$BFF" || fail "backup failed"
[ -s "$BFF" ] || fail "backup made no file"
restore -Tqf "$BFF" 2>/dev/null | grep 'usr/bin/scriptix$' >/dev/null || fail "the .bff cannot be read back"

if [ "$MODE" = build ]; then
  cp "$BFF" "$START/scriptix.rte.2.6.2519.1381.bff" || fail "cannot write $START/scriptix.rte.2.6.2519.1381.bff"
  chmod 600 "$START/scriptix.rte.2.6.2519.1381.bff"
  printf 'Made %s\n' "$START/scriptix.rte.2.6.2519.1381.bff"
  printf 'Install it with: installp -acgXd %s scriptix.rte\n' "$START/scriptix.rte.2.6.2519.1381.bff"
  exit 0
fi
installp -acgXd "$BFF" scriptix.rte; r=$?
if lslpp -Lqc scriptix.rte 2>/dev/null | grep '2.6.2519.1381' >/dev/null && [ -x /usr/bin/scriptix ]; then
  printf 'Installed scriptix.rte 2.6.2519.1381\n'
  exit 0
fi
[ "$r" = 0 ] && r=1
printf 'installp did not install scriptix.rte (exit code %s). See /var/adm/ras/installp.summary\n' "$r" >&2
exit 1

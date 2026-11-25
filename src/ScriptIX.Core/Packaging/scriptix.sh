#!/bin/sh
# scriptix {{PKGVERSION}} - runs the ScriptIX scripts installed on this server.
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

VERSION='{{PKGVERSION}}'
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

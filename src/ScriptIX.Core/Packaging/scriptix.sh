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
umask 077

VERSION='{{PKGVERSION}}'
LIB=/usr/share/scriptix/scripts
STATE=/var/lib/scriptix
KEEP=30
CRONCMD='/usr/bin/scriptix scan -q'
OS=$(uname -s 2>/dev/null)

msg() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
die() { err "scriptix: $1"; exit "${2:-1}"; }
have() {
  for hv_d in /usr/bin /bin /usr/sbin /sbin; do
    if [ -f "$hv_d/$1" ] && [ -x "$hv_d/$1" ]; then return 0; fi
  done
  return 1
}

usage() {
  cat <<'EOF'
scriptix - run the ScriptIX scripts installed on this server

  scriptix list                     scripts on this server
  scriptix scan [NAME...] [-q]      run the check scripts (they change nothing)
  scriptix status                   last result of every script
  scriptix results [NAME] [--all]   failed rules of the last run (--all: every rule)
  scriptix diff [NAME]              what changed between the last two runs
  scriptix export [NAME] [--stamp]  print the last results file (CSV; --stamp: its time first)

  scriptix preview NAME             show what a script would change
  scriptix apply NAME [OPTIONS]     run a script that changes the server (it asks first)
  scriptix undo [MANIFEST]          put back what the last apply changed

  scriptix add FILE.sh              add a script made by ScriptIX
  scriptix remove NAME              remove an added script
  scriptix verify                   check that no script was changed
  scriptix selftest                 check that this server has every tool needed

  scriptix schedule daily HH:MM     scan every day
  scriptix schedule weekly DAY HH:MM   scan every week (DAY: mon ... sun)
  scriptix schedule off             stop the scheduled scan
  scriptix schedule                 show the schedule
  scriptix version

Run it as root. Results are kept in /var/lib/scriptix/runs (the last 30 scans).
Exit codes: 0 all passed, 1 a rule failed, 2 usage error, 3 cannot run.
EOF
}

# ---- helpers -------------------------------------------------------------------
need_root() {
  [ "$(id -u 2>/dev/null)" = 0 ] || die "run this as root" 3
  mkdir -p "$STATE/scripts" "$STATE/runs" || die "cannot create $STATE" 3
  chmod 700 "$STATE" "$STATE/scripts" "$STATE/runs"
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
  [ -d "$STATE/runs/$1" ] || return 0
  ls "$STATE/runs/$1" | grep '^scriptix_' | grep -v '^scriptix_undo_' |
    sed -n 's/^\(.*_\([0-9]\{8\}_[0-9]\{6\}\)\)$/\2 \1/p' | sort | awk '{ print $2 }'
}
csv_of() { for co_f in "$1"/results_*.csv; do [ -f "$co_f" ] && printf '%s\n' "$co_f"; done | head -n 1; }
# last_csv NAME [N] : the Nth newest results file (1 = newest)
last_csv() {
  lc_n=${2:-1}
  for lc_d in $(runs "$1" | awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }'); do
    lc_f=$(csv_of "$STATE/runs/$1/$lc_d")
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
  else
    pn_n=$(check_names | head -n 1)
    [ -n "$pn_n" ] || die "no check script is installed (scriptix add FILE.sh)" 3
  fi
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
  printf '%s\n' $$ > "$STATE/lock/pid"
  trap 'rm -rf "$STATE/lock"' 0
  trap 'rm -rf "$STATE/lock"; trap - 0; exit 4' 1 2 15
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
      scriptix_check_*|scriptix_oscap_*) rm -rf "$STATE/runs/$1/$pr_d" ;;
    esac
  done
}

do_status() {
  need_root
  printf '%-24s %-17s %7s %7s %8s\n' SCRIPT 'LAST RUN' PASSED FAILED SKIPPED
  all_scripts | while read st_n st_f; do
    st_c=$(last_csv "$st_n")
    if [ -z "$st_c" ]; then printf '%-24s %s\n' "$st_n" "never"; continue; fi
    set -- $(counts "$st_c")
    printf '%-24s %-17s %7s %7s %8s\n' "$st_n" "$(when_of "$st_c")" "$1" "$2" "$3"
  done
  msg ""
  show_schedule
}

do_results() {
  need_root
  rs_all=0; rs_n=''
  for rs_a in "$@"; do
    case "$rs_a" in --all) rs_all=1 ;; -*) die "unknown option: $rs_a" 2 ;; *) rs_n=$rs_a ;; esac
  done
  pick_name "$rs_n"
  rs_f=$(last_csv "$pn_n") || die "$pn_n was not run yet" 3
  msg "$pn_n, $(when_of "$rs_f")"
  awk -v all="$rs_all" "$CSVAWK"' NR > 1 { fields($0, 8)
      if (F[7] == "PASS") p++; else if (F[7] == "FAIL") f++; else s++
      if (all == 1 || F[7] == "FAIL") printf "%-8s %-14s %-40s %s\n", F[7], F[8], F[3], F[4] }
    END { printf "%d passed, %d failed, %d skipped\n", p, f, s }' "$rs_f"
  msg "Full results: $rs_f"
}

do_diff() {
  need_root
  pick_name "$1"
  df_new=$(last_csv "$pn_n") || die "$pn_n was not run yet" 3
  df_old=$(last_csv "$pn_n" 2) || die "$pn_n was run only once" 3
  msg "$pn_n: $(when_of "$df_old")  ->  $(when_of "$df_new")"
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
  for ex_a in "$@"; do
    case "$ex_a" in --stamp) ex_s=1 ;; -*) die "unknown option: $ex_a" 2 ;; *) ex_n=$ex_a ;; esac
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
  if [ -f "$STATE/scripts/$rm_n.sh" ]; then rm -f "$STATE/scripts/$rm_n.sh" && msg "Removed: $rm_n (its results are kept)"; return; fi
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
  diff) do_diff "$1" ;;
  export) do_export "$@" ;;
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

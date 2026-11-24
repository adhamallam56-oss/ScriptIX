#!/bin/sh
# ScriptIX {{VERSION}} package for AIX 7.1 or newer, fileset {{FILESET}} {{VRMF}}.
# AIX's own backup command turns the files in here into a real .bff for installp, smit or NIM.
#
#   sh THIS_FILE              make {{BFF}} in this folder
#   sh THIS_FILE --install    make it and install it with installp
#   sh THIS_FILE --uninstall  remove the fileset (the results in /var/lib/scriptix stay)
#
# Or install the .bff later: installp -acgXd {{BFF}} {{FILESET}}

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
  installp -u {{FILESET}}
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
{{PAYLOAD}}
# ---- control library ------------------------------------------------------------
cd .ctl || fail "cannot use .ctl"
LIBS="{{FILESET}}.copyright {{FILESET}}.inventory {{FILESET}}.al {{FILESET}}.size {{FILESET}}.unconfig"
ar -cqg ../usr/lpp/{{NAME}}/liblpp.a $LIBS 2>/dev/null || { rm -f ../usr/lpp/{{NAME}}/liblpp.a; ar -cq ../usr/lpp/{{NAME}}/liblpp.a $LIBS; } || fail "ar failed"
[ "$(ar -t ../usr/lpp/{{NAME}}/liblpp.a | grep -c '^{{FILESET}}\.')" = 5 ] || fail "ar made a bad library"
mv {{FILESET}}.al ../../list || fail "cannot use the file list"
cd .. && rm -rf .ctl
chmod 644 usr/lpp/{{NAME}}/liblpp.a
chown -R 0:0 . || fail "chown failed"

# ---- the .bff: lpp_name must come first, then only our own files and folders -----
BFF="$T/{{BFF}}"
{ printf './lpp_name\n./usr/lpp/{{NAME}}/liblpp.a\n'
  cat "$T/list"; } | backup -iqf "$BFF" || fail "backup failed"
[ -s "$BFF" ] || fail "backup made no file"
restore -Tqf "$BFF" 2>/dev/null | grep 'usr/bin/scriptix$' >/dev/null || fail "the .bff cannot be read back"

if [ "$MODE" = build ]; then
  cp "$BFF" "$START/{{BFF}}" || fail "cannot write $START/{{BFF}}"
  chmod 600 "$START/{{BFF}}"
  printf 'Made %s\n' "$START/{{BFF}}"
  printf 'Install it with: installp -acgXd %s {{FILESET}}\n' "$START/{{BFF}}"
  exit 0
fi
installp -acgXd "$BFF" {{FILESET}}; r=$?
if lslpp -Lqc {{FILESET}} 2>/dev/null | grep '{{VRMF}}' >/dev/null && [ -x /usr/bin/scriptix ]; then
  printf 'Installed {{FILESET}} {{VRMF}}\n'
  exit 0
fi
[ "$r" = 0 ] && r=1
printf 'installp did not install {{FILESET}} (exit code %s). See /var/adm/ras/installp.summary\n' "$r" >&2
exit 1

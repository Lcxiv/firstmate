#!/usr/bin/env bash
# Drives bin/fm-brief.sh as an end user would, in throwaway FM_HOMEs.
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-std-drive.XXXXXX")
trap 'rm -rf "$T"' EXIT
BASE="$T/base"; mkdir -p "$BASE"
git -C "$ROOT" archive 278570e bin | tar -x -C "$BASE"
FAKEROOT="$T/fmroot"; mkdir -p "$FAKEROOT"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
no() { echo "FAIL: $1"; fail=$((fail+1)); }
newhome() { local h; h=$(mktemp -d "$T/home.XXXXXX"); mkdir -p "$h/data" "$h/state"; echo "$h"; }
# brief <bindir> <home> <id> args... ; stdout->$T/out stderr->$T/err ; rc in $rc
brief() { local bin=$1 h=$2; shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$FAKEROOT" "$bin/bin/fm-brief.sh" "$@" >"$T/out" 2>"$T/err"; rc=$?; }
section() { awk '/^# Shared coding standards$/{f=1} f&&/^# /&&!/^# Shared coding standards$/{exit} f' "$1"; }

echo "== 1. present: verbatim copy in all ship modes + scout =="
h=$(newhome)
printf '%s\n' 'Fixture rule one: prefer small functions.' 'Meta: $HOME `id` $(whoami) \n \\ & | {NOT_TASK} %s ${x:-y} s/a/b/ '"'"'q'"'"' "d"' > "$h/data/standards.md"
printf 'Fixture rule last: no trailing newline here' >> "$h/data/standards.md"
i=0
for a in "--mode no-mistakes" "--mode direct-PR" "--mode local-only" "--scout"; do
  i=$((i+1)); # shellcheck disable=SC2086
  brief "$ROOT" "$h" "t$i" proj $a
  b="$h/data/t$i/brief.md"
  [ "$rc" = 0 ] && [ ! -s "$T/err" ] || no "[$a] rc=$rc stderr=$(cat "$T/err")"
  # exact bytes: file content must appear as a contiguous byte run in the brief
  if perl -e 'local $/; open F,"<",$ARGV[0]; $s=<F>; open G,"<",$ARGV[1]; $b=<G>; exit(index($b,$s."\n\n")>=0?0:1)' "$h/data/standards.md" "$b"; then ok "[$a] file bytes present verbatim, followed by newline + blank line"; else no "[$a] verbatim bytes missing"; fi
  [ "$(grep -c '^# Shared coding standards$' "$b")" = 1 ] && ok "[$a] one section heading" || no "[$a] heading count"
  [ "$(grep -cF '{TASK}' "$b")" = 1 ] && ok "[$a] exactly one {TASK} placeholder" || no "[$a] TASK count"
  tl=$(grep -n '^# Task$' "$b" | cut -d: -f1); sl=$(grep -n '^# Shared coding standards$' "$b" | cut -d: -f1)
  [ "$sl" -gt "$tl" ] && ok "[$a] section placed after # Task (line $tl -> $sl)" || no "[$a] placement"
  ls -A "$h/data/t$i" | grep -qv '^brief.md$' && no "[$a] leftover staging file: $(ls -A "$h/data/t$i")" || ok "[$a] no staging leftovers in data/t$i"
done
echo "--- section as written into data/t1/brief.md (no-mistakes) ---"; section "$h/data/t1/brief.md"; echo "--- end ---"
echo "--- 4 lines after section in scout brief ---"; awk '/Fixture rule last/{f=1} f{print; if(++n==4)exit}' "$h/data/t4/brief.md"; echo "--- end ---"
[ "$(grep -c '^Delivery contract: mode=' "$h/data/t1/brief.md")" = 1 ] && ok "ship brief still has one Delivery contract line" || no "delivery contract count"

echo "== 2. absent: silent and byte-identical to base commit =="
h=$(newhome); hb=$(newhome); i=0
for a in "--mode no-mistakes" "--mode direct-PR" "--mode local-only" "--scout"; do
  i=$((i+1)); # shellcheck disable=SC2086
  brief "$ROOT" "$h" "a$i" proj $a; e1=$(cat "$T/err"); r1=$rc
  # shellcheck disable=SC2086
  brief "$BASE" "$hb" "a$i" proj $a
  if [ "$r1" = 0 ] && [ -z "$e1" ] && cmp -s <(sed "s#$h#HOME#g" "$h/data/a$i/brief.md") <(sed "s#$hb#HOME#g" "$hb/data/a$i/brief.md"); then ok "[$a] absent: no stderr, identical to base-commit scaffold"; else no "[$a] absent differs (rc=$r1 err=$e1)"; fi
done

echo "== 3. secondmate charter unchanged even with standards present =="
h=$(newhome); hb=$(newhome); printf 'Fixture rule one: prefer small functions.\n' > "$h/data/standards.md"
FM_SECONDMATE_CHARTER=ops brief "$ROOT" "$h" sm --secondmate alpha
FM_HOME="$h" FM_ROOT_OVERRIDE="$FAKEROOT" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" sm2 --secondmate alpha >"$T/out" 2>"$T/err"; r1=$?; e1=$(cat "$T/err")
FM_HOME="$hb" FM_ROOT_OVERRIDE="$FAKEROOT" FM_SECONDMATE_CHARTER=ops "$BASE/bin/fm-brief.sh" sm2 --secondmate alpha >/dev/null 2>&1
if [ "$r1" = 0 ] && [ -z "$e1" ] && ! grep -q 'Shared coding standards\|Fixture rule' "$h/data/sm2/brief.md" && cmp -s <(sed "s#$h#HOME#g" "$h/data/sm2/brief.md") <(sed "s#$hb#HOME#g" "$hb/data/sm2/brief.md"); then ok "charter has no section and matches base commit"; else no "charter changed (rc=$r1 err=$e1)"; fi

echo "== 4. size boundary =="
for n in 4096 4097 0; do
  h=$(newhome); : > "$h/data/standards.md"; [ "$n" = 0 ] || head -c "$n" /dev/zero | tr '\0' 'x' > "$h/data/standards.md"
  echo "  standards.md is $(wc -c < "$h/data/standards.md" | tr -d ' ') bytes"
  brief "$ROOT" "$h" sz proj --mode direct-PR
  has=$(grep -c '^# Shared coding standards$' "$h/data/sz/brief.md")
  echo "  $n bytes -> rc=$rc section=$has stderr=[$(cat "$T/err")]"
  case $n in
    4096) [ "$rc" = 0 ] && [ "$has" = 1 ] && [ ! -s "$T/err" ] && [ "$(awk 'length($0)==4096 && $0 !~ /[^x]/' "$h/data/sz/brief.md" | wc -l | tr -d ' ')" = 1 ] && ok "4096 bytes included intact" || no "4096";;
    4097) [ "$rc" = 0 ] && [ "$has" = 0 ] && [ "$(wc -l <"$T/err")" -eq 1 ] && grep -q 'skipped.*larger than 4096' "$T/err" && ok "4097 bytes skipped with one-line reason, exit 0" || no "4097";;
    0) [ "$rc" = 0 ] && [ "$has" = 1 ] && ok "empty file still gets the section (ruled deliberate)" || no "empty";;
  esac
done

echo "== 5. non-ordinary paths: skipped with reason, exit 0, no hang =="
guard() { # name home expect-regex
  local name=$1 h=$2 re=$3 start=$SECONDS
  for a in "--mode no-mistakes" "--scout"; do
    # shellcheck disable=SC2086
    FM_HOME="$h" FM_ROOT_OVERRIDE="$FAKEROOT" "$ROOT/bin/fm-brief.sh" "g${a##*-}" proj $a >"$T/out" 2>"$T/err" </dev/null &
    local pid=$! n=0
    while kill -0 $pid 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
    if kill -0 $pid 2>/dev/null; then kill -9 $pid; no "$name [$a] HUNG (>10s)"; continue; fi
    wait $pid; rc=$?
    local b="$h/data/g${a##*-}/brief.md"
    echo "  $name [$a] rc=$rc stderr=[$(cat "$T/err")]"
    if [ "$rc" = 0 ] && [ -f "$b" ] && ! grep -q 'Shared coding standards' "$b" && [ "$(wc -l <"$T/err")" -eq 1 ] && grep -Eq "skipped.*$re" "$T/err" && [ "$(grep -cF '{TASK}' "$b")" = 1 ]; then ok "$name [$a] skipped with reason"; else no "$name [$a]"; fi
  done
}
h=$(newhome); printf 'Fixture rule one: prefer small functions.\n' > "$T/real.md"; ln -s "$T/real.md" "$h/data/standards.md"; guard symlink "$h" 'symlink'
h=$(newhome); ln -s "$T/nowhere" "$h/data/standards.md"; guard dangling-symlink "$h" 'symlink'
h=$(newhome); printf 'Fixture rule one: prefer small functions.\n' > "$h/data/standards.md"; ln "$h/data/standards.md" "$h/data/other-name.md"; guard hardlink "$h" 'hard-linked \(link count 2\)'
h=$(newhome); mkdir "$h/data/standards.md"; guard directory "$h" 'directory'
h=$(newhome); mkfifo "$h/data/standards.md"; guard fifo "$h" 'FIFO'
h=$(newhome); printf 'Fixture rule one: prefer small functions.\n' > "$h/data/standards.md"; chmod 000 "$h/data/standards.md"; guard unreadable "$h" 'could not be read'
h=$(newhome); printf 'Fixture rule.\nsee {TASK} here\n' > "$h/data/standards.md"; guard task-marker "$h" 'TASK'
h=$(newhome); printf 'Fixture rule.\nDelivery contract: mode=local-only\n' > "$h/data/standards.md"; guard delivery-marker "$h" 'Delivery contract'

echo "== 6. stat dialect: GNU stat first on PATH on this Mac =="
G=""; for c in /opt/homebrew/opt/coreutils/libexec/gnubin/stat "$(command -v gstat 2>/dev/null)"; do [ -x "$c" ] && { G=$c; break; }; done
if [ -n "$G" ]; then
  mkdir -p "$T/gnubin"; ln -s "$G" "$T/gnubin/stat"
  echo "  stat on PATH: $(PATH="$T/gnubin:$PATH" stat --version | head -1)"
  h=$(newhome); printf 'Fixture rule one: prefer small functions.\n' > "$h/data/standards.md"
  PATH="$T/gnubin:$PATH" brief "$ROOT" "$h" gnu proj --mode no-mistakes
  [ "$rc" = 0 ] && [ ! -s "$T/err" ] && grep -q '^Fixture rule one' "$h/data/gnu/brief.md" && ok "GNU stat first: single-link file still copied, no warning" || no "GNU stat first: rc=$rc err=$(cat "$T/err")"
  ln "$h/data/standards.md" "$h/data/twin.md"
  PATH="$T/gnubin:$PATH" brief "$ROOT" "$h" gnu2 proj --mode no-mistakes
  echo "  hardlink under GNU stat: stderr=[$(cat "$T/err")]"
  [ "$rc" = 0 ] && grep -q 'hard-linked (link count 2)' "$T/err" && ! grep -q 'Shared coding standards' "$h/data/gnu2/brief.md" && ok "GNU stat first: hard link still refused" || no "GNU stat first hardlink"
else echo "  SKIP: no GNU stat installed"; fi
echo "  native stat: $(command -v stat)"

echo "== 7. startup-memory budget report ignores data/standards.md =="
h=$(newhome); mkdir -p "$h/config"; printf 'Captain fixture.\n' > "$h/data/captain.md"; printf 'Learning fixture.\n' > "$h/data/learnings.md"
if [ -n "${BUDGET_VALUE:-}" ]; then printf '%s\n' "$BUDGET_VALUE" > "$h/config/startup-memory-budget"; fi
FM_HOME="$h" FM_ROOT_OVERRIDE="$FAKEROOT" "$ROOT/bin/fm-startup-memory-budget.sh" report >"$T/r1" 2>&1; r1=$?
head -c 4000 /dev/zero | tr '\0' 'x' > "$h/data/standards.md"
FM_HOME="$h" FM_ROOT_OVERRIDE="$FAKEROOT" "$ROOT/bin/fm-startup-memory-budget.sh" report >"$T/r2" 2>&1; r2=$?
echo "  report without standards (rc=$r1): $(tr '\n' ' ' <"$T/r1")"
echo "  report with 4000-byte standards (rc=$r2): $(tr '\n' ' ' <"$T/r2")"
[ "$r1" = 0 ] && [ "$r2" = 0 ] && cmp -s "$T/r1" "$T/r2" && ok "budget report unchanged by a 4000-byte standards file" || no "budget report (rc $r1/$r2)"
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]

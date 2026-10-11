#!/usr/bin/env bash
# Live driver for the handoff-note digest section. Builds throwaway primary
# homes under $LAB and runs the REAL session-open adapter against them.
set -u
WT=/Users/louiscondevaux/.no-mistakes/worktrees/71bad1a6f2bc/01M4MJ4CVC7KXTS0G6BY3328ED
EVID=/Users/louiscondevaux/.no-mistakes/evidence/01M4MJ4CVC7KXTS0G6BY3328ED
LAB=${LAB:-/tmp/fm-handoff-lab}
RUN="$WT/bin/fm-sessionstart-run.sh"
SS="$WT/bin/fm-session-start.sh"
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
MARK=SYNTHETIC-HANDOFF-BODY-MARKER
rm -rf "$LAB"; mkdir -p "$LAB" "$EVID"
SUMMARY="$EVID/handoff-scenarios-summary.txt"
: > "$SUMMARY"
FAILS=0

git_quiet() { git -c user.name=lab -c user.email=lab@example.invalid "$@"; }

mk_home() {  # <name> -> echoes root (main home: FM_HOME == code root)
  local r="$LAB/$1"
  mkdir -p "$r/bin" "$r/state" "$r/data" "$r/config"
  git_quiet init -q -b main "$r"
  git_quiet -C "$r" commit -q --allow-empty -m init
  printf '# lab firstmate\n' > "$r/AGENTS.md"
  printf '%s\n' "$r"
}

note() {  # <root> [extra-lines] : synthetic note only
  local r=$1 extra=${2:-0} i=1
  mkdir -p "$r/data/handoff"
  {
    printf '# Handoff, 2026-01-02 0304\n'
    printf 'Synthetic lab session about nothing in particular.\n\n'
    printf '## Waiting on the captain\n'
    printf -- '- %s: say "synthetic go".\n' "$MARK"
    while [ "$i" -le "$extra" ]; do printf -- '- filler line %s\n' "$i"; i=$((i + 1)); done
    printf '## Pointers\n- data/backlog.md\n'
  } > "$r/data/handoff/latest.md"
}

hook() {  # <root> <source> [VAR=val ...] : real adapter, user-shaped env
  local r=$1 src=$2; shift 2
  env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$r" FM_HOME="$r" \
    PATH="$BASE_PATH" "$@" "$RUN" --source "$src" </dev/null 2>&1
}

hook_payload() {  # <root> <json> : the adapter reading a Claude SessionStart payload
  local r=$1 json=$2
  printf '%s' "$json" | env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$r" FM_HOME="$r" \
    PATH="$BASE_PATH" "$RUN" 2>&1
}

section_of() {  # handoff section body (between its header rule and next rule)
  awk '
    /^HANDOFF NOTE FROM THE PREVIOUS SESSION$/ { grab=1; skip=1; next }
    grab && skip && /^=+$/ { skip=0; next }
    grab && /^=+$/ { exit }
    grab { print }
  '
}

check() {  # <scenario> <desc> <cmd...>
  local sc=$1 desc=$2; shift 2
  if "$@"; then printf 'PASS  [%s] %s\n' "$sc" "$desc" >> "$SUMMARY"
  else printf 'FAIL  [%s] %s\n' "$sc" "$desc" >> "$SUMMARY"; FAILS=$((FAILS + 1)); fi
}
has() { printf '%s' "$1" | grep -qF -- "$2"; }
hasnt() { ! printf '%s' "$1" | grep -qF -- "$2"; }
line_of() { printf '%s\n' "$1" | grep -n -- "$2" | head -1 | cut -d: -f1; }

save() {  # <file> <title> <full-output>
  { printf '### %s\n### (live run of bin/fm-sessionstart-run.sh against an isolated throwaway home)\n\n' "$2"
    printf '%s\n' "$3"; } > "$EVID/$1"
}

set_age_hours() {  # <file> <hours-old>
  local t
  t=$(( $(date +%s) - $2 * 3600 - 120 ))
  touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$1"
}

############ S1 fresh note on a true startup
r=$(mk_home fresh); note "$r"
out=$(hook "$r" startup)
save s1-fresh-startup.txt "S1 fresh note, true startup (source=startup)" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S1 "section header present" has "$out" "HANDOFF NOTE FROM THE PREVIOUS SESSION"
check S1 "body printed" has "$sec" "$MARK"
check S1 "last note line printed (whole note)" has "$sec" "- data/backlog.md"
check S1 "age and path label" has "$sec" "Written 0h ago (data/handoff/latest.md)"
check S1 "no unreadable-age line on this platform" hasnt "$out" "age could not be read"
w=$(line_of "$out" '^WAKE QUEUE$'); h=$(line_of "$out" '^HANDOFF NOTE FROM THE PREVIOUS SESSION$')
s=$(line_of "$out" '^SUPERVISION OPERATING INSTRUCTIONS'); f=$(line_of "$out" '^FLEET STATE$'); c=$(line_of "$out" '^CONTEXT')
printf 'S1 line numbers: WAKE QUEUE=%s HANDOFF=%s SUPERVISION=%s FLEET=%s CONTEXT=%s\n' "$w" "$h" "$s" "$f" "$c" >> "$SUMMARY"
check S1 "placed after WAKE QUEUE" test "${w:-0}" -lt "${h:-0}"
check S1 "placed before SUPERVISION" test "${h:-999999}" -lt "${s:-0}"
check S1 "placed before FLEET STATE" test "${h:-999999}" -lt "${f:-0}"
check S1 "read-once contract names the stale/unreadable/bounded case" has "$out" "the handoff section said the note was stale, unreadable, or bounded"
check S1 "digest completed (NEXT STEP)" has "$out" "NEXT STEP"
check S1 "lock acquired (not read-only)" hasnt "$out" "READ-ONLY SESSION"

############ S2 context re-emit after compaction and after /clear (payload-driven, like the Claude hook)
out=$(hook_payload "$r" '{"session_id":"lab","hook_event_name":"SessionStart","source":"compact"}')
save s2a-reemit-compact.txt "S2a context re-emit after compaction (Claude SessionStart payload source=compact)" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S2 "compact routed to re-emit" has "$out" "SESSION START (CONTEXT RE-EMIT) - $r"
check S2 "compact re-emit prints the handoff section" has "$out" "HANDOFF NOTE FROM THE PREVIOUS SESSION"
check S2 "compact re-emit prints the body" has "$sec" "$MARK"
out=$(hook_payload "$r" '{"session_id":"lab","hook_event_name":"SessionStart","source":"clear"}')
save s2b-reemit-clear.txt "S2b context re-emit after /clear (Claude SessionStart payload source=clear)" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S2 "clear routed to re-emit" has "$out" "SESSION START (CONTEXT RE-EMIT) - $r"
check S2 "clear re-emit prints the body" has "$sec" "$MARK"

############ S3 stale note (100h) - one line, never the body; and the exact 72h boundary
r=$(mk_home stale); note "$r"; set_age_hours "$r/data/handoff/latest.md" 100
out=$(hook "$r" startup)
save s3-stale-100h.txt "S3 stale note (mtime 100h ago), default 72h bound" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S3 "section still present" has "$out" "HANDOFF NOTE FROM THE PREVIOUS SESSION"
check S3 "body never leaked anywhere in digest" hasnt "$out" "$MARK"
check S3 "stale line names age, bound, and path" has "$sec" "Handoff note is 100h old (data/handoff/latest.md), past the 72h freshness bound"
check S3 "section is exactly one non-blank line" test "$(printf '%s\n' "$sec" | grep -c .)" -eq 1
printf 'S3 handoff section verbatim:\n%s\n' "$sec" >> "$SUMMARY"
set_age_hours "$r/data/handoff/latest.md" 72
out=$(hook "$r" startup)
check S3 "exactly 72h old is stale (bound is exclusive)" has "$out" "Handoff note is 72h old"
check S3 "72h note body withheld" hasnt "$out" "$MARK"
set_age_hours "$r/data/handoff/latest.md" 71
out=$(hook "$r" startup)
check S3 "71h old is still fresh and printed" has "$out" "Written 71h ago"
check S3 "71h note body printed" has "$out" "$MARK"

############ S4 freshness override, including invalid values falling back to 72
set_age_hours "$r/data/handoff/latest.md" 100
out=$(hook "$r" startup FM_SESSION_START_HANDOFF_MAX_AGE_HOURS=120)
save s4a-override-widened.txt "S4a 100h note with FM_SESSION_START_HANDOFF_MAX_AGE_HOURS=120" "$out"
check S4 "widened bound prints the 100h note" has "$out" "Written 100h ago"
check S4 "widened bound prints its body" has "$out" "$MARK"
set_age_hours "$r/data/handoff/latest.md" 30
out=$(hook "$r" startup FM_SESSION_START_HANDOFF_MAX_AGE_HOURS=24)
save s4b-override-narrowed.txt "S4b 30h note with FM_SESSION_START_HANDOFF_MAX_AGE_HOURS=24" "$out"
check S4 "narrowed bound makes a 30h note stale" has "$out" "Handoff note is 30h old (data/handoff/latest.md), past the 24h freshness bound"
check S4 "narrowed bound withholds the body" hasnt "$out" "$MARK"
set_age_hours "$r/data/handoff/latest.md" 100
for bad in abc 0 -5 ''; do
  out=$(hook "$r" startup "FM_SESSION_START_HANDOFF_MAX_AGE_HOURS=$bad")
  check S4 "invalid max-age '$bad' falls back to 72h (100h note stale)" has "$out" "past the 72h freshness bound"
  check S4 "invalid max-age '$bad' does not leak body" hasnt "$out" "$MARK"
done

############ S5 absent note
r=$(mk_home absent)
out=$(hook "$r" startup)
save s5-absent.txt "S5 no data/handoff/ at all" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S5 "section present" has "$out" "HANDOFF NOTE FROM THE PREVIOUS SESSION"
check S5 "absent line" has "$sec" "No handoff note (data/handoff/latest.md)"
check S5 "exactly one non-blank line" test "$(printf '%s\n' "$sec" | grep -c .)" -eq 1
check S5 "no file was created" test ! -e "$r/data/handoff/latest.md"
check S5 "no handoff dir created" test ! -e "$r/data/handoff"
printf 'S5 handoff section verbatim:\n%s\n' "$sec" >> "$SUMMARY"

############ S6 empty note
mkdir -p "$r/data/handoff"; : > "$r/data/handoff/latest.md"
out=$(hook "$r" startup)
save s6-empty.txt "S6 empty-but-present data/handoff/latest.md" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S6 "empty line" has "$sec" "Handoff note is empty (data/handoff/latest.md)"
check S6 "exactly one non-blank line" test "$(printf '%s\n' "$sec" | grep -c .)" -eq 1
check S6 "not announced as fresh" hasnt "$sec" "Written"
printf 'S6 handoff section verbatim:\n%s\n' "$sec" >> "$SUMMARY"

############ S7 unreadable mtime -> stale, never fresh (stat refuses only this file)
r=$(mk_home unreadable); note "$r"
fb="$LAB/unreadable-fakebin"; mkdir -p "$fb"
cat > "$fb/stat" <<'SH'
#!/bin/bash
for a in "$@"; do case "$a" in */data/handoff/latest.md) exit 1 ;; esac; done
exec /usr/bin/stat "$@"
SH
chmod +x "$fb/stat"
out=$(env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$r" FM_HOME="$r" \
  PATH="$fb:$BASE_PATH" "$RUN" --source startup </dev/null 2>&1)
save s7-unreadable-mtime.txt "S7 note whose mtime cannot be read (stat fails for that path only)" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S7 "unreadable-age line" has "$sec" "Handoff note present but its age could not be read (data/handoff/latest.md), so it is not printed"
check S7 "body never leaked" hasnt "$out" "$MARK"
check S7 "exactly one non-blank line" test "$(printf '%s\n' "$sec" | grep -c .)" -eq 1
printf 'S7 handoff section verbatim:\n%s\n' "$sec" >> "$SUMMARY"

############ S8 print bound: default 200 on a 260-line note, override 20, invalid override
r=$(mk_home bound); note "$r" 255
total=$(awk 'END{print NR}' "$r/data/handoff/latest.md")
out=$(hook "$r" startup)
save s8a-bound-default.txt "S8a ${total}-line note, default 200-line print bound" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S8 "default bound shows head of note" has "$sec" "$MARK"
check S8 "default bound stops at line 200" has "$sec" "- filler line 194"
check S8 "default bound omits line 201+" hasnt "$sec" "- filler line 196"
check S8 "default bound discloses exact remainder" has "$sec" "... $((total - 200)) more line(s) omitted by the 200-line bound: read data/handoff/latest.md for the rest."
check S8 "supervision block still emitted after bounded note" has "$out" "SUPERVISION OPERATING INSTRUCTIONS"
check S8 "fleet state still emitted after bounded note" has "$out" "FLEET STATE"
out=$(hook "$r" startup FM_SESSION_START_HANDOFF_LINES=20)
save s8b-bound-override.txt "S8b ${total}-line note, FM_SESSION_START_HANDOFF_LINES=20" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S8 "override 20 discloses exact remainder" has "$sec" "... $((total - 20)) more line(s) omitted by the 20-line bound"
check S8 "override 20 prints line 20 (filler 15)" has "$sec" "- filler line 15"
check S8 "override 20 omits line 21 (filler 16)" hasnt "$sec" "- filler line 16"
out=$(hook "$r" startup FM_SESSION_START_HANDOFF_LINES=nope)
check S8 "invalid lines override falls back to 200" has "$out" "omitted by the 200-line bound"
r2=$(mk_home bound-small); note "$r2" 100
out=$(hook "$r2" startup)
check S8 "note under the bound printed whole (last line)" has "$out" "- data/backlog.md"
check S8 "note under the bound claims no remainder" hasnt "$out" "more line(s) omitted by"

############ S9 note without a trailing newline does not glue onto the next output
r=$(mk_home unterminated); mkdir -p "$r/data/handoff"
printf '# Handoff\n- %s-UNTERMINATED' "$MARK" > "$r/data/handoff/latest.md"
out=$(hook "$r" startup)
save s9-unterminated.txt "S9 note whose last byte is not a newline" "$out"
check S9 "last note line stands alone" sh -c 'printf "%s\n" "$1" | grep -qx -- "- $2-UNTERMINATED"' _ "$out" "$MARK"
check S9 "next section rule starts its own line" sh -c 'printf "%s\n" "$1" | grep -A3 -- "- $2-UNTERMINATED" | grep -qx "=\{80\}"' _ "$out" "$MARK"

############ S10 read-only session (lock held by another live session) still gets the note
r=$(mk_home readonly); note "$r"
# first a startup takes the lock under this harness ...
hook "$r" startup >/dev/null
# ... then a different live "harness" owns it: a plain long-lived process recorded as holder
fb="$LAB/readonly-fakebin"; mkdir -p "$fb"
cat > "$fb/ps" <<'SH'
#!/bin/bash
# report every pid as a live claude harness so the recorded holder counts as live
case "$*" in
  *comm=*) echo /usr/local/bin/claude; exit 0 ;;
  *args=*) echo claude; exit 0 ;;
esac
exec /bin/ps "$@"
SH
chmod +x "$fb/ps"
sleep 300 & holder=$!
printf '%s\n' "$holder" > "$r/state/.lock"
out=$(env -u NO_MISTAKES_GATE -u CLAUDECODE FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$r" FM_HOME="$r" \
  PATH="$fb:$BASE_PATH" "$SS" 2>&1)
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
save s10-read-only.txt "S10 lock held by another live session (read-only path)" "$out"
sec=$(printf '%s\n' "$out" | section_of)
check S10 "session is read-only" has "$out" "READ-ONLY SESSION"
check S10 "wake queue skipped" has "$out" "skipped (read-only session)"
check S10 "handoff section present" has "$out" "HANDOFF NOTE FROM THE PREVIOUS SESSION"
check S10 "handoff body printed on read-only path" has "$sec" "$MARK"

############ S11 truncation banner names the handoff stage when the digest stops before it
r=$(mk_home truncate); note "$r"
fb="$LAB/truncate-fakebin"; mkdir -p "$fb"
# a hanging git makes bootstrap overrun a 3s budget, so handoff and later stages never run
cat > "$fb/git" <<'SH'
#!/bin/bash
sleep 20
SH
chmod +x "$fb/git"
out=$(env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_SESSION_START_TIMEOUT=3 FM_STARTUP_NETWORK_TIMEOUT=2 \
  FM_ROOT_OVERRIDE="$r" FM_HOME="$r" PATH="$fb:$BASE_PATH" "$SS" 2>&1)
save s11-truncated.txt "S11 digest truncated by the runtime bound before the handoff stage" "$out"
check S11 "truncation banner printed" has "$out" "STARTUP TRUNCATED"
check S11 "truncation banner lists handoff among never-run stages" has "$out" "handoff supervision-instructions read-once"

printf '\nTOTAL FAILS: %s\n' "$FAILS" >> "$SUMMARY"
cat "$SUMMARY"

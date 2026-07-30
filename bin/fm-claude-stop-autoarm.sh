#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     A recorded owner that is dead, not a session shape, or - by the shared
#     session-id contract in bin/fm-session-lock-lib.sh - the SAME logical
#     session in a replaced process (a fork/relaunch successor) is recovered
#     through bin/fm-lock.sh, then ownership is re-verified. A live owner from
#     another session never lets this hook arm, rewake for a watcher close, or
#     touch the lock; but when supervision is needed and away mode is off, that
#     foreign-owner state wakes the model ONCE per distinct holder (exit 2,
#     deduped via state/.claude-autoarm-foreign-lock) with the real diagnosis,
#     because silent inertness is exactly how a fork handover went unnoticed:
#     the working session's hooks land here while the superseded pre-fork
#     process keeps the lock alive. Missing or malformed locks and unresolved
#     ancestry stay inert.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) or a typed
#     watcher: FAILED prints one rewake banner to stderr and exits 2, which
#     wakes Claude even while idle ("Stop hook feedback"). A clean close with
#     no actionable reason and no remaining need exits 0 silently.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Consume the Stop payload once. The gates below are state-based; the only
# field read is the harness-planted session_id, exported as the trusted
# identity hint for the shared session-lock lib (which re-validates its shape).
# Any parse doubt degrades to no hint, never to a wedge or a wrong identity.
PAYLOAD=$(cat 2>/dev/null || true)
FM_CLAUDE_SESSION_ID_HINT=$(printf '%s' "$PAYLOAD" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p' \
  | head -n 1)
export FM_CLAUDE_SESSION_ID_HINT

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# Classify a non-owned numeric lock through the shared relation predicate:
# a stale owner or a same-session successor (fork/relaunch, proven by the
# recorded session id) is recoverable through fm-lock.sh; a live owner from
# another session is never touched but may deserve one loud notice below.
# Defer every mutating step until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
FOREIGN_LIVE_LOCK=0
FOREIGN_HOLDER_SID=''
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  MY_PID=$(fm_harness_ancestry_pid) || exit 0
  case "$(fm_session_lock_relation "$STATE" "$LOCK_PID" "$MY_PID")" in
    stale|same-session) RECOVER_SESSION_LOCK=1 ;;
    live-other)
      FOREIGN_LIVE_LOCK=1
      FOREIGN_HOLDER_SID=$(fm_session_lock_holder_session_id "$STATE") || FOREIGN_HOLDER_SID=''
      ;;
    *) exit 0 ;;
  esac
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale or same-session lock recovery ---------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal, same-session
# re-key, and write semantics remain the single acquisition owner, then
# re-verify current-session identity before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner foregrounds the arm and translates its close; every other firing exits
# 0 so one watcher cycle maps to at most one exit-2 rewake.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# --- foreign live owner: one loud notice, never an arm or a reclaim -----------
# The competing-session boundary holds: no arm, no rewake-for-a-close, no lock
# mutation. But a silent exit here is how a fork handover went unnoticed for
# hours, so with supervision needed and away mode off, tell the model once per
# distinct holder that supervision is not running from this session and how
# ownership recovers. The single-flight owner lock above serializes the marker.
if [ "$FOREIGN_LIVE_LOCK" -eq 1 ]; then
  FOREIGN_MARK="$STATE/.claude-autoarm-foreign-lock"
  FOREIGN_KEY="$LOCK_PID ${FOREIGN_HOLDER_SID:-unknown}"
  [ "$(cat "$FOREIGN_MARK" 2>/dev/null)" = "$FOREIGN_KEY" ] && exit 0
  printf '%s\n' "$FOREIGN_KEY" > "$FOREIGN_MARK" 2>/dev/null || true
  write_epoch rewake
  {
    printf 'firstmate supervision is NOT running from this session: the home lock is held by another live session (pid %s%s).\n' \
      "$LOCK_PID" "${FOREIGN_HOLDER_SID:+, session $FOREIGN_HOLDER_SID}"
    printf 'If this session is the working session (e.g. Claude Code forked or relaunched it from the recorded one), the recorded process is superseded: run bin/fm-session-start.sh for the exact diagnostic, report the blocker to the captain, and stay read-only until the recorded process exits - ownership and supervision then recover automatically.\n'
  } >&2
  exit 2
fi

write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
if [ -n "$OUT" ]; then
  "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1
  RC=$?
else
  "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1
  RC=$?
fi

# --- classify and translate ---------------------------------------------------
# AFK may have appeared mid-cycle: the daemon owns triage now, so suppress the
# rewake even for an actionable close.
if [ -e "$STATE/.afk" ]; then
  write_epoch afk
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

ACTIONABLE=0
FAILED=0
if [ -n "$OUT" ]; then
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  grep -q '^watcher: FAILED' "$OUT" 2>/dev/null && FAILED=1
fi
[ "$RC" -ne 0 ] && FAILED=1

if [ "$ACTIONABLE" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

write_epoch rewake
if [ "$FAILED" -eq 1 ]; then
  {
    printf 'firstmate watcher cycle FAILED - supervision is down while this home still needs it.\n'
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first. Then repair supervision with bin/fm-watch-arm.sh as its own Claude Code background task (never shell &). If the failure repeats, treat it as a blocker and report it instead of ending blind.\n'
  } >&2
else
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first and handle the wake. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2

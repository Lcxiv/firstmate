#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# When the current session's harness session id resolves from a trusted source
# (bin/fm-session-lock-lib.sh owns that contract), it is recorded in the
# state/.lock-session sidecar so a successor that KEPT its session id can
# re-key the pid. A live holder from a different session still refuses, now
# naming the holder and any fork lineage it can see - Claude Code's
# --fork-session mints a NEW session id, so a fork successor takes this
# refusal while the pre-fork process lives and reclaims through the ordinary
# stale path the moment it exits.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

SIDECAR="$STATE/.lock-session"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  sid_note=''
  if sid=$(fm_session_lock_holder_session_id "$STATE"); then sid_note=" (session $sid)"; fi
  if fm_harness_pid_alive "$old"; then echo "lock: held by live harness pid $old$sid_note"; else echo "lock: stale (pid $old dead or not a harness)$sid_note"; fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
MY_SID=$(fm_session_lock_my_session_id "$me") || MY_SID=''
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CLAIM_LOCK"
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    # A live holder from the SAME logical session (a fork/relaunch successor
    # proving the recorded session id as its own) may re-key the pid below;
    # every other live holder refuses, with enough detail for the captain to
    # act: which process, since when, on which terminal, and - when this
    # process's own launch flags show it was forked/resumed from the recorded
    # session - the one action that hands the home over safely.
    relation=$(fm_session_lock_relation "$STATE" "$old" "$me")
    if [ "$relation" != same-session ]; then
      holder_sid=$(fm_session_lock_holder_session_id "$STATE") || holder_sid=''
      echo "error: another live firstmate session holds the lock (pid $old${holder_sid:+, session $holder_sid}); operate read-only until resolved" >&2
      holder_start=$(ps -o lstart= -p "$old" 2>/dev/null | sed 's/^ *//;s/ *$//') || holder_start=''
      holder_tty=$(ps -o tty= -p "$old" 2>/dev/null | tr -d ' ') || holder_tty=''
      [ -n "$holder_start" ] && echo "lock holder: pid $old, started $holder_start${holder_tty:+, terminal $holder_tty}" >&2
      if [ -n "$holder_sid" ]; then
        my_args=$(ps -o args= -p "$me" 2>/dev/null) || my_args=''
        case "$my_args" in
          *--fork-session*"$holder_sid"*|*"$holder_sid"*--fork-session*)
            echo "note: this session was forked from the lock-holding session $holder_sid; if that process is no longer the captain's working session, exit it (or close its terminal) - the lock is reclaimed automatically once it is gone" >&2
            ;;
        esac
      fi
      exit 1
    fi
  fi
fi
# Clear the previous owner's session identity BEFORE publishing ours: a stale
# sidecar left beside a new pid would attribute another session's id to this
# owner and let a third process with that id claim same-session succession.
rm -f "$SIDECAR" 2>/dev/null || true
if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
  echo "error: cannot clear the previous owner's session identity; operate read-only until resolved" >&2
  exit 1
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
if [ -n "$MY_SID" ]; then
  # A failed identity write degrades to today's pid-only lock rather than
  # refusing, but never leaves partial bytes that could match something.
  if ! { printf '%s\n' "$MY_SID" > "$SIDECAR"; } 2>/dev/null \
    || [ "$(cat "$SIDECAR" 2>/dev/null)" != "$MY_SID" ]; then
    rm -f "$SIDECAR" 2>/dev/null || true
    if [ -e "$SIDECAR" ]; then
      echo "error: cannot record session identity coherently; operate read-only until resolved" >&2
      exit 1
    fi
    MY_SID=''
  fi
fi
release_claim_lock
echo "lock acquired: harness pid $me${MY_SID:+ (session $MY_SID)}"

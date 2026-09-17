#!/usr/bin/env bash
# PreToolUse notice for a supervision handoff that is never coming.
#
# Why this hook exists, and why it is NOT a Stop hook: watcher continuity for a
# Claude primary is triggered only by a turn end
# (bin/fm-claude-stop-autoarm.sh), and so is the turn-end guard that would
# otherwise catch it. Claude Code does not run Stop hooks for a turn that is cut
# short rather than completed - a usage-limit park and an expired login are both
# observed cases - and such a session then stops producing turn ends at all. The
# watcher's last cycle closes normally, nothing arms the next one, and every
# mechanism that could notice is downstream of the turn end that will not
# happen. The failure seals itself: waiting for it to recover cannot work by
# construction, because its only trigger is the thing that stopped.
#
# A tool call is the one signal that survives that seal. The moment the session
# is able to do anything at all - the first tool call after a usage limit
# resets, or any call in a turn that has been running blind - this hook runs and
# says so, without depending on a turn ever ending.
#
# Boundaries, all deliberate:
#   - It NEVER denies a tool call and never blocks work. Every path exits 0.
#     Watcher status has never been grounds for denying a fleet command
#     (docs/watcher-continuity.md), and this hook does not change that.
#   - It NEVER arms a watcher. The arm belongs in the Stop hook's own process
#     tree, where the harness owns the process group and tears arm and watcher
#     down together; arming from a transient per-tool-call hook would orphan the
#     watcher it started. The model repairs supervision through its documented
#     protocol, which this notice points at.
#   - It speaks at most once per handoff episode, so a session that is working
#     through the repair is not nagged on every subsequent call.
#   - bin/fm-supervision-lib.sh owns the overdue predicate and the activity
#     record; this wrapper only acquires the payload, renders the notice, and
#     keeps the activity record current.
#
# Exit/output contract:
#   exit 0 and no output  - nothing to say, or any uncertainty at all.
#   exit 0 with a {"systemMessage": ...} object on stdout - the notice, the same
#   informational shape bin/fm-turnend-guard.sh uses for its attended fail-open.
set -u

CLAUDE_MODE=0
CURSOR_MODE=0
for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    --cursor) CURSOR_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude|--cursor]" >&2; exit 2 ;;
  esac
done
# Accepted for transport parity with the other tracked hook entries; the notice
# renders identically for every harness that reads a systemMessage object.
: "$CLAUDE_MODE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" || exit 0
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
MARKER="$STATE/.supervision-handoff-notified"

# Consume the payload once so a writer can never wedge on a full pipe.
PAYLOAD=$(cat 2>/dev/null || true)

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh" 2>/dev/null || exit 0

[ -d "$STATE" ] || exit 0

# The predicate reads the activity record, so it must run BEFORE this call
# refreshes it: the whole point is how long the session had gone without taking
# a step when it took this one.
fm_supervision_handoff_status "$STATE" "$GRACE"
OVERDUE=$FM_SUP_HANDOFF_OVERDUE
HANDOFF_AGE=$FM_SUP_HANDOFF_AGE
# The status helper returns early - without computing the need counts - as soon
# as there is no handoff to be overdue, so default them rather than tripping
# set -u on a path that is about to exit silently anyway.
IN_FLIGHT=${FM_SUP_IN_FLIGHT:-0}
SOURCES=${FM_SUP_SOURCES:-0}
fm_supervision_activity_touch "$STATE"

[ "$OVERDUE" = true ] || exit 0

# While away mode is on, the away daemon owns supervision and its own triage;
# never speak over it.
[ -e "$STATE/.afk" ] && exit 0

# A Cursor primary loads the tracked Claude settings too, and Cursor's own
# registration owns its hooks; without --cursor this payload is that duplicate.
# Checked here rather than on the hot path so an ordinary healthy tool call
# never pays for jq.
if [ "$CURSOR_MODE" -eq 0 ] && command -v jq >/dev/null 2>&1; then
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh" 2>/dev/null || true
  if command -v fm_hook_payload_is_foreign_host >/dev/null 2>&1 \
    && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
fi

# Only a genuine primary home has supervision to lose; a crew or scout worktree
# stays silent. Checked last because it is the most expensive step and only the
# speaking path needs it.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# One notice per handoff episode. The episode is the ledger entry that was never
# picked up, so a later handoff (a turn that did end, and did arm) mints a new
# one; an unchanged entry stays quiet until the re-nag window so a session that
# parks again is told again.
LEDGER_STAMP=$(fm_sup_stat_mtime "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
[ -n "$LEDGER_STAMP" ] || exit 0
NOW=$(date +%s)
RENAG=${FM_SUPERVISION_HANDOFF_RENAG:-$FM_SUP_HANDOFF_WINDOW}
case "$RENAG" in ''|*[!0-9]*|0) RENAG=$FM_SUP_HANDOFF_WINDOW ;; esac
if [ -f "$MARKER" ]; then
  OLD_LEDGER=$(sed -n '1s/^ledger=//p' "$MARKER" 2>/dev/null || true)
  OLD_AT=$(sed -n '2s/^at=//p' "$MARKER" 2>/dev/null || true)
  case "$OLD_AT" in ''|*[!0-9]*) OLD_AT=0 ;; esac
  if [ "$OLD_LEDGER" = "$LEDGER_STAMP" ] && [ $(( NOW - OLD_AT )) -lt "$RENAG" ]; then
    exit 0
  fi
fi
TMP="$MARKER.tmp.$$"
if ! printf 'ledger=%s\nat=%s\n' "$LEDGER_STAMP" "$NOW" > "$TMP" 2>/dev/null \
  || ! mv -f "$TMP" "$MARKER" 2>/dev/null; then
  # Unable to record the notice: stay silent rather than repeat it on every
  # single tool call for the rest of the session.
  rm -f "$TMP" 2>/dev/null || true
  exit 0
fi

if [ "$IN_FLIGHT" -gt 0 ]; then
  NEED_DESC="$IN_FLIGHT task(s) in flight"
elif [ "$SOURCES" -gt 0 ]; then
  NEED_DESC="$SOURCES process-event source(s) registered"
else
  NEED_DESC="remote command polling active"
fi
FOR_HOW_LONG=$(fm_supervision_duration "$HANDOFF_AGE")

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}
MSG=$(printf 'FIRSTMATE SUPERVISION IS OFF AND NOTHING IS SCHEDULED TO RESTART IT: %s, and no watcher cycle has been armed for %s. The automatic re-arm runs only when a turn ends, and this session went that whole stretch without ending one - a turn cut short by a usage limit, an expired login, or a similar abort does not run the Stop hooks that own it - so it cannot recover on its own no matter how long you wait. Repair supervision now, per the operating block this session start emitted, before continuing other work.' \
  "$NEED_DESC" "$FOR_HOW_LONG")
printf '{"systemMessage":"%s"}\n' "$(json_escape "$MSG")"
exit 0

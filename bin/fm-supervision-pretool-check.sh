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
#     protocol, which this notice names via bin/fm-supervision-instructions.sh.
#   - It speaks on TWO channels at once, because its reader is usually
#     unattended: hookSpecificOutput.additionalContext is the field Claude Code
#     adds to the model's context, so the model can act on the diagnosis by
#     itself; systemMessage is shown to an attending operator only, and is kept
#     so a human at the keyboard still sees it. Neither is a permission
#     decision.
#   - It speaks once per park, so a session that is working through the repair
#     is not nagged on every subsequent call. The activity record delivers that
#     by itself: the call that speaks also refreshes it, so the predicate cannot
#     hold again until the session has gone a whole window without a step - and
#     a session that parks again must be told again.
#   - The activity record is refreshed when a tool call RETURNS as well as when
#     it starts (--post, registered on PostToolUse). Sampling only call starts
#     would measure the gap between them, so one long-running call or an
#     unanswered permission prompt inside a live turn would read as a parked
#     session. The post path refreshes the record and does nothing else: it
#     never reads the predicate, never speaks, never arms, never denies.
#   - bin/fm-supervision-lib.sh owns the overdue predicate and the activity
#     record; this wrapper only acquires the payload, renders the notice, and
#     keeps the activity record current.
#
# Exit/output contract:
#   exit 0 and no output  - nothing to say, an unknown argument, an internal
#   failure, or any uncertainty at all.
#   exit 0 with one JSON object on stdout carrying both
#   hookSpecificOutput.additionalContext (model-visible) and systemMessage
#   (operator-visible) - the notice. This is deliberately NOT the bare
#   systemMessage shape bin/fm-turnend-guard.sh uses for its attended fail-open:
#   that precedent assumes a human is watching, and this hook cannot.
set -u

# A non-zero PreToolUse status can deny the call, and under the catch-all
# matcher that would lock the home out of the very calls needed to repair it.
# Force a zero status for every way this script can end, including an unbound
# variable under set -u or a sourced library that exits non-zero.
trap 'exit 0' EXIT

# --claude is accepted for transport parity with the other tracked hook entries
# and changes nothing. --post selects the PostToolUse path. Anything else is a
# misregistration: say so on stderr and stand down without speaking.
POST=0
for arg in "$@"; do
  case "$arg" in
    --claude) ;;
    --post) POST=1 ;;
    *) echo "usage: $(basename "$0") [--claude] [--post]" >&2; exit 0 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" || exit 0
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}

# Consume the payload once so a writer can never wedge on a full pipe.
PAYLOAD=$(cat 2>/dev/null || true)

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh" 2>/dev/null || exit 0

[ -d "$STATE" ] || exit 0

if [ "$POST" -eq 1 ]; then
  fm_supervision_activity_touch "$STATE"
  exit 0
fi

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

# A Cursor primary loads the tracked Claude settings too, but the ledger this
# notice reads belongs to the Claude auto-arm alone, so a Cursor payload always
# stands down. Checked here rather than on the hot path so an ordinary healthy
# tool call never pays for jq.
if command -v jq >/dev/null 2>&1; then
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
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
phone_mode=0
[ -f "$CONFIG/phone-mode.env" ] && phone_mode=1
REPAIR=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk 0 --x-mode "$x_mode" --phone-mode "$phone_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'Repair supervision now, per the operating block this session start emitted.')
REPAIR=${REPAIR%$'\n'}
MSG=$(printf 'FIRSTMATE SUPERVISION IS OFF AND NOTHING IS SCHEDULED TO RESTART IT: %s, and no watcher cycle has been armed for %s. The automatic re-arm runs only when a turn ends, and this session went that whole stretch without ending one - a turn cut short by a usage limit, an expired login, or a similar abort does not run the Stop hooks that own it - so it cannot recover on its own no matter how long you wait. Repair supervision before continuing other work: %s' \
  "$NEED_DESC" "$FOR_HOW_LONG" "$REPAIR")
ESCAPED=$(json_escape "$MSG")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"},"systemMessage":"%s"}\n' "$ESCAPED" "$ESCAPED"
exit 0

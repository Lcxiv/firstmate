# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists), an X-mode relay poll
# (state/x-watch.check.sh), or a Discord phone poll
# (state/phone-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, a remote command poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ -f "$state/phone-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# --- auto-arm handoff health -------------------------------------------------
# The Claude Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) is triggered
# ONLY by a turn end, and Claude Code does not run Stop hooks for a turn that is
# cut short rather than completed (observed: a usage-limit park on 2026-09-17
# and an expired login on 2026-09-03, both of which recorded a turn_duration
# with no stop_hook_summary). Such a session also stops producing turn ends, so
# the handoff the auto-arm expects never happens, nothing re-arms, and the only
# mechanism that could notice is the same one that is not running. The auto-arm
# never refuses to claim in this state - it is never invoked, which is why its
# ledger freezes on a TERMINAL outcome instead of advancing to a refused one.
#
# The beacon alone cannot tell that apart from the benign case, because under
# the auto-arm model no watcher runs while the model is handling a turn, so a
# stale beacon is the normal mid-turn shape. Three ages together do separate
# them:
#   - the auto-arm ledger's age is how long ago a handoff was expected,
#   - the beacon's age is whether a cycle is running right now,
#   - the activity file's age is whether this session is taking turns at all.
# A session parked mid-abort has all three stale; a session working through a
# long turn has fresh activity; a session between turns has a fresh ledger.
#
# state/.session-activity is touched by the tracked hooks that run while a
# primary session is actually taking turns. It is advisory: an absent or
# unwritable file only ever ages toward the overdue verdict the operator
# already needs to see, and never suppresses one.

FM_SUPERVISION_ACTIVITY_FILE=.session-activity

# fm_supervision_activity_touch <state-dir>
# Best-effort record that this session just took a guarded step. Never fails a
# caller: a read-only or missing state dir simply records nothing.
fm_supervision_activity_touch() {
  local state=$1
  [ -d "$state" ] || return 0
  : > "$state/$FM_SUPERVISION_ACTIVITY_FILE" 2>/dev/null || true
  return 0
}

# fm_supervision_handoff_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_HANDOFF_AGE       seconds since the auto-arm ledger last changed
#   FM_SUP_ACTIVITY_AGE      seconds since this session last took a guarded step
#   FM_SUP_HANDOFF_WINDOW    the window an age must exceed to count as stale
#   FM_SUP_HANDOFF_STALE     true/false - nothing has armed a cycle for that long
#   FM_SUP_HANDOFF_OVERDUE   true/false - and nothing is going to, either
# Ages report 999999 for an absent or unreadable path, which is the honest
# reading: no evidence of a handoff or of activity is not evidence of either.
# The window defaults to twice the guard grace so an ordinary wake-handling turn
# never trips it; FM_SUPERVISION_HANDOFF_WINDOW overrides it.
# The two verdicts answer different questions and have different right users.
# FM_SUP_HANDOFF_STALE is about DURATION alone: nothing has armed a cycle for
# longer than an ordinary gap between cycles. It is what a banner should report,
# because at a turn boundary the session is obviously alive and the only honest
# question left is how long the home has been running without one.
# FM_SUP_HANDOFF_OVERDUE adds the activity gate on top: the session was not even
# taking turns across that stretch, so no turn end is coming to clear it. That is
# the unrecoverable state, and it is the only one worth interrupting work over.
# Always returns 0; callers read the vars.
fm_supervision_handoff_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} window ledger m outcome owner
  case "$grace" in
    ''|*[!0-9]*|0) grace=300 ;;
  esac
  window=${FM_SUPERVISION_HANDOFF_WINDOW:-$(( grace * 2 ))}
  case "$window" in
    ''|*[!0-9]*|0) window=$(( grace * 2 )) ;;
  esac
  # shellcheck disable=SC2034 # Read by callers (the pre-tool notice) after sourcing.
  FM_SUP_HANDOFF_WINDOW=$window
  FM_SUP_HANDOFF_AGE=999999
  FM_SUP_ACTIVITY_AGE=999999
  # shellcheck disable=SC2034 # Read by callers (both watcher-down banners) after sourcing.
  FM_SUP_HANDOFF_STALE=false
  # shellcheck disable=SC2034 # Read by callers (both watcher-down banners and the pre-tool notice) after sourcing.
  FM_SUP_HANDOFF_OVERDUE=false

  # A running cycle answers the whole question and is by far the common case, so
  # settle it before touching anything else: this runs on every tool call.
  m=$(fm_sup_stat_mtime "$state/.last-watcher-beat")
  if [ -n "$m" ] && [ $(( $(date +%s) - m )) -lt "$grace" ]; then
    return 0
  fi

  ledger="$state/.claude-autoarm-epoch"
  [ -f "$ledger" ] || return 0
  m=$(fm_sup_stat_mtime "$ledger")
  # No ledger at all means this home has never run the Claude auto-arm, so there
  # is no handoff to be overdue. Continuity for the other harnesses is owned by
  # their own adapters and reported through the beacon, not through this file.
  [ -n "$m" ] || return 0
  FM_SUP_HANDOFF_AGE=$(( $(date +%s) - m ))
  m=$(fm_sup_stat_mtime "$state/$FM_SUPERVISION_ACTIVITY_FILE")
  [ -n "$m" ] && FM_SUP_ACTIVITY_AGE=$(( $(date +%s) - m ))

  # A live "arming" claim is a handoff in progress and belongs to the auto-arm's
  # own generation contract, not here. A claim whose owner is gone is as
  # abandoned as a terminal one.
  outcome=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$ledger" 2>/dev/null || true)
  [ -n "$outcome" ] || return 0
  if [ "$outcome" = arming ]; then
    owner=$(sed -n '1s/^.*owner_pid=\([0-9][0-9]*\) .*$/\1/p' "$ledger" 2>/dev/null || true)
    [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && return 0
  fi

  fm_supervision_status "$state" "$grace"
  [ "$FM_SUP_NEEDED" = true ] || return 0
  # Re-read rather than trust the cheap pre-check: fm_supervision_status is the
  # owner of the freshness verdict, and a cycle may have started meanwhile.
  [ "$FM_SUP_WATCHER_FRESH" = false ] || return 0
  [ "$FM_SUP_HANDOFF_AGE" -ge "$window" ] || return 0
  # shellcheck disable=SC2034 # Read by callers after this function returns.
  FM_SUP_HANDOFF_STALE=true
  [ "$FM_SUP_ACTIVITY_AGE" -ge "$window" ] || return 0
  # shellcheck disable=SC2034 # Read by callers after this function returns.
  FM_SUP_HANDOFF_OVERDUE=true
  return 0
}

# fm_supervision_duration <seconds>
# Render an age for an operator banner: "3h38m", "12m", "45s".
fm_supervision_duration() {
  local s=$1
  case "$s" in
    ''|*[!0-9]*) printf 'unknown\n'; return 0 ;;
  esac
  if [ "$s" -ge 3600 ]; then
    printf '%sh%sm\n' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
  elif [ "$s" -ge 60 ]; then
    printf '%sm\n' "$(( s / 60 ))"
  else
    printf '%ss\n' "$s"
  fi
}

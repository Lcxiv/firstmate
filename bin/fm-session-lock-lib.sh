#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# Identity has two layers, because a harness can replace a session's PROCESS
# while the LOGICAL session continues (observed live on Claude Code 2.1.220:
# a mid-conversation fork/relaunch leaves the pre-fork pid alive as an idle
# interactive process while a new pid carries the working conversation):
#   state/.lock          the owning harness process pid (the incarnation).
#   state/.lock-session  optional sidecar: the owning harness SESSION id (the
#                        logical session). Written and cleared only by
#                        bin/fm-lock.sh under its acquisition mutex.
# A lock whose recorded session id equals the current session's id names the
# SAME logical session in a new process, so bin/fm-lock.sh may re-key the pid;
# a live holder with a different or unresolvable session id is a competing
# session and is never reclaimed, inherited, or forced.
#
# The current session's id resolves only from sources the harness itself
# plants, in trust order:
#   1. FM_CLAUDE_SESSION_ID_HINT - set exclusively by our own hook scripts from
#      the harness-provided hook payload (Claude writes session_id into every
#      Stop payload), never from ps-visible text.
#   2. CLAUDE_CODE_SESSION_ID from the environment, accepted only when
#      CLAUDE_PID names exactly the pid the ancestry walk resolved: Claude Code
#      exports both into every tool shell it spawns, so the pair proves the
#      environment was planted by the resolved session itself and not inherited
#      from the shared daemon or an unrelated outer session.
# Command-line text (ps args) is NEVER an identity source for the current
# session: prompts and briefs are argv-visible and can quote a session id.
# Non-Claude harnesses have no verified session-id source, so their locks stay
# pid-only and every behavior below degrades to the pid-only contract.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Claude Code process shapes that are NOT a session, matched in argv subcommand
# position or in a worker's own process title.
# Extend when a new non-session Claude worker role is verified.
FM_CLAUDE_NONSESSION_SUBCMD='daemon|bg-spare|bg-pty-host|--bg-spare|--bg-pty-host'

# Echo the argv tokens that follow argv[0] of args ($2), dropping $3 further
# tokens (1 for an interpreter host, whose argv[1] is the harness script path
# and whose subcommand is therefore one token further along).
# argv[0] is located by ANCHORING ON THE EXECUTABLE comm ($1), never by
# splitting on the first whitespace: an executable path containing a space
# ("/Applications/Claude Code.app/.../claude") must still yield its real
# subcommand. comm and argv[0] can disagree - ps reports a full path for one and
# a bare name for the other, and Linux truncates comm - so a leading comm is
# tried first, then the first argv token whose basename is comm's basename.
# Returns 1 when argv[0] cannot be located at all.
fm_claude_argv_tail() {
  local comm=$1 args=$2 skip=$3 bc rest tok found=0
  case "$args" in
    "$comm") rest='' ;;
    "$comm "*) rest=${args:$((${#comm} + 1))} ;;
    *)
      bc=${comm##*/}
      rest=$args
      while [ -n "$rest" ]; do
        tok=${rest%% *}
        case "$rest" in
          *' '*) rest=${rest#* } ;;
          *) rest='' ;;
        esac
        if [ "${tok##*/}" = "$bc" ]; then
          found=1
          break
        fi
      done
      [ "$found" -eq 1 ] || return 1
      ;;
  esac
  while [ "$skip" -gt 0 ]; do
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) rest='' ;;
    esac
    skip=$((skip - 1))
  done
  printf '%s' "$rest"
}

# True when a claude-named process belongs to Claude Code's shared background
# daemon infrastructure rather than to one interactive or headless session.
#
# Three roles are rejected, all verified live on Claude Code 2.1.220:
#   claude daemon ...        the background daemon. Parented to init, shared by
#                            every session of the user, and outlives all of
#                            them. Its argv carries an --origin value that
#                            varies by how it was started (transient, service,
#                            and an unrecognized-origin case are all handled in
#                            the binary), so the daemon is identified by its
#                            "daemon" SUBCOMMAND, never by one origin value.
#   claude bg-pty-host ...   a pty host owned by the daemon.
#   claude bg-spare ...      a pre-forked pooled worker owned by the daemon.
# The daemon hands a pooled spare to whichever session next needs a background
# process, so a spare's ancestry AND its inherited environment both describe
# the daemon, not the session that claimed it (a spare-hosted shell was
# observed sourcing the daemon's own startup shell snapshot, not the claiming
# session's). Neither is per-session, so neither can ever identify a session:
# treating one as the lock owner lets two different sessions resolve the same
# identity and claim one home's lock, and records a lock pid that no later
# session can ever see go stale.
# The subcommand test reads ONE argv token in subcommand position, never the
# whole command line, so a session whose PROMPT mentions one of these words stays
# a session.
# $3 is the interpreter offset: 0 when comm is the harness executable itself, 1
# when comm is an interpreter hosting the harness script (see
# fm_harness_session_match, which is the branch that knows).
fm_claude_nonsession() {
  local comm=$1 args=$2 skip=${3:-0} rest token title=0
  # A pooled worker sets its own process title, so comm alone can carry the role.
  case "$comm" in
    *bg-spare*|*bg-pty-host*) return 0 ;;
  esac
  # A process that rewrote its own process title carries its role inside comm, so
  # comm's own subcommand position is what to test there. A comm with no path
  # separator but with further tokens is such a title; a comm containing "/" is
  # an executable path whose spaces belong to the path.
  case "$comm" in
    */*) ;;
    *' '*) title=1 ;;
  esac
  if [ "$title" -eq 1 ]; then
    rest=${comm#* }
  else
    # Unlocatable argv[0] means the subcommand position is unknown. Fail CLOSED
    # (report infrastructure), so an unreadable command line can never let the
    # shared daemon be accepted as a session identity.
    rest=$(fm_claude_argv_tail "$comm" "$args" "$skip") || return 0
  fi
  token=${rest%% *}
  printf '%s' "$token" | grep -qE "^($FM_CLAUDE_NONSESSION_SUBCMD)$"
}

# True when ps fields comm ($1) and args ($2) describe a verified harness
# SESSION process. Sets FM_HARNESS_MATCH_CLAUDE=1 when that session is
# Claude-shaped, which is the only harness whose ancestry nests (see
# fm_harness_ancestry_pid). ONE owner of the "is this process a session of a
# verified harness?" test, so the ancestry walk and the holder-liveness check
# can never disagree about the same pid.
fm_harness_session_match() {
  local comm=$1 args=$2 bc hit=0 is_claude=0 argv_skip=0
  FM_HARNESS_MATCH_CLAUDE=0
  bc=$(basename -- "$comm")
  if printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
    hit=1
    case "$bc" in *claude*) is_claude=1 ;; esac
  else
    case "$comm" in
      # Claude Code's versioned executable: comm is the version, not a name, so
      # a session launched through it (resumed and forked sessions, and sessions
      # hosted by the desktop app) matches on neither name nor interpreter.
      # Both signals are required - a "claude" PATH COMPONENT and a
      # version-shaped basename - so an unrelated program that merely lives in
      # a directory named claude is not mistaken for the harness.
      */claude/*) case "$bc" in [0-9]*) hit=1; is_claude=1 ;; esac ;;
    esac
    if [ "$hit" -eq 0 ]; then
      # Bare interpreter (e.g. node): match the harness name in its script path.
      # argv[0] is the interpreter and argv[1] the harness script, so the
      # subcommand sits one token further along than for a direct install; that
      # offset is passed to fm_claude_nonsession rather than re-derived there.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            argv_skip=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
  fi
  [ "$hit" -eq 1 ] || return 1
  if [ "$is_claude" -eq 1 ] && fm_claude_nonsession "$comm" "$args" "$argv_skip"; then
    return 1
  fi
  FM_HARNESS_MATCH_CLAUDE=$is_claude
  return 0
}

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
# Claude's shared daemon infrastructure (fm_claude_nonsession) is never a
# session, so it is skipped rather than returned. A skip before any match keeps
# walking, which is what still resolves the nested bg-spare chain whose pooled
# workers sit BELOW the session; a skip after a match ends the contiguous run
# exactly as an unrelated process does, because the daemon is parented to init
# and nothing above it belongs to this session. When every candidate is
# infrastructure the walk resolves nothing and every caller fails closed, which
# is the only honest answer: a pooled worker's ancestry carries no evidence of
# the session that claimed it.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' extending=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_session_match "$comm" "$args"; then
      best="$pid"
      if [ "$FM_HARNESS_MATCH_CLAUDE" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

# True if $1 is a live process that looks like a verified harness session.
# Claude's shared daemon infrastructure is deliberately NOT alive for this
# purpose: a lock recorded against a pooled worker or the daemon belongs to no
# session, and the daemon outlives every session, so accepting one as a live
# holder would wedge the home's lock permanently. Rejecting it lets the ordinary
# stale-owner path reclaim such a lock.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_session_match "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}

# True when $1 is shaped like a harness session id (a UUID). Both Claude
# session ids and Stop-payload session_id values are UUIDs; anything else is
# rejected so free-text can never become an identity.
fm_session_id_wellformed() {
  printf '%s' "$1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# Print the current session's harness session id, or fail when no trusted
# source resolves one. $1 is the pid the ancestry walk resolved for this
# process; the environment pair is accepted only when CLAUDE_PID names exactly
# that pid (see the header for the full trust contract).
fm_session_lock_my_session_id() {
  local my_pid=$1 hint=${FM_CLAUDE_SESSION_ID_HINT:-} env_sid=${CLAUDE_CODE_SESSION_ID:-} env_pid=${CLAUDE_PID:-}
  if [ -n "$hint" ] && fm_session_id_wellformed "$hint"; then
    printf '%s\n' "$hint"
    return 0
  fi
  if [ -n "$env_sid" ] && [ -n "$env_pid" ] && [ "$env_pid" = "$my_pid" ] \
    && fm_session_id_wellformed "$env_sid"; then
    printf '%s\n' "$env_sid"
    return 0
  fi
  return 1
}

# Print the session id recorded for state dir $1's lock holder, or fail when
# the sidecar is absent or malformed. A malformed sidecar is treated as absent
# so damaged bytes can never match anything.
fm_session_lock_holder_session_id() {
  local state=$1 sid
  sid=$(cat "$state/.lock-session" 2>/dev/null || true)
  fm_session_id_wellformed "$sid" || return 1
  printf '%s\n' "$sid"
}

# Classify how the current process relates to state dir $1's recorded holder
# $2, given this process's resolved harness pid $3. Prints exactly one of:
#   self          the recorded pid is this session's own harness pid
#   same-session  a different pid, but the recorded session id equals this
#                 session's trusted id: the same logical session in a new
#                 process (a fork/relaunch successor), safe to re-key
#   live-other    a live competing session, or a live holder whose succession
#                 cannot be proven - never reclaimable while it lives
#   stale         the recorded pid is dead or not a harness session shape
# Missing either session id fails toward live-other, never toward takeover.
fm_session_lock_relation() {
  local state=$1 lock_pid=$2 my_pid=$3 my_sid holder_sid
  if [ "$lock_pid" = "$my_pid" ]; then
    printf 'self\n'
    return 0
  fi
  if ! fm_harness_pid_alive "$lock_pid"; then
    printf 'stale\n'
    return 0
  fi
  if my_sid=$(fm_session_lock_my_session_id "$my_pid") \
    && holder_sid=$(fm_session_lock_holder_session_id "$state") \
    && [ "$my_sid" = "$holder_sid" ]; then
    printf 'same-session\n'
    return 0
  fi
  printf 'live-other\n'
}

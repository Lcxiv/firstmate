#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Claude Code process shapes that are NOT a session, matched in argv subcommand
# position (argv[1]) or in a worker's own process title.
# Extend when a new non-session Claude worker role is verified.
FM_CLAUDE_NONSESSION_ARGV1='daemon|bg-spare|bg-pty-host|--bg-spare|--bg-pty-host'

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
# The subcommand test reads argv[1] only, never the whole command line, so a
# session whose PROMPT mentions one of these words stays a session.
fm_claude_nonsession() {
  local comm=$1 args=$2 argv1
  # A pooled worker sets its own process title, so comm alone can carry the role.
  case "$comm" in
    *bg-spare*|*bg-pty-host*) return 0 ;;
  esac
  argv1=${args#* }
  argv1=${argv1%% *}
  printf '%s' "$argv1" | grep -qE "^($FM_CLAUDE_NONSESSION_ARGV1)$"
}

# True when ps fields comm ($1) and args ($2) describe a verified harness
# SESSION process. Sets FM_HARNESS_MATCH_CLAUDE=1 when that session is
# Claude-shaped, which is the only harness whose ancestry nests (see
# fm_harness_ancestry_pid). ONE owner of the "is this process a session of a
# verified harness?" test, so the ancestry walk and the holder-liveness check
# can never disagree about the same pid.
fm_harness_session_match() {
  local comm=$1 args=$2 bc hit=0 is_claude=0
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
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
  fi
  [ "$hit" -eq 1 ] || return 1
  if [ "$is_claude" -eq 1 ] && fm_claude_nonsession "$comm" "$args"; then
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

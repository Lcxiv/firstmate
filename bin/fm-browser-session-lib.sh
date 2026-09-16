#!/usr/bin/env bash
# bin/fm-browser-session-lib.sh - per-task browser-automation session identity.
#
# WHY THIS EXISTS
# chrome-devtools-axi keys its bridge by SESSION NAME, not by task. The bridge is
# spawned `detached: true` + `unref()`, so it leaves the crewmate's process group,
# and the Chrome it launches re-groups again (observed: bridge pgid 60457, Chrome
# pgid 60491). The whole tree keeps the cwd of whoever launched it FIRST, and every
# later `chrome-devtools-axi` call that resolves the same session name reuses that
# same bridge (proved in docs/verification/browser-session-cleanup.md).
#
# Without a per-task binding every browser-using task resolves the same ambient
# session, so:
#   - task A launches the bridge; the tree's cwd is worktree A;
#   - tasks B, C, D reuse A's bridge and drive A's browser;
#   - B/C/D tear down, fm-teardown.sh's cwd sweep (Fix 2) scans their own worktree
#     and tasktmp, correctly finds nothing, and reports success;
#   - the browser, its helpers, the MCP server and the bridge survive with no live
#     task to attribute them to, and accumulate across tasks.
# The sweep is not wrong: its only ownership evidence is "cwd under this task's
# worktree", which records who launched first rather than who owns the work. This
# file supplies the missing evidence at the point where ownership actually exists -
# launch - so cleanup has something task-scoped to consume.
#
# THE BINDING
# fm-spawn.sh derives a name here, exports CHROME_DEVTOOLS_AXI_SESSION into the
# crewmate's shell through the same channel that already ships GOTMPDIR (so every
# backend, harness, ship, scout and secondmate gets it before launch), and records
# browser_session= in state/<id>.meta. fm-teardown.sh reads that field back and
# retires exactly that session. Nothing here scans process names, enumerates control
# ports, or uses age heuristics.
#
# THE OWNERSHIP PROOF (fm_browser_session_bridge_pid)
# Before anything is signalled, three independent records must agree:
#   1. state/<id>.meta's browser_session= names a session, and that name is neither
#      empty nor "default". The default session is the ambient one an operator's own
#      `chrome-devtools-axi` shares (port 9224); a task never owns it.
#   2. ~/.chrome-devtools-axi/sessions/<name>/bridge.pid parses and names a live pid.
#      The path itself is the pid -> session binding; the tool owns that file.
#   3. That pid is BOTH running the chrome-devtools-axi bridge script AND listening
#      on the port the same pid file records. The listen check is `lsof -p <pid>`
#      scoped to one pid and one port - never a scan for browsers on ambient ports -
#      and it is what defeats pid reuse: a recycled pid is not listening there.
# Any disagreement returns non-zero with a reason on stdout, and the caller leaves
# the process alone. Ambiguity never escalates to a signal.
#
# RETIREMENT
# fm_browser_session_stop calls the tool's own `chrome-devtools-axi stop` with
# CHROME_DEVTOOLS_AXI_SESSION set to the proven name. That is the tool's public
# lifecycle owner, not a reimplementation: it runs the bridge's shutdown handler,
# which closes the browser over CDP, and escalates to the bridge's process group.
# Verified to retire the bridge, npx, the MCP server, Chrome, every Chrome helper and
# the updater it spawned, while a concurrently running browser on a different session
# survived untouched (docs/verification/browser-session-cleanup.md).
#
# Idempotent by construction: a retired, never-started, or already-exited session has
# no live pid to prove, so every later call is a silent no-op.
#
# DEGRADATION
# Two cases land back on the pre-binding behavior rather than on a wrong kill: a
# runtime where the exported variable never reaches the agent, and an agent that
# sets CHROME_DEVTOOLS_AXI_SESSION itself for a command. Either way the recorded
# name names no bridge this task started, so the proof finds nothing live to own and
# nothing is signalled. The browser then leaks exactly as it did before; it is never
# some other task's browser that gets retired instead.

_FM_BROWSER_SESSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# bin/fm-timeout-lib.sh owns bounded execution. `set -u` at its top would leak into
# consumers that deliberately run without it, so the caller's setting is restored
# around the source (the same guard bin/fm-classify-lib.sh uses).
case $- in *u*) _fm_browser_session_nounset=on ;; *) _fm_browser_session_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_BROWSER_SESSION_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_browser_session_nounset" = on ] || set +u

# A hung vendor CLI must never hold a teardown open. The tool's own stop polls for
# about 3s before escalating, so this bound only fires when it is genuinely stuck.
FM_BROWSER_SESSION_STOP_TIMEOUT=${FM_BROWSER_SESSION_STOP_TIMEOUT:-30}

# Session names chrome-devtools-axi accepts: 1-64 chars from [A-Za-z0-9._-].
# Anything else makes the tool throw, which would break the crewmate's first
# browser command rather than this cleanup, so the name is built to fit.
FM_BROWSER_SESSION_MAX=64
# The ambient session every unbound caller shares. Never a task's to retire.
FM_BROWSER_SESSION_DEFAULT=default

# fm_browser_session_name <task-id> [scope]
# Deterministic, filesystem-safe session name for one task. <scope> disambiguates
# firstmate homes that share one machine and could hold the same task id - the same
# ambiguity bin/fm-backend-hometag-lib.sh exists for on backend-global namespaces;
# callers pass the owning FM_HOME. The hash covers scope AND id, so two homes
# running one id never collide even after the id is truncated to fit.
fm_browser_session_name() {
  local id=$1 scope=${2:-} safe hash budget
  [ -n "$id" ] || return 1
  hash=$(fm_browser_session_hash "$scope/$id") || return 1
  safe=$(printf '%s' "$id" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  # "fm-" + id + "-" + 8-char hash must fit FM_BROWSER_SESSION_MAX.
  budget=$((FM_BROWSER_SESSION_MAX - 3 - 1 - ${#hash}))
  [ "$budget" -ge 1 ] || return 1
  [ "${#safe}" -le "$budget" ] || safe=${safe:0:$budget}
  printf 'fm-%s-%s' "$safe" "$hash"
}

# fm_browser_session_hash <text> -> 8 hex chars
fm_browser_session_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x", $1}'
  fi
}

# fm_browser_session_state_dir <name>
# The tool's own per-session state directory. Mirrors resolveSessionStateDir():
# named sessions live under sessions/<name>; the default session keeps the legacy
# root, which is exactly why the default name is refused everywhere below.
fm_browser_session_state_dir() {
  local name=$1 base
  base=${FM_BROWSER_SESSION_STATE_ROOT:-$HOME/.chrome-devtools-axi}
  [ -n "$name" ] && [ "$name" != "$FM_BROWSER_SESSION_DEFAULT" ] || return 1
  printf '%s/sessions/%s' "$base" "$name"
}

# fm_browser_session_valid_name <name>
# True only for a name this repo could have minted: task-scoped, in the tool's
# accepted character set, and never the ambient default.
fm_browser_session_valid_name() {
  local name=${1:-}
  [ -n "$name" ] || return 1
  [ "$name" != "$FM_BROWSER_SESSION_DEFAULT" ] || return 1
  [ "${#name}" -le "$FM_BROWSER_SESSION_MAX" ] || return 1
  case "$name" in
    *[!A-Za-z0-9._-]*) return 1 ;;
    fm-*) ;;
    *) return 1 ;;
  esac
  return 0
}

# fm_browser_session_bridge_pid <name>
# Prints "<pid> <port>" when all three records above agree. Otherwise prints a
# one-line reason and returns 1 when nothing live is implicated (no record, a stale
# or corrupt one, an already-exited bridge), or 2 when a LIVE process is implicated
# but not proven ours. The caller must not signal either way; the split exists only
# so a live stranger's record is preserved while a dead one can be cleared.
# Read-only: signals nothing.
fm_browser_session_bridge_pid() {
  local name=${1:-} dir pidfile raw pid port cmd
  if ! fm_browser_session_valid_name "$name"; then
    printf 'recorded browser session name is absent or not task-scoped\n'
    return 1
  fi
  dir=$(fm_browser_session_state_dir "$name") || {
    printf 'no state directory maps to browser session %s\n' "$name"
    return 1
  }
  pidfile="$dir/bridge.pid"
  if [ ! -f "$pidfile" ]; then
    printf 'browser session %s has no recorded bridge\n' "$name"
    return 1
  fi
  raw=$(cat "$pidfile" 2>/dev/null) || {
    printf 'browser session %s bridge record is unreadable\n' "$name"
    return 1
  }
  pid=$(fm_browser_session_json_number "$raw" pid)
  port=$(fm_browser_session_json_number "$raw" port)
  if [ -z "$pid" ] || [ -z "$port" ]; then
    printf 'browser session %s bridge record does not name a pid and port\n' "$name"
    return 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'browser session %s bridge (pid %s) already exited\n' "$name" "$pid"
    return 1
  fi
  cmd=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || cmd=
  case "$cmd" in
    *chrome-devtools-axi-bridge*) ;;
    *)
      printf 'pid %s recorded for browser session %s is not a browser bridge; leaving it alone\n' \
        "$pid" "$name"
      return 2
      ;;
  esac
  if ! fm_browser_session_pid_listens_on "$pid" "$port"; then
    printf 'pid %s is not listening on browser session %s port %s; leaving it alone\n' \
      "$pid" "$name" "$port"
    return 2
  fi
  printf '%s %s\n' "$pid" "$port"
}

# fm_browser_session_json_number <json> <key>
# Minimal reader for the tool's flat {"pid":N,"port":N} record. A record that is
# not that shape yields nothing, which the caller treats as unproven ownership.
fm_browser_session_json_number() {
  local json=$1 key=$2 value
  value=$(printf '%s' "$json" \
    | LC_ALL=C sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
    | head -1)
  case "$value" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$value"
}

# fm_browser_session_pid_listens_on <pid> <port>
# One pid, one port. Never an ambient scan for whatever happens to be listening.
# lsof missing means the binding cannot be proven, so ownership stays unproven.
fm_browser_session_pid_listens_on() {
  local pid=$1 port=$2
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

# fm_browser_session_stop <name>
# Retire one proven session through the tool's public per-session stop. Prints one
# outcome line. Returns 0 when the session is gone or was never live, 1 only when a
# proven-owned bridge survived the tool's own stop.
fm_browser_session_stop() {
  local name=${1:-} proof pid port rc
  proof=$(fm_browser_session_bridge_pid "$name") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'browser cleanup skipped: %s\n' "$proof"
    # rc 1 means nothing live is implicated, so the task's own leftover session
    # directory can go; rc 2 means a live process we refused to touch still owns
    # that record, and removing it would orphan whatever does own it.
    if [ "$rc" -eq 1 ]; then
      fm_browser_session_clear_state "$name"
    fi
    return 0
  fi
  pid=${proof%% *}
  port=${proof##* }
  if ! command -v chrome-devtools-axi >/dev/null 2>&1; then
    printf 'browser cleanup skipped: chrome-devtools-axi is not installed; browser session %s (pid %s) left running\n' \
      "$name" "$pid"
    return 0
  fi
  CHROME_DEVTOOLS_AXI_SESSION="$name" CHROME_DEVTOOLS_AXI_PORT="$port" \
    fm_run_timed "$FM_BROWSER_SESSION_STOP_TIMEOUT" \
      chrome-devtools-axi stop >/dev/null 2>&1 || true
  if kill -0 "$pid" 2>/dev/null \
     && fm_browser_session_pid_listens_on "$pid" "$port"; then
    printf 'browser cleanup incomplete: browser session %s bridge (pid %s) survived stop\n' \
      "$name" "$pid"
    return 1
  fi
  fm_browser_session_clear_state "$name"
  printf 'browser cleanup: retired browser session %s (bridge pid %s)\n' "$name" "$pid"
  return 0
}

# fm_browser_session_clear_state <name>
# Remove one task's own leftover session directory, so binding a session per task
# does not trade a process leak for an unbounded pile of state directories. Guarded
# to a validated task-scoped name, which is what keeps this off the default
# session's legacy root; anything else is a no-op.
fm_browser_session_clear_state() {
  local name=${1:-} dir
  fm_browser_session_valid_name "$name" || return 0
  dir=$(fm_browser_session_state_dir "$name") || return 0
  case "$dir" in
    */sessions/"$name")
      if [ -d "$dir" ]; then
        rm -rf "$dir"
      fi
      ;;
  esac
  return 0
}

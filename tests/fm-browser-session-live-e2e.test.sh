#!/usr/bin/env bash
# Opt-in live guard for per-task browser-session retirement.
#
# The portable suite (tests/fm-browser-session.test.sh) pins firstmate's half: that
# ownership is proved from the task record before anything is signalled, and that
# the right session name reaches the tool. It cannot pin the vendor's half - whether
# `chrome-devtools-axi stop` for ONE session really retires that session's bridge,
# its MCP server, its Chrome and every Chrome helper, while leaving a browser on
# another session untouched. Chrome re-groups itself away from the bridge's process
# group, so that outcome depends on the bridge's own shutdown handler and could
# change in any chrome-devtools-axi release.
#
# This guard measures that against the REAL tool and the REAL browser, in a lab
# built entirely from processes, ports and profiles it creates itself:
#   - two sessions, both named for this run, on kernel-allocated ports;
#   - one is retired, the other must survive byte-for-byte;
#   - nothing pre-existing is read, signalled, or connected to, and the ambient
#     default session (an operator's own browser) is never named. That is enforced,
#     not assumed: every inherited variable that would divert the tool into
#     attaching to an already-running browser is cleared before each launch, and
#     each tree must contain a browser running this lab's own freshly created
#     profile before anything is measured or retired.
# It fails naming the tool version rather than degrading quietly. On a clean run it
# leaves no lab process and no lab state behind. If the tool's own stop ever leaves
# lab processes running past the settle bound, the run FAILS, the guard keeps every
# record naming them - the launched-pid list, the lab profiles and whichever session
# directories still exist - and prints each survivor, so the leak is traceable and
# clearable rather than orphaned. It never signals a process itself, not even its
# own: stopping a session it created, through the tool, is its only reach.
#
# Opt-in because it launches real browsers. Run it after every chrome-devtools-axi
# upgrade and before trusting a refreshed
# docs/verification/browser-session-cleanup.md.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-browser-session-lib.sh
. "$ROOT/bin/fm-browser-session-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_BROWSER_SESSION_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_BROWSER_SESSION_LIVE_E2E=1 to run the real-browser session-retirement guard"
  exit 0
fi

for tool in chrome-devtools-axi lsof python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

AXI_VERSION=$(chrome-devtools-axi --version 2>/dev/null | head -1)
[ -n "$AXI_VERSION" ] || { echo "skip: chrome-devtools-axi did not report a version"; exit 0; }

# Lab identity: every session name, profile and port below is minted here, so
# nothing this guard touches can predate it.
RUN_TAG="live$$-$(date +%s)"
OWNED_SESSION="fm-labowned-$RUN_TAG"
CONTROL_SESSION="fm-labcontrol-$RUN_TAG"
fm_browser_session_valid_name "$OWNED_SESSION" \
  || fail "lab session name $OWNED_SESSION is not task-scoped"
[ "$OWNED_SESSION" != "$FM_BROWSER_SESSION_DEFAULT" ] \
  && [ "$CONTROL_SESSION" != "$FM_BROWSER_SESSION_DEFAULT" ] \
  || fail "lab refused to run: a lab session resolved to the ambient default"

LAB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-session-live.XXXXXX")

# Every pid this lab launched, as "<session> <pid>" lines, written at launch. It has
# to be a FILE: lab_open runs inside a command substitution, so a shell array never
# reaches the EXIT trap. Chrome is reparented to init once the bridge exits, so it
# stops being a descendant of anything - the tree has to be captured while it is
# still walkable, not rediscovered afterwards.
LAB_LAUNCHED="$LAB_ROOT/launched"

lab_stop() {  # <session>
  CHROME_DEVTOOLS_AXI_SESSION="$1" chrome-devtools-axi stop >/dev/null 2>&1 || true
}

# lab_survivors -> one line per launched process still alive AND still identifiable
# as this lab's own. Identity is the run's own LAB_ROOT in the process command line,
# so a recycled pid can never be reported as a lab leak. Read-only: this file never
# signals a process, including its own.
lab_survivors() {
  local session pid cmd
  [ -f "$LAB_LAUNCHED" ] || return 0
  while read -r session pid; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    cmd=$(ps -ww -p "$pid" -o command= 2>/dev/null) || continue
    case "$cmd" in
      *"$LAB_ROOT"*)
        printf '  session %s  pid %-7s %s\n' \
          "$session" "$pid" "$(ps -ww -p "$pid" -o comm= 2>/dev/null)" ;;
    esac
  done < "$LAB_LAUNCHED"
}

# On the clean path the records are the lab's own litter and go. On the UNCLEAN path
# they are the only thing naming the processes still running, so deleting them would
# turn a leak this guard caused into an untraceable one - the exact shape of the
# incident this whole change exists for. They are kept and pointed at instead, and
# the run goes red: "left nothing behind" is one of this guard's acceptance criteria,
# so failing it has to be a failure rather than a note under an ok.
#
# The census waits first, on the same bound the body uses after a stop. The tool's
# stop returns once the BRIDGE pid is gone, while Chrome is closed over CDP by the
# MCP server and can still be winding down for a moment afterwards. Censusing the
# instant stop returns would read that ordinary latency as a leak and publish it as
# an accusation against a tool version operators are told to trust.
cleanup() {
  local survivors waited=0 dir
  lab_stop "$OWNED_SESSION"
  lab_stop "$CONTROL_SESSION"
  survivors=$(lab_survivors)
  while [ -n "$survivors" ] && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
    survivors=$(lab_survivors)
  done
  if [ -n "$survivors" ]; then
    {
      printf 'LAB NOT CLEAN: chrome-devtools-axi %s left lab processes running %ss after stop.\n' \
        "$AXI_VERSION" "$waited"
      printf 'Nothing was signalled; this guard only ever stops sessions it created, through the tool.\n'
      printf 'Still running:\n%s\n' "$survivors"
      printf 'Records kept so you can trace and clear them:\n'
      printf '  %s   <- the launched pids listed above\n' "$LAB_LAUNCHED"
      printf '  %s   <- lab profiles\n' "$LAB_ROOT"
      for dir in "$HOME/.chrome-devtools-axi/sessions/$OWNED_SESSION" \
                 "$HOME/.chrome-devtools-axi/sessions/$CONTROL_SESSION"; do
        [ -d "$dir" ] && printf '  %s   <- session record\n' "$dir"
      done
    } >&2
    exit 1
  fi
  rm -rf "$HOME/.chrome-devtools-axi/sessions/$OWNED_SESSION" \
         "$HOME/.chrome-devtools-axi/sessions/$CONTROL_SESSION"
  rm -rf "$LAB_ROOT"
}
trap cleanup EXIT

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PY
}

# lab_open <session> <profile-dir> -> echoes the bridge pid; launches a real browser
# on its own control port with its own freshly created profile.
#
# A session name isolates the BRIDGE only. Connection mode is chosen separately, and
# in the tool's own buildTransportArgs the attach modes win outright over the
# profile: `if (autoConnect) ... else if (browserUrl) ... else { userDataDir ... }`.
# An operator who exported CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 (the tool's README
# suggests exactly that) would otherwise have this guard attach to their own running
# Chrome, open a tab in it, and then retire it. Every variable in that attach class
# is therefore cleared here, so the lab can only ever take the launch path into the
# profile it just created.
lab_open() {
  local session=$1 profile=$2 port proof bridge pid
  port=$(free_port)
  mkdir -p "$profile"
  ( cd "$LAB_ROOT" && \
    env -u CHROME_DEVTOOLS_AXI_AUTO_CONNECT \
        -u CHROME_DEVTOOLS_AXI_BROWSER_URL \
        -u CHROME_DEVTOOLS_AXI_WS_HEADERS \
      CHROME_DEVTOOLS_AXI_SESSION="$session" \
      CHROME_DEVTOOLS_AXI_PORT="$port" \
      CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile" \
      chrome-devtools-axi open about:blank >/dev/null 2>&1 ) || true
  proof=$(fm_browser_session_bridge_pid "$session") \
    || fail "chrome-devtools-axi $AXI_VERSION: lab session $session never came up ($proof)"
  bridge=${proof%% *}
  for pid in $(lab_tree "$bridge"); do
    printf '%s %s\n' "$session" "$pid" >> "$LAB_LAUNCHED"
  done
  printf '%s' "$bridge"
}

# lab_tree <bridge-pid> -> every pid descended from the bridge, this lab's only reach.
lab_tree() {
  python3 - "$1" <<'PY'
import collections, subprocess, sys
out = subprocess.run(["ps", "-Ao", "pid,ppid"], capture_output=True, text=True).stdout.splitlines()[1:]
kids = collections.defaultdict(list)
for line in out:
    parts = line.split()
    if len(parts) >= 2:
        kids[int(parts[1])].append(int(parts[0]))
seen, stack = [], [int(sys.argv[1])]
while stack:
    p = stack.pop()
    seen.append(p)
    stack.extend(kids.get(p, []))
print(" ".join(str(p) for p in sorted(seen)))
PY
}

alive_count() {
  local pid n=0
  for pid in $1; do kill -0 "$pid" 2>/dev/null && n=$((n + 1)); done
  printf '%s' "$n"
}

# lab_browser_pid <tree> <profile-dir> -> the pid of the browser this lab launched
# into that profile, or non-zero if the tree holds none. The browser is the process
# carrying Chrome's own `--user-data-dir=<profile>`; the node processes above it
# carry the tool's camelCase `--userDataDir=`, so this cannot mistake one for the
# other. Scoped to pids already inside this lab's own tree - never a search of the
# process table for browsers.
lab_browser_pid() {
  local pid tree=$1 profile=$2
  for pid in $tree; do
    case "$(ps -ww -p "$pid" -o command= 2>/dev/null)" in
      *"--user-data-dir=$profile"*) printf '%s' "$pid"; return 0 ;;
    esac
  done
  return 1
}

identities() {
  local pid
  for pid in $1; do ps -p "$pid" -o pid=,lstart= 2>/dev/null; done
}

test_real_stop_retires_one_session_only() {
  local owned_pid control_pid owned_tree control_tree before after waited
  owned_pid=$(lab_open "$OWNED_SESSION" "$LAB_ROOT/profile-owned")
  control_pid=$(lab_open "$CONTROL_SESSION" "$LAB_ROOT/profile-control")
  owned_tree=$(lab_tree "$owned_pid")
  control_tree=$(lab_tree "$control_pid")
  # A process count cannot tell a real browser tree from bridge + npx + MCP server
  # + node with no browser at all, and that is exactly the shape an attach mode
  # produces. Require the browser ITSELF, positively bound to the profile this lab
  # just created, or "its whole browser tree was retired" would be recorded as
  # version-scoped evidence for something never measured.
  lab_browser_pid "$owned_tree" "$LAB_ROOT/profile-owned" >/dev/null \
    || fail "chrome-devtools-axi $AXI_VERSION: no browser running this lab's own owned profile is present in the launched tree; nothing meaningful to retire"
  lab_browser_pid "$control_tree" "$LAB_ROOT/profile-control" >/dev/null \
    || fail "chrome-devtools-axi $AXI_VERSION: no browser running this lab's own control profile is present in the launched tree"
  before=$(identities "$control_tree")

  # The production call, with exactly the production argument.
  fm_browser_session_stop "$OWNED_SESSION" >/dev/null \
    || fail "chrome-devtools-axi $AXI_VERSION: retiring session $OWNED_SESSION reported an incomplete stop"
  waited=0
  while [ "$waited" -lt 10 ]; do
    [ "$(alive_count "$owned_tree")" -eq 0 ] && break
    waited=$((waited + 1))
    sleep 1
  done

  [ "$(alive_count "$owned_tree")" -eq 0 ] \
    || fail "chrome-devtools-axi $AXI_VERSION: $(alive_count "$owned_tree") process(es) of the retired browser survived stop"
  [ "$(alive_count "$control_tree")" -eq "$(printf '%s' "$control_tree" | wc -w | tr -d ' ')" ] \
    || fail "chrome-devtools-axi $AXI_VERSION: retiring one session killed processes of another session's browser"
  after=$(identities "$control_tree")
  [ "$before" = "$after" ] \
    || fail "chrome-devtools-axi $AXI_VERSION: the unrelated lab browser did not survive byte-for-byte"
  # Idempotence against the real tool: the record is gone, so a repeat is a no-op
  # and must not reach for a replacement process.
  fm_browser_session_stop "$OWNED_SESSION" >/dev/null \
    || fail "chrome-devtools-axi $AXI_VERSION: a repeated retirement reported failure"
  [ "$(alive_count "$control_tree")" -eq "$(printf '%s' "$control_tree" | wc -w | tr -d ' ')" ] \
    || fail "chrome-devtools-axi $AXI_VERSION: a repeated retirement killed the unrelated lab browser"
  pass "chrome-devtools-axi $AXI_VERSION: retiring one session retires its whole browser tree and leaves another session's browser untouched"
}

test_real_stop_retires_one_session_only

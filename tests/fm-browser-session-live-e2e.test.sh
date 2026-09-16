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
#     default session (an operator's own browser) is never named.
# It fails naming the tool version rather than degrading quietly, and leaves no lab
# process or lab state behind.
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

lab_stop() {  # <session>
  CHROME_DEVTOOLS_AXI_SESSION="$1" chrome-devtools-axi stop >/dev/null 2>&1 || true
}

cleanup() {
  lab_stop "$OWNED_SESSION"
  lab_stop "$CONTROL_SESSION"
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
lab_open() {
  local session=$1 profile=$2 port proof
  port=$(free_port)
  mkdir -p "$profile"
  ( cd "$LAB_ROOT" && \
    CHROME_DEVTOOLS_AXI_SESSION="$session" \
    CHROME_DEVTOOLS_AXI_PORT="$port" \
    CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile" \
    chrome-devtools-axi open about:blank >/dev/null 2>&1 ) || true
  proof=$(fm_browser_session_bridge_pid "$session") \
    || fail "chrome-devtools-axi $AXI_VERSION: lab session $session never came up ($proof)"
  printf '%s' "${proof%% *}"
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
  # A real browser tree is a bridge, an MCP server and a Chrome with helpers. Fewer
  # than that means the lab never actually launched a browser, so a later "it was
  # retired" would be vacuous.
  [ "$(alive_count "$owned_tree")" -ge 4 ] \
    || fail "chrome-devtools-axi $AXI_VERSION: owned lab browser tree is only $(alive_count "$owned_tree") processes; nothing meaningful to retire"
  [ "$(alive_count "$control_tree")" -ge 4 ] \
    || fail "chrome-devtools-axi $AXI_VERSION: control lab browser tree is only $(alive_count "$control_tree") processes"
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

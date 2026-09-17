#!/usr/bin/env bash
# Manual live scenario: the REAL bin/fm-teardown.sh, with the REAL chrome-devtools-axi
# on PATH and a REAL headless Chrome, retires the browser session recorded in the
# task's meta, while a control browser on another lab session survives byte-for-byte.
# Every process, profile, port and session name here is created by this script.
# The browsers are launched from a cwd OUTSIDE the task's worktree, so the existing
# cwd sweep (Fix 2) cannot reach them: only Fix 4 can.
set -u
ROOT=/Users/louiscondevaux/.no-mistakes/worktrees/71bad1a6f2bc/01M2PC61AT3702RM09BJQSHQZD
. "$ROOT/bin/fm-browser-session-lib.sh"
fail() { printf 'not ok - %s\n' "$1"; exit 1; }
TAG="rt$$-$(date +%s)"
ID="br-real-$TAG"
LAB=$(mktemp -d /tmp/fm-real-teardown-lab.XXXXXX)
FAKE="$LAB/home"
LAUNCHED="$LAB/launched"
mkdir -p "$FAKE/bin/backends" "$FAKE/state" "$FAKE/data" "$LAB/launcher-cwd"
ln -s "$ROOT"/bin/*.sh "$FAKE/bin/"
ln -s "$ROOT"/bin/backends/*.sh "$FAKE/bin/backends/"
rm -f "$FAKE/bin/fm-guard.sh" "$FAKE/bin/fm-fleet-sync.sh" "$FAKE/bin/fm-tasks-axi-lib.sh" "$FAKE/bin/fm-remote-job-reap-orphans.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/bin/fm-guard.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/bin/fm-fleet-sync.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/bin/fm-remote-job-reap-orphans.sh"
chmod +x "$FAKE/bin/fm-guard.sh" "$FAKE/bin/fm-fleet-sync.sh" "$FAKE/bin/fm-remote-job-reap-orphans.sh"
cat > "$FAKE/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
OWNED=$(fm_browser_session_name "$ID" "$FAKE") || fail "could not derive a session name"
CONTROL="fm-labcontrol-$TAG"
{
  printf 'window=fakeses:fm-%s\n' "$ID"
  printf 'worktree=%s/nonexistent-wt-%s\n' "$LAB" "$ID"
  printf 'project=%s/nonexistent-proj-%s\n' "$LAB" "$ID"
  printf 'harness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\n'
  printf 'browser_session=%s\n' "$OWNED"
} > "$FAKE/state/$ID.meta"
echo "task id:          $ID"
echo "owned session:    $OWNED   (derived exactly as fm-spawn records it)"
echo "control session:  $CONTROL"
echo "meta:"; sed 's/^/  /' "$FAKE/state/$ID.meta"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
lab_tree() { python3 - "$1" <<'PY'
import collections, subprocess, sys
out = subprocess.run(["ps", "-Ao", "pid,ppid"], capture_output=True, text=True).stdout.splitlines()[1:]
kids = collections.defaultdict(list)
for line in out:
    p = line.split()
    if len(p) >= 2: kids[int(p[1])].append(int(p[0]))
seen, stack = [], [int(sys.argv[1])]
while stack:
    p = stack.pop(); seen.append(p); stack.extend(kids.get(p, []))
print(" ".join(str(p) for p in sorted(seen)))
PY
}
alive_count() { local n=0 p; for p in $1; do kill -0 "$p" 2>/dev/null && n=$((n+1)); done; printf '%s' "$n"; }
identities() { local p; for p in $1; do ps -p "$p" -o pid=,lstart= 2>/dev/null; done; }
lab_open() {  # <session> <profile> -> bridge pid
  local session=$1 profile=$2 port proof bridge
  port=$(free_port); mkdir -p "$profile"
  ( cd "$LAB/launcher-cwd" && env -u CHROME_DEVTOOLS_AXI_AUTO_CONNECT -u CHROME_DEVTOOLS_AXI_BROWSER_URL -u CHROME_DEVTOOLS_AXI_WS_HEADERS \
      CHROME_DEVTOOLS_AXI_SESSION="$session" CHROME_DEVTOOLS_AXI_PORT="$port" CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile" \
      chrome-devtools-axi open about:blank >/dev/null 2>&1 ) || true
  proof=$(fm_browser_session_bridge_pid "$session") || fail "lab session $session never came up ($proof)"
  bridge=${proof%% *}
  for p in $(lab_tree "$bridge"); do printf '%s %s\n' "$session" "$p" >> "$LAUNCHED"; done
  printf '%s' "$bridge"
}
cleanup() {
  CHROME_DEVTOOLS_AXI_SESSION="$CONTROL" chrome-devtools-axi stop >/dev/null 2>&1 || true
  CHROME_DEVTOOLS_AXI_SESSION="$OWNED" chrome-devtools-axi stop >/dev/null 2>&1 || true
  local w=0 left
  while [ "$w" -lt 15 ]; do
    left=0
    while read -r s p; do kill -0 "$p" 2>/dev/null && case "$(ps -ww -p "$p" -o command= 2>/dev/null)" in *"$LAB"*) left=$((left+1));; esac; done < "$LAUNCHED"
    [ "$left" -eq 0 ] && break; sleep 1; w=$((w+1))
  done
  echo "cleanup: lab processes still alive after ${w}s: $left"
  rm -rf "$HOME/.chrome-devtools-axi/sessions/$OWNED" "$HOME/.chrome-devtools-axi/sessions/$CONTROL"
  [ "$left" -eq 0 ] && rm -rf "$LAB" || echo "cleanup: kept $LAB (records of survivors)"
}
trap cleanup EXIT

owned_pid=$(lab_open "$OWNED" "$LAB/profile-owned") || exit 1
control_pid=$(lab_open "$CONTROL" "$LAB/profile-control") || exit 1
owned_tree=$(lab_tree "$owned_pid"); control_tree=$(lab_tree "$control_pid")
echo
echo "owned bridge pid $owned_pid; pid file: $(cat "$HOME/.chrome-devtools-axi/sessions/$OWNED/bridge.pid")"
echo "owned tree ($(echo $owned_tree | wc -w | tr -d ' ') processes):"
for p in $owned_tree; do ps -ww -p "$p" -o pid=,ppid=,pgid=,comm= | cut -c1-120; done
echo "control bridge pid $control_pid; pid file: $(cat "$HOME/.chrome-devtools-axi/sessions/$CONTROL/bridge.pid")"
echo "control tree ($(echo $control_tree | wc -w | tr -d ' ') processes):"
for p in $control_tree; do ps -ww -p "$p" -o pid=,ppid=,pgid=,comm= | cut -c1-120; done
echo
echo "browser cwd (outside the task worktree, so the cwd sweep cannot attribute it):"
lsof -a -d cwd -p "$owned_pid" -Fn 2>/dev/null | sed -n 's/^n//p'
grep -c -- "--user-data-dir=$LAB/profile-owned" <(for p in $owned_tree; do ps -ww -p "$p" -o command=; done) | sed 's/^/owned tree processes running the lab-owned profile: /'
before=$(identities "$control_tree")

echo
# FM_GATE_REFUSE_BYPASS=1 is the documented test-harness escape hatch in bin/fm-gate-refuse-lib.sh
# (this shell carries NO_MISTAKES_GATE); the home here is a throwaway sandbox under /tmp, as in tests/.
echo "\$ FM_GATE_REFUSE_BYPASS=1 FM_HOME=$FAKE bash $FAKE/bin/fm-teardown.sh $ID      (real chrome-devtools-axi on PATH)"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$FAKE" bash "$FAKE/bin/fm-teardown.sh" "$ID" > "$LAB/teardown.out" 2>&1; rc=$?
sed 's/^/  | /' "$LAB/teardown.out"; echo "teardown exit=$rc"
[ "$rc" -eq 0 ] || fail "teardown exited $rc"
w=0; while [ "$w" -lt 15 ] && [ "$(alive_count "$owned_tree")" -ne 0 ]; do sleep 1; w=$((w+1)); done
echo
echo "owned tree alive after teardown (+${w}s): $(alive_count "$owned_tree") of $(echo $owned_tree | wc -w | tr -d ' ')"
echo "control tree alive:                     $(alive_count "$control_tree") of $(echo $control_tree | wc -w | tr -d ' ')"
after=$(identities "$control_tree")
[ "$(alive_count "$owned_tree")" -eq 0 ] || fail "owned browser tree survived teardown"
[ "$(alive_count "$control_tree")" -eq "$(echo $control_tree | wc -w | tr -d ' ')" ] || fail "control tree lost processes"
[ "$before" = "$after" ] || fail "control tree identities changed"
echo "control tree identities byte-for-byte identical: yes"
[ ! -d "$HOME/.chrome-devtools-axi/sessions/$OWNED" ] || fail "owned session dir left behind"
[ -f "$HOME/.chrome-devtools-axi/sessions/$CONTROL/bridge.pid" ] || fail "control session record was cleared"
echo "owned session dir removed: yes; control session record intact: yes"
grep -q "browser cleanup: stopped browser session $OWNED" "$LAB/teardown.out" || fail "teardown did not report the stop"
grep -q "$CONTROL" "$LAB/teardown.out" && fail "teardown mentioned the control session"
echo
echo "repeat retirement (idempotence) via the interface teardown calls:"
out=$(fm_browser_session_stop "$OWNED" 2>&1); rc=$?
echo "  rc=$rc output=[$out]"
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "repeat retirement not a silent no-op"
[ "$(alive_count "$control_tree")" -eq "$(echo $control_tree | wc -w | tr -d ' ')" ] || fail "repeat retirement touched the control tree"
echo "ok - real fm-teardown.sh retired the task's recorded chrome-devtools-axi $(chrome-devtools-axi --version | head -1) session (bridge + MCP server + Chrome + helpers) and left the control browser untouched"

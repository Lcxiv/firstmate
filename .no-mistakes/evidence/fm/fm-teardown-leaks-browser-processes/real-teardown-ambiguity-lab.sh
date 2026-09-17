#!/usr/bin/env bash
# Adversarial live scenario: the REAL bin/fm-teardown.sh with the REAL chrome-devtools-axi on
# PATH and a REAL headless Chrome running on lab session S. Three task records each try to
# implicate that live browser (or another live process) through a record that does NOT prove
# ownership. Teardown must refuse every time, never invoke the tool's stop, and leave the
# browser byte-for-byte intact. A stale record naming an exited pid is cleared as litter.
set -u
ROOT=/Users/louiscondevaux/.no-mistakes/worktrees/71bad1a6f2bc/01M2PC61AT3702RM09BJQSHQZD
. "$ROOT/bin/fm-browser-session-lib.sh"
fail() { printf 'not ok - %s\n' "$1"; exit 1; }
TAG="amb$$-$(date +%s)"
LAB=$(mktemp -d /tmp/fm-real-ambiguity-lab.XXXXXX) || exit 1
FAKE="$LAB/home"; SESS="$HOME/.chrome-devtools-axi/sessions"
mkdir -p "$FAKE/bin/backends" "$FAKE/state" "$FAKE/data" "$LAB/launcher-cwd"
ln -s "$ROOT"/bin/*.sh "$FAKE/bin/"; ln -s "$ROOT"/bin/backends/*.sh "$FAKE/bin/backends/"
rm -f "$FAKE/bin/fm-guard.sh" "$FAKE/bin/fm-fleet-sync.sh" "$FAKE/bin/fm-tasks-axi-lib.sh" "$FAKE/bin/fm-remote-job-reap-orphans.sh"
for s in fm-guard.sh fm-fleet-sync.sh fm-remote-job-reap-orphans.sh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/bin/$s"; chmod +x "$FAKE/bin/$s"; done
printf 'fm_tasks_axi_backend_available() { return 1; }\nfm_tasks_axi_compatible() { return 1; }\nfm_backlog_backend_manual() { return 1; }\n' > "$FAKE/bin/fm-tasks-axi-lib.sh"
S="fm-lablive-$TAG"; Y="fm-labmismatch-$TAG"; Z="fm-labreuse-$TAG"; W="fm-labstale-$TAG"
meta() { { printf 'window=fakeses:fm-%s\nworktree=%s/nonexistent-wt-%s\nproject=%s/nonexistent-proj-%s\n' "$1" "$LAB" "$1" "$LAB" "$1"; printf 'harness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\nbrowser_session=%s\n' "$2"; } > "$FAKE/state/$1.meta"; }
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
SLEEPER=; tree=
cleanup() {
  CHROME_DEVTOOLS_AXI_SESSION="$S" chrome-devtools-axi stop >/dev/null 2>&1 || true
  [ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null || true
  local w=0; while [ $w -lt 15 ] && [ "$(alive_count "$tree")" -ne 0 ]; do sleep 1; w=$((w+1)); done
  echo "cleanup: lab browser processes still alive after ${w}s: $(alive_count "$tree")"
  local d; for d in "$S" "$Y" "$Z" "$W"; do [ -d "${SESS:?}/${d:?}" ] && rm -rf "${SESS:?}/${d:?}"; done
  if [ "$(alive_count "$tree")" -eq 0 ]; then rm -rf "${LAB:?}"; else echo "cleanup: kept $LAB"; fi
}
trap cleanup EXIT
port=$(free_port); mkdir -p "$LAB/profile-live"
( cd "$LAB/launcher-cwd" && env -u CHROME_DEVTOOLS_AXI_AUTO_CONNECT -u CHROME_DEVTOOLS_AXI_BROWSER_URL -u CHROME_DEVTOOLS_AXI_WS_HEADERS \
    CHROME_DEVTOOLS_AXI_SESSION="$S" CHROME_DEVTOOLS_AXI_PORT="$port" CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$LAB/profile-live" \
    chrome-devtools-axi open about:blank >/dev/null 2>&1 ) || true
proof=$(fm_browser_session_bridge_pid "$S") || fail "live lab session never came up ($proof)"
bridge=${proof%% *}; tree=$(lab_tree "$bridge"); n=$(echo $tree | wc -w | tr -d ' ')
echo "live lab session $S: bridge pid $bridge, record $(cat "$SESS/$S/bridge.pid"), tree of $n processes"
before=$(identities "$tree")
sleep 600 & SLEEPER=$!
echo "unrelated live non-bridge process (stands in for a recycled pid): sleep pid $SLEEPER"
mkdir -p "$SESS/$Y" "$SESS/$Z" "$SESS/$W"
wrong=$(free_port)
printf '{"pid":%s,"port":%s}\n' "$bridge" "$wrong" > "$SESS/$Y/bridge.pid"
printf '{"pid":%s,"port":%s}\n' "$SLEEPER" "$port" > "$SESS/$Z/bridge.pid"
sleep 0 & dead=$!; wait "$dead" 2>/dev/null
printf '{"pid":%s,"port":%s}\n' "$dead" "$port" > "$SESS/$W/bridge.pid"
meta "br-mis-$TAG" "$Y"; meta "br-reuse-$TAG" "$Z"; meta "br-stale-$TAG" "$W"
echo "records under test:"
echo "  $Y -> {pid=$bridge (the REAL live bridge), port=$wrong (NOT the port it serves)}"
echo "  $Z -> {pid=$SLEEPER (live, not a bridge), port=$port}"
echo "  $W -> {pid=$dead (already exited), port=$port}"
run_td() { FM_GATE_REFUSE_BYPASS=1 FM_HOME="$FAKE" bash "$FAKE/bin/fm-teardown.sh" "$1" 2>&1 | grep -i "browser" | sed 's/^/  | /'; }
check_intact() {
  [ "$(alive_count "$tree")" -eq "$n" ] || fail "$1: the live lab browser lost processes ($(alive_count "$tree") of $n alive)"
  [ "$(identities "$tree")" = "$before" ] || fail "$1: the live lab browser identities changed"
  lsof -nP -a -p "$bridge" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || fail "$1: the live bridge stopped listening (a stop was issued)"
  [ -f "$SESS/$S/bridge.pid" ] || fail "$1: the live session's own record was cleared"
}
echo; echo "\$ teardown br-mis-$TAG   (record names the live bridge pid but the wrong port)"; run_td "br-mis-$TAG"
check_intact mismatch; [ -f "$SESS/$Y/bridge.pid" ] || fail "mismatch: record of a live, refused process was deleted"
echo "  => live browser intact ($(alive_count "$tree")/$n, byte-for-byte), still listening on $port; refused record kept"
echo; echo "\$ teardown br-reuse-$TAG   (record names a live pid that is not a bridge)"; run_td "br-reuse-$TAG"
check_intact reuse; kill -0 "$SLEEPER" 2>/dev/null || fail "reuse: the non-bridge process was signalled"
[ -f "$SESS/$Z/bridge.pid" ] || fail "reuse: record of a live, refused process was deleted"
echo "  => sleep $SLEEPER alive, live browser intact ($(alive_count "$tree")/$n), refused record kept"
echo; echo "\$ teardown br-stale-$TAG   (record names an exited pid)"; run_td "br-stale-$TAG"
check_intact stale; [ ! -d "$SESS/$W" ] || fail "stale: dead session directory was left to accumulate"
echo "  => live browser intact ($(alive_count "$tree")/$n); stale record directory cleared"
echo; echo "ok - real fm-teardown.sh refused all three unproven records against chrome-devtools-axi $(chrome-devtools-axi --version | head -1); the live lab browser never lost a process and the tool's stop was never issued"

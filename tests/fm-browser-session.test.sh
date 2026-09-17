#!/usr/bin/env bash
# Behavior tests for per-task browser-automation session ownership.
#
# THE BUG THESE PIN
# chrome-devtools-axi keys its bridge by session name. The bridge is detached, in
# its own process group, and its whole Chrome tree keeps the cwd of whoever launched
# it first. With no per-task binding, task B reuses task A's bridge, so B's teardown
# sweeps B's own worktree, correctly finds nothing, and reports success while the
# browser survives. fm-spawn now records browser_session= in the task's meta and
# fm-teardown retires exactly that session.
#
# WHAT IS EXERCISED
# The public interfaces only: bin/fm-browser-session-lib.sh's derivation and proof
# functions, and the REAL bin/fm-teardown.sh as a subprocess against a fake
# FM_HOME/FM_ROOT. Every browser in here is a real long-lived process that really
# listens on a real port and really has a child, so retirement and survival are
# observed, never asserted against source text.
#
# The boundary is `chrome-devtools-axi stop`: a stub stands in for it and retires
# whatever session it is handed, so a teardown that proved the wrong session would
# kill the wrong browser and fail these tests. The real tool's retirement behavior
# is covered by the opt-in live guard (tests/fm-browser-session-live-e2e.test.sh).
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

LIB="$ROOT/bin/fm-browser-session-lib.sh"

# Fixture browsers are started inside command substitutions, so the registry has to
# be a FILE: a shell array written in that subshell never reaches this trap, and the
# processes outlive the run. Only pids recorded here are ever signalled.
LAB_PID_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-browser-session-labpids.XXXXXX")

lab_register() { printf '%s\n' "$1" >> "$LAB_PID_FILE"; }

browser_lab_cleanup() {
  local pid
  if [ -f "$LAB_PID_FILE" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -KILL -- "-$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
    done < "$LAB_PID_FILE"
    rm -f "$LAB_PID_FILE"
  fi
  fm_test_cleanup
}
trap browser_lab_cleanup EXIT

TMP_ROOT=$(fm_test_tmproot fm-browser-session-tests) || exit 1
STATE_ROOT="$TMP_ROOT/axi-state"
mkdir -p "$STATE_ROOT/sessions"

# --- fake bridge ------------------------------------------------------------
# A real process that looks to the proof exactly like a chrome-devtools-axi bridge:
# its command contains "chrome-devtools-axi-bridge", it listens on the port its pid
# file records, it leads its own process group, and it has a child standing in for
# the browser. Nothing here resembles a real Chrome, because nothing in the
# production path matches on browser process names.
BRIDGE_SCRIPT="$TMP_ROOT/chrome-devtools-axi-bridge.js"
cat > "$BRIDGE_SCRIPT" <<'PYBRIDGE'
import os, signal, socket, sys, time
port = int(sys.argv[1])
os.setsid()
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
# SIGUSR1 stands in for a shutdown that got as far as releasing the listening
# socket and then wedged: the process stays alive, the port is no longer served.
signal.signal(signal.SIGUSR1, lambda *_: srv.close())
if os.fork() == 0:            # stand-in for the browser tree under the bridge
    while True:
        time.sleep(3600)
sys.stdout.write("%d\n" % port)
sys.stdout.flush()
while True:
    time.sleep(3600)
PYBRIDGE

# free_port: ask the kernel for an unused port rather than guessing one.
free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PY
}

# start_bridge <session-name> -> echoes "<pid> <port>"; writes the tool's pid file.
start_bridge() {
  local name=$1 port pid dir attempt
  port=$(free_port)
  python3 "$BRIDGE_SCRIPT" "$port" >/dev/null 2>&1 &
  pid=$!
  lab_register "$pid"
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && break
    attempt=$((attempt + 1))
    sleep 0.2
  done
  lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
    || fail "fixture bridge for $name never listened on $port"
  if [ "$name" = default ]; then
    dir="$STATE_ROOT"
  else
    dir="$STATE_ROOT/sessions/$name"
  fi
  mkdir -p "$dir"
  printf '{"pid":%s,"port":%s}\n' "$pid" "$port" > "$dir/bridge.pid"
  printf '%s %s\n' "$pid" "$port"
}

# bridge_tree <pid> -> the bridge pid plus its children, as a sorted pid list.
bridge_tree() {
  local pid=$1
  { printf '%s\n' "$pid"; pgrep -P "$pid" 2>/dev/null || true; } | sort -n
}

tree_alive_count() {
  local pid alive=0
  for pid in $1; do kill -0 "$pid" 2>/dev/null && alive=$((alive + 1)); done
  printf '%s' "$alive"
}

# --- fake FM_HOME/FM_ROOT ---------------------------------------------------
# Symlink every real bin/ library in rather than enumerating them, so a new
# teardown dependency does not silently break this fixture, then override the few
# that must not touch live state.
make_fake_root() {
  local id=$1 session=$2 stop_log=$3 kind=${4:-ship}
  local fake="$TMP_ROOT/home-$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  ln -s "$ROOT"/bin/*.sh "$fake/bin/" 2>/dev/null || true
  ln -s "$ROOT"/bin/backends/*.sh "$fake/bin/backends/" 2>/dev/null || true
  rm -f "$fake/bin/fm-guard.sh" "$fake/bin/fm-fleet-sync.sh" \
        "$fake/bin/fm-tasks-axi-lib.sh" "$fake/bin/fm-remote-job-reap-orphans.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/bin/fm-guard.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/bin/fm-fleet-sync.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/bin/fm-remote-job-reap-orphans.sh"
  chmod +x "$fake/bin/fm-guard.sh" "$fake/bin/fm-fleet-sync.sh" \
           "$fake/bin/fm-remote-job-reap-orphans.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  # Stand-in for the tool: retire whatever session it is told to, and log it, so a
  # teardown that named the wrong session is observable as a wrongly-killed browser.
  mkdir -p "$fake/fakebin"
  cat > "$fake/fakebin/chrome-devtools-axi" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${CHROME_DEVTOOLS_AXI_SESSION:-<unset>}" >> "$stop_log"
[ "\${1:-}" = stop ] || exit 0
name=\${CHROME_DEVTOOLS_AXI_SESSION:-default}
if [ "\$name" = default ]; then dir="$STATE_ROOT"; else dir="$STATE_ROOT/sessions/\$name"; fi
pid=\$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "\$dir/bridge.pid" 2>/dev/null)
[ -n "\$pid" ] || exit 0
kill -KILL -- "-\$pid" 2>/dev/null || true
kill -KILL "\$pid" 2>/dev/null || true
rm -f "\$dir/bridge.pid"
exit 0
STUB
  chmod +x "$fake/fakebin/chrome-devtools-axi"
  {
    printf 'window=fakeses:fm-%s\n' "$id"
    printf 'worktree=%s/nonexistent-wt-%s\n' "$TMP_ROOT" "$id"
    printf 'project=%s/nonexistent-proj-%s\n' "$TMP_ROOT" "$id"
    printf 'harness=claude\nkind=%s\nmode=no-mistakes\nyolo=off\n' "$kind"
    [ "$session" = '<none>' ] || printf 'browser_session=%s\n' "$session"
  } > "$fake/state/$id.meta"
  if [ "$kind" = secondmate ]; then
    # A secondmate is retired by home, not by worktree: it needs a genuine seeded
    # home and the registry route that binds it to this id, or teardown refuses
    # before it ever reaches the browser step.
    local sub="$TMP_ROOT/secondmate-home-$id"
    mkdir -p "$sub/bin" "$sub/data" "$sub/state"
    printf '# Firstmate\n' > "$sub/AGENTS.md"
    printf '%s\n' "$id" > "$sub/.fm-secondmate-home"
    printf '%s\n' "$fake" > "$sub/.fm-secondmate-parent"
    mkdir -p "$fake/data"
    printf -- '- %s - browser session guard (home: %s; scope: browser cleanup; projects: none; added 2026-09-16)\n' \
      "$id" "$sub" > "$fake/data/secondmates.md"
    printf 'home=%s\n' "$sub" >> "$fake/state/$id.meta"
  fi
  printf '%s' "$fake"
}

run_teardown() {  # <fake-root> <id> -> stdout+stderr on fd 1
  local fake=$1 id=$2
  PATH="$fake/fakebin:$PATH" \
  FM_HOME="$fake" \
  FM_BROWSER_SESSION_STATE_ROOT="$STATE_ROOT" \
    bash "$fake/bin/fm-teardown.sh" "$id" 2>&1
}

run_stop() {  # <fake-root> <session> -> stdout+stderr on fd 1, exit code preserved
  local fake=$1 name=$2
  PATH="$fake/fakebin:$PATH" \
  FM_BROWSER_SESSION_STATE_ROOT="$STATE_ROOT" \
    bash -c '. "$1"; fm_browser_session_stop "$2"' _ "$LIB" "$name" 2>&1
}

# no_lsof_path: a PATH holding only the externals the ownership proof needs, with
# lsof deliberately absent, so `command -v lsof` really fails for the code under
# test instead of the test pretending it did.
NO_LSOF_BIN="$TMP_ROOT/no-lsof-bin"
no_lsof_path() {
  local tool src
  if [ ! -d "$NO_LSOF_BIN" ]; then
    mkdir -p "$NO_LSOF_BIN"
    for tool in cat ps sed head rm sleep dirname basename mkdir; do
      src=$(command -v "$tool") || fail "no-lsof fixture needs $tool"
      ln -sf "$src" "$NO_LSOF_BIN/$tool"
    done
  fi
  command -v lsof >/dev/null 2>&1 \
    && [ ! -e "$NO_LSOF_BIN/lsof" ] || fail "the no-lsof fixture PATH still resolves lsof"
  printf '%s' "$NO_LSOF_BIN"
}

# --- name derivation --------------------------------------------------------

test_name_is_task_scoped_and_never_default() {
  local a b c long
  a=$(bash -c '. "$1"; fm_browser_session_name "$2" "$3"' _ "$LIB" alpha home-1)
  b=$(bash -c '. "$1"; fm_browser_session_name "$2" "$3"' _ "$LIB" beta home-1)
  c=$(bash -c '. "$1"; fm_browser_session_name "$2" "$3"' _ "$LIB" alpha home-2)
  [ -n "$a" ] || fail "no session name derived"
  [ "$a" != "$b" ] || fail "two tasks in one home derived the same session ($a)"
  [ "$a" != "$c" ] || fail "one task id in two homes derived the same session ($a)"
  [ "$a" = "$(bash -c '. "$1"; fm_browser_session_name "$2" "$3"' _ "$LIB" alpha home-1)" ] \
    || fail "session name is not stable across calls"
  [ "$a" != default ] || fail "derived the ambient default session name"
  # The tool rejects anything outside [A-Za-z0-9._-]{1,64}; an invalid name would
  # break the crewmate's first browser command, not cleanup.
  long=$(bash -c '. "$1"; fm_browser_session_name "$2" "$3"' _ "$LIB" \
    "a-very-long-task-id-$(printf 'x%.0s' $(seq 1 120))" home-1)
  [ "${#long}" -le 64 ] || fail "long task id produced a ${#long}-char session name"
  case "$long" in *[!A-Za-z0-9._-]*) fail "session name has characters the tool rejects: $long" ;; esac
  case "$(bash -c '. "$1"; fm_browser_session_name "$2" "$3"' _ "$LIB" 'id with/slash and spaces' h)" in
    *[!A-Za-z0-9._-]*) fail "unsafe task id leaked unsafe characters into the session name" ;;
  esac
  pass "session names are task-scoped, home-scoped, stable, and always tool-legal"
}

# --- the launch half of the record -------------------------------------------

# spawn_case <name> -> "<home>|<proj>|<wt>|<fakebin>|<launchlog>"
# Minimal spawn world: a real git worktree for the pane path, a held session lock,
# and the shared tmux/treehouse stubs.
spawn_case() {
  local name=$1 id=$2 dir home proj wt fakebin launchlog
  dir="$TMP_ROOT/spawn-$name"
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"; launchlog="$dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake" claude)
  fm_test_spawn_home "$home" claude
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog"
}

run_case_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  : > "$launchlog.calls"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_TMUX_CALL_LOG="$launchlog.calls" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" --mode no-mistakes --yolo off 2>&1
}

test_spawn_binds_and_records_the_session() {
  # fm-spawn must publish the task's session in BOTH places cleanup depends on:
  # the crewmate's shell (or its first browser command resolves the ambient
  # session) and the task's meta (or cleanup has nothing to consume).
  local id=br-spawn-z1 rec home proj wt fakebin launchlog out session other
  rec=$(spawn_case one "$id")
  IFS='|' read -r home proj wt fakebin launchlog <<< "$rec"
  out=$(run_case_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj") \
    || fail "spawn failed: $out"
  session=$(sed -n 's/^browser_session=//p' "$home/state/$id.meta")
  [ -n "$session" ] || fail "spawn did not record a browser session for the task"
  [ "$session" != default ] || fail "spawn bound the task to the ambient default session"
  grep -Fq "export CHROME_DEVTOOLS_AXI_SESSION=$session" "$launchlog.calls" \
    || fail "spawn did not export the task's browser session into the crewmate shell"
  # The recorded name must be exactly what the cleanup library derives, so the two
  # halves of the record cannot drift apart.
  [ "$session" = "$(bash -c '. "$1"; fm_browser_session_name "$2" "$3"' \
      _ "$LIB" "$id" "$home")" ] \
    || fail "spawn recorded a session name the cleanup library does not derive"
  # A second home holding the same task id must not land on the same session.
  rec=$(spawn_case two "$id")
  IFS='|' read -r home proj wt fakebin launchlog <<< "$rec"
  out=$(run_case_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj") \
    || fail "second-home spawn failed: $out"
  other=$(sed -n 's/^browser_session=//p' "$home/state/$id.meta")
  [ -n "$other" ] || fail "second home recorded no browser session"
  [ "$other" != "$session" ] \
    || fail "two homes running the same task id bound one browser session ($session)"
  pass "fm-spawn binds a task-scoped browser session in the crewmate shell and the task record"
}

# --- retirement, with a control browser running the whole time ---------------

test_owned_browser_retired_control_survives() {
  local owned control owned_pid control_pid owned_port control_port
  local owned_tree control_tree before after fake out before_stops
  owned=$(start_bridge fm-owned-a1b2c3d4); owned_pid=${owned%% *}; owned_port=${owned##* }
  control=$(start_bridge fm-control-9f8e7d6c); control_pid=${control%% *}; control_port=${control##* }
  owned_tree=$(bridge_tree "$owned_pid")
  control_tree=$(bridge_tree "$control_pid")
  [ "$(tree_alive_count "$owned_tree")" -ge 2 ] || fail "owned fixture browser has no child"
  [ "$(tree_alive_count "$control_tree")" -ge 2 ] || fail "control fixture browser has no child"
  before=$(for p in $control_tree; do ps -p "$p" -o pid=,lstart= 2>/dev/null; done)
  fake=$(make_fake_root br-retire fm-owned-a1b2c3d4 "$TMP_ROOT/stop-retire.log")
  out=$(run_teardown "$fake" br-retire) || fail "teardown failed: $out"
  sleep 1
  [ "$(tree_alive_count "$owned_tree")" -eq 0 ] \
    || fail "the task's own browser survived teardown ($(tree_alive_count "$owned_tree") of the tree still alive)"
  [ "$(tree_alive_count "$control_tree")" -eq 2 ] \
    || fail "an unrelated browser was killed by teardown"
  after=$(for p in $control_tree; do ps -p "$p" -o pid=,lstart= 2>/dev/null; done)
  [ "$before" = "$after" ] || fail "the unrelated browser did not survive byte-for-byte"
  lsof -nP -a -p "$control_pid" -iTCP:"$control_port" -sTCP:LISTEN >/dev/null 2>&1 \
    || fail "the unrelated browser stopped serving its own port"
  grep -q "stop fm-owned-a1b2c3d4" "$TMP_ROOT/stop-retire.log" \
    || fail "teardown did not retire the recorded session"
  grep -q "fm-control-9f8e7d6c" "$TMP_ROOT/stop-retire.log" \
    && fail "teardown touched the unrelated session"
  [ ! -d "$STATE_ROOT/sessions/fm-owned-a1b2c3d4" ] \
    || fail "teardown left the retired session's state directory behind"
  [ -f "$STATE_ROOT/sessions/fm-control-9f8e7d6c/bridge.pid" ] \
    || fail "teardown cleared the unrelated session's record"
  case "$out" in
    *"retired browser session"*|*"browser retired"*)
      fail "teardown claimed the browser tree was retired when only the bridge was proved: $out" ;;
  esac
  case "$out" in
    *"browser cleanup: stopped browser session fm-owned-a1b2c3d4"*) ;;
    *) fail "teardown did not report the stop it performed: $out" ;;
  esac
  # Repeat cleanup, driven at the interface teardown actually calls: the record is
  # gone, so a second retirement must succeed, say nothing, and signal nothing.
  # (A second run_teardown could not show this - it exits at endpoint validation
  # long before the browser step, so it would pass however the mechanism behaved.)
  before_stops=$(wc -l < "$TMP_ROOT/stop-retire.log")
  out=$(run_stop "$fake" fm-owned-a1b2c3d4) \
    || fail "a repeated retirement of an already-retired session failed: $out"
  [ -z "$out" ] || fail "a repeated retirement was not silent: $out"
  [ "$(wc -l < "$TMP_ROOT/stop-retire.log")" -eq "$before_stops" ] \
    || fail "a repeated retirement invoked the browser tool again"
  [ "$(tree_alive_count "$control_tree")" -eq 2 ] \
    || fail "a repeated retirement killed the unrelated browser"
  pass "the task's own browser and its child are retired; an unrelated browser survives byte-for-byte"
  printf '%s' "$owned_port" >/dev/null
}

test_secondmate_retires_its_own_session() {
  # fm-spawn binds and records a session for EVERY kind, secondmate included, so a
  # secondmate teardown that skipped the browser step would leak exactly the tree
  # this whole mechanism exists for.
  local owned control owned_pid control_pid control_port
  local owned_tree control_tree fake out
  owned=$(start_bridge fm-sub-a0b1c2d3); owned_pid=${owned%% *}
  control=$(start_bridge fm-sub-control-d3c2b1a0)
  control_pid=${control%% *}; control_port=${control##* }
  owned_tree=$(bridge_tree "$owned_pid")
  control_tree=$(bridge_tree "$control_pid")
  [ "$(tree_alive_count "$owned_tree")" -ge 2 ] || fail "secondmate fixture browser has no child"
  fake=$(make_fake_root br-sub fm-sub-a0b1c2d3 "$TMP_ROOT/stop-sub.log" secondmate)
  out=$(run_teardown "$fake" br-sub) || fail "secondmate teardown failed: $out"
  sleep 1
  [ "$(tree_alive_count "$owned_tree")" -eq 0 ] \
    || fail "a secondmate's own browser survived its teardown ($(tree_alive_count "$owned_tree") alive)"
  grep -q "stop fm-sub-a0b1c2d3" "$TMP_ROOT/stop-sub.log" \
    || fail "secondmate teardown did not retire its recorded session"
  grep -q "fm-sub-control-d3c2b1a0" "$TMP_ROOT/stop-sub.log" \
    && fail "secondmate teardown touched an unrelated session"
  [ "$(tree_alive_count "$control_tree")" -eq 2 ] \
    || fail "secondmate teardown killed an unrelated browser"
  lsof -nP -a -p "$control_pid" -iTCP:"$control_port" -sTCP:LISTEN >/dev/null 2>&1 \
    || fail "the unrelated browser stopped serving its own port"
  pass "a secondmate teardown retires its own proven browser session and no other"
}

test_forced_secondmate_cleanup_retires_child_sessions() {
  # A forced secondmate cleanup erases each child's meta - the ONLY record naming
  # that child's session. If the child's bridge is not retired before that, its
  # browser tree is permanently unattributable: exactly the leak this fix targets.
  local owned control owned_pid control_pid control_port owned_tree control_tree
  local fake sub out
  owned=$(start_bridge fm-child-c0ffee11); owned_pid=${owned%% *}
  control=$(start_bridge fm-child-control-11eeff0c)
  control_pid=${control%% *}; control_port=${control##* }
  owned_tree=$(bridge_tree "$owned_pid")
  control_tree=$(bridge_tree "$control_pid")
  [ "$(tree_alive_count "$owned_tree")" -ge 2 ] || fail "child fixture browser has no child process"
  fake=$(make_fake_root br-force fm-parent-none-00000000 "$TMP_ROOT/stop-force.log" secondmate)
  sub="$TMP_ROOT/secondmate-home-br-force"
  {
    printf 'window=fakeses:fm-kid\n'
    printf 'worktree=%s/nonexistent-wt-kid\n' "$TMP_ROOT"
    printf 'project=%s/nonexistent-proj-kid\n' "$TMP_ROOT"
    printf 'harness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'browser_session=fm-child-c0ffee11\n'
  } > "$sub/state/kid.meta"
  out=$(PATH="$fake/fakebin:$PATH" FM_HOME="$fake" \
    FM_BROWSER_SESSION_STATE_ROOT="$STATE_ROOT" \
    bash "$fake/bin/fm-teardown.sh" br-force --force 2>&1) \
    || fail "forced secondmate teardown failed: $out"
  sleep 1
  [ ! -f "$sub/state/kid.meta" ] || fail "forced cleanup left the child record behind"
  [ "$(tree_alive_count "$owned_tree")" -eq 0 ] \
    || fail "the child's browser survived its home's forced cleanup ($(tree_alive_count "$owned_tree") alive)"
  grep -q "stop fm-child-c0ffee11" "$TMP_ROOT/stop-force.log" \
    || fail "forced cleanup removed the child record without retiring its session"
  grep -q "fm-child-control-11eeff0c" "$TMP_ROOT/stop-force.log" \
    && fail "forced cleanup touched an unrelated session"
  [ "$(tree_alive_count "$control_tree")" -eq 2 ] \
    || fail "forced cleanup killed an unrelated browser"
  lsof -nP -a -p "$control_pid" -iTCP:"$control_port" -sTCP:LISTEN >/dev/null 2>&1 \
    || fail "the unrelated browser stopped serving its own port"
  pass "a forced secondmate cleanup retires each child's proven session before erasing its record"
}

test_alive_bridge_that_released_its_port_is_reported_and_kept() {
  # A shutdown that releases the listening socket and then wedges leaves the proven
  # pid alive with its port free. Identity was proven BEFORE the stop, so that pid
  # is still the bridge: it must be reported as surviving and its record - the only
  # evidence a later cleanup could ever use - must be preserved.
  local b pid port tree fake out session=fm-wedged-abcd1234
  b=$(start_bridge "$session"); pid=${b%% *}; port=${b##* }
  tree=$(bridge_tree "$pid")
  fake=$(make_fake_root br-wedged "$session" "$TMP_ROOT/stop-wedged.log")
  # Stand in for the wedged vendor stop: release the port, leave the process alive.
  cat > "$fake/fakebin/chrome-devtools-axi" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\${1:-}" "\${CHROME_DEVTOOLS_AXI_SESSION:-<unset>}" >> "$TMP_ROOT/stop-wedged.log"
[ "\${1:-}" = stop ] || exit 0
kill -USR1 $pid 2>/dev/null || true
exit 0
STUB
  chmod +x "$fake/fakebin/chrome-devtools-axi"
  out=$(run_stop "$fake" "$session") && fail "a surviving bridge was reported as a successful stop: $out"
  sleep 1
  [ "$(tree_alive_count "$tree")" -eq 2 ] || fail "the fixture bridge died; this case proves nothing"
  lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
    && fail "the fixture bridge never released its port; this case proves nothing"
  case "$out" in
    *"is still alive after stop"*) ;;
    *) fail "a surviving bridge was not reported as surviving: $out" ;;
  esac
  case "$out" in
    *" is gone"*) fail "a live bridge was reported as gone: $out" ;;
  esac
  [ -f "$STATE_ROOT/sessions/$session/bridge.pid" ] \
    || fail "the only ownership record of a live bridge was deleted"
  pass "a bridge alive but no longer listening is reported as surviving and keeps its record"
}

# --- ambiguity refuses ------------------------------------------------------

test_pid_reuse_is_refused() {
  # The pid file names a live process that is NOT a bridge: exactly what pid reuse
  # after the owned bridge exited looks like. Nothing may be signalled.
  local victim_pid tree fake out session=fm-reuse-11223344
  sleep 600 & victim_pid=$!
  lab_register "$victim_pid"
  mkdir -p "$STATE_ROOT/sessions/$session"
  printf '{"pid":%s,"port":%s}\n' "$victim_pid" "$(free_port)" \
    > "$STATE_ROOT/sessions/$session/bridge.pid"
  tree=$(bridge_tree "$victim_pid")
  fake=$(make_fake_root br-reuse "$session" "$TMP_ROOT/stop-reuse.log")
  out=$(run_teardown "$fake" br-reuse) || fail "teardown failed: $out"
  sleep 1
  kill -0 "$victim_pid" 2>/dev/null \
    || fail "teardown killed a reused pid that was not a browser bridge"
  [ ! -f "$TMP_ROOT/stop-reuse.log" ] \
    || fail "teardown invoked browser retirement on unproven ownership"
  case "$out" in
    *"not a browser bridge"*) ;;
    *) fail "teardown did not report why it left the process alone: $out" ;;
  esac
  [ -f "$STATE_ROOT/sessions/$session/bridge.pid" ] \
    || fail "teardown cleared a record whose live owner it had refused to touch"
  printf '%s' "$tree" >/dev/null
  pass "a recorded pid that is not a browser bridge is reported and left alone"
}

test_port_identity_mismatch_is_refused() {
  # A real bridge process, but the recorded port is not the one it serves: the
  # record and the live process disagree, so ownership is unproven.
  local b pid tree fake out session=fm-mismatch-55667788 other
  b=$(start_bridge "$session"); pid=${b%% *}
  other=$(free_port)
  printf '{"pid":%s,"port":%s}\n' "$pid" "$other" \
    > "$STATE_ROOT/sessions/$session/bridge.pid"
  tree=$(bridge_tree "$pid")
  fake=$(make_fake_root br-mismatch "$session" "$TMP_ROOT/stop-mismatch.log")
  out=$(run_teardown "$fake" br-mismatch) || fail "teardown failed: $out"
  sleep 1
  [ "$(tree_alive_count "$tree")" -eq 2 ] \
    || fail "teardown killed a bridge whose recorded port did not match the live one"
  [ ! -f "$TMP_ROOT/stop-mismatch.log" ] \
    || fail "teardown invoked retirement despite an identity mismatch"
  case "$out" in
    *"not listening on"*) ;;
    *) fail "teardown did not report the identity mismatch: $out" ;;
  esac
  [ -f "$STATE_ROOT/sessions/$session/bridge.pid" ] \
    || fail "teardown cleared a live bridge's record after refusing to retire it"
  pass "a recorded pid not serving the recorded port is reported and left alone"
}

test_default_session_is_never_retired() {
  # A meta naming the ambient default session must never retire it: that is the
  # session an operator's own chrome-devtools-axi shares.
  local b pid tree fake out
  b=$(start_bridge default); pid=${b%% *}
  tree=$(bridge_tree "$pid")
  fake=$(make_fake_root br-default default "$TMP_ROOT/stop-default.log")
  out=$(run_teardown "$fake" br-default) || fail "teardown failed: $out"
  sleep 1
  [ "$(tree_alive_count "$tree")" -eq 2 ] \
    || fail "teardown retired the ambient default browser session"
  [ ! -f "$TMP_ROOT/stop-default.log" ] \
    || fail "teardown invoked retirement for the default session"
  [ -f "$STATE_ROOT/bridge.pid" ] \
    || fail "teardown cleared the ambient default session's own record"
  pass "the ambient default browser session is never retired"
}

test_missing_lsof_refuses_and_says_why() {
  # lsof-less hosts are supported (fm-teardown.sh has its own fallback there). The
  # listen check cannot run at all on such a host, so ownership is unproven - but
  # "we could not look" is a different fact from "we looked and it is not there",
  # and reporting the latter both misdirects the operator and claims a measurement
  # that never happened.
  local b pid tree fake out session=fm-nolsof-7f7f7f7f
  b=$(start_bridge "$session"); pid=${b%% *}
  tree=$(bridge_tree "$pid")
  fake=$(make_fake_root br-nolsof "$session" "$TMP_ROOT/stop-nolsof.log")
  out=$(PATH="$(no_lsof_path):$fake/fakebin" \
    FM_BROWSER_SESSION_STATE_ROOT="$STATE_ROOT" \
    /bin/bash -c '. "$1"; fm_browser_session_stop "$2"' _ "$LIB" "$session" 2>&1) \
    || fail "an unprovable session must not fail cleanup: $out"
  sleep 1
  [ "$(tree_alive_count "$tree")" -eq 2 ] \
    || fail "a bridge whose ownership could not be proven was signalled anyway"
  [ ! -f "$TMP_ROOT/stop-nolsof.log" ] \
    || fail "retirement was invoked without a completed ownership proof"
  [ -f "$STATE_ROOT/sessions/$session/bridge.pid" ] \
    || fail "the only ownership record of a possibly-live bridge was cleared"
  case "$out" in
    *"is not listening on"*)
      fail "cleanup asserted an unmeasured negative when lsof was unavailable: $out" ;;
  esac
  case "$out" in
    *"lsof is unavailable"*) ;;
    *) fail "cleanup did not name the missing tool as the reason: $out" ;;
  esac
  case "$out" in
    *"$session"*"nothing was retired"*) ;;
    *) fail "cleanup did not report the session it left alone: $out" ;;
  esac
  pass "a host without lsof reports ownership as unprovable, retires nothing, and keeps the record"
}

# --- stale, absent, and already-exited records ------------------------------

test_stale_and_absent_records_are_no_ops() {
  local fake out session=fm-stale-99aabbcc dead
  # (a) a pid file naming a pid that has already exited.
  sleep 0 & dead=$!; wait "$dead" 2>/dev/null || true
  mkdir -p "$STATE_ROOT/sessions/$session"
  printf '{"pid":%s,"port":%s}\n' "$dead" "$(free_port)" \
    > "$STATE_ROOT/sessions/$session/bridge.pid"
  fake=$(make_fake_root br-stale "$session" "$TMP_ROOT/stop-stale.log")
  out=$(run_teardown "$fake" br-stale) || fail "teardown failed on a stale record: $out"
  [ ! -f "$TMP_ROOT/stop-stale.log" ] || fail "teardown retired an already-exited browser"
  case "$out" in *"bridge record is stale"*) ;; *) fail "stale record not reported: $out" ;; esac
  # Only the bridge pid was checked, so the report must not claim the browser went.
  case "$out" in
    *"browser session $session"*"already exited"*"not checked"*) ;;
    *) fail "stale record report claimed more than the bridge pid: $out" ;;
  esac
  [ ! -d "$STATE_ROOT/sessions/$session" ] \
    || fail "teardown left a dead session's state directory to accumulate"
  # (b) a session recorded but never started (no pid file at all): nothing an
  # operator can act on, so teardown must say nothing at all about browsers.
  fake=$(make_fake_root br-never fm-never-00112233 "$TMP_ROOT/stop-never.log")
  out=$(run_teardown "$fake" br-never) || fail "teardown failed with no bridge record: $out"
  [ ! -f "$TMP_ROOT/stop-never.log" ] || fail "teardown retired a session that never started"
  case "$out" in
    *"browser cleanup"*) fail "teardown spoke about a session that never started a bridge: $out" ;;
  esac
  # (c) a corrupt record IS worth reporting: the record itself is wrong.
  mkdir -p "$STATE_ROOT/sessions/fm-corrupt-44556677"
  printf 'not json at all\n' > "$STATE_ROOT/sessions/fm-corrupt-44556677/bridge.pid"
  fake=$(make_fake_root br-corrupt fm-corrupt-44556677 "$TMP_ROOT/stop-corrupt.log")
  out=$(run_teardown "$fake" br-corrupt) || fail "teardown failed on a corrupt record: $out"
  [ ! -f "$TMP_ROOT/stop-corrupt.log" ] || fail "teardown acted on a corrupt record"
  case "$out" in
    *"does not name a pid and port"*) ;;
    *) fail "teardown did not report a corrupt bridge record: $out" ;;
  esac
  # (d) backward compatibility: a task spawned before browser_session= existed.
  # Nothing was ever recorded, so teardown has nothing to say.
  fake=$(make_fake_root br-legacy '<none>' "$TMP_ROOT/stop-legacy.log")
  out=$(run_teardown "$fake" br-legacy) || fail "teardown failed without browser_session=: $out"
  [ ! -f "$TMP_ROOT/stop-legacy.log" ] || fail "teardown retired something with no recorded session"
  case "$out" in
    *"browser cleanup"*) fail "teardown spoke about browsers for a task with no recorded session: $out" ;;
  esac
  pass "stale and corrupt records are reported; never-started and pre-binding records are silent no-ops"
}

test_name_is_task_scoped_and_never_default
test_spawn_binds_and_records_the_session
test_owned_browser_retired_control_survives
test_secondmate_retires_its_own_session
test_forced_secondmate_cleanup_retires_child_sessions
test_alive_bridge_that_released_its_port_is_reported_and_kept
test_pid_reuse_is_refused
test_port_identity_mismatch_is_refused
test_default_session_is_never_retired
test_missing_lsof_refuses_and_says_why
test_stale_and_absent_records_are_no_ops

#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh, docs/watcher-continuity.md).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it hermetically
# as a child of a fake harness (a bash symlink named "claude") whose pid is
# written into the fixture home's state/.lock for ordinary owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so no
# real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-autoarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. Any extra env assignments must be exported
# before invocation. Captures stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    cadence-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf '%s\n' "${FM_CHECK_INTERVAL:-missing}" > "$FM_HOME/state/arm-cadence"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    benign-live)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    reset-boundary)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/arm-waiting"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.02; done
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    slow-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: slow fixture\n'
exit 0
SH
      ;;
    blocking-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 6
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    supersede-then-fail)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'epoch=999 owner_pid=1 outcome=arming updated_at=%s\nfixture-superseder-identity\n' "$(date +%s)" \
  > "$FM_HOME/state/.claude-autoarm-epoch"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    meta-vanishes)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.afk"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

epoch_outcome() {
  sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# Run the hook in the background under the fake harness, output captured to a
# file. Sets RUN_AUTOARM_BG_PID (a direct child of the calling shell, so the
# caller can `wait` on it for the hook's exit status).
RUN_AUTOARM_BG_PID=
run_autoarm_bg() {
  local dir=$1 out=$2
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' > "$out" 2>&1 &
  RUN_AUTOARM_BG_PID=$!
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$dir
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# --- registration contract ----------------------------------------------------

# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # No state/.lock: run the hook directly (no fake harness, no lock file).
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "auto-arm: inert with no session lock"
}

test_reclaims_stale_session_lock_before_arming() {
  local dir out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 2 "$status" "a dead recorded session owner must be reclaimed before the actionable rewake"
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  [ "$actual_owner" = "$expected_owner" ] || fail "stale session lock was not claimed by the current harness: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the stale session lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale-lock recovery must record outcome=rewake"
  pass "auto-arm: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before arming"
}

# A live process whose command name is claude and whose argv subcommand is
# "daemon": the shape of Claude Code's shared background daemon, which sets its
# own process title exactly this way. Echoes its pid.
# One process with no child and no inherited pipe, so killing the pid ends the
# whole fixture and the caller's command substitution never waits on it.
start_fake_claude_daemon() {
  exec -a "claude daemon run --origin transient" sleep 60 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

test_reclaims_live_daemon_owner_before_arming() {
  local dir daemon_pid out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/daemon-owner")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # Claude Code's background daemon is claude-named, shared by every session of
  # the user, and outlives all of them, so a lock recorded against it belongs to
  # no session and can never be seen to go stale. Treating it as a competing
  # live owner left this hook inert on every Stop for the whole session, with
  # nothing else routinely arming the watcher. It must be reclaimed instead.
  daemon_pid=$(start_fake_claude_daemon)
  printf '%s\n' "$daemon_pid" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"daemon-owner"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  expect_code 2 "$status" "a live shared-daemon lock owner must be reclaimed before the actionable rewake"
  [ "$actual_owner" = "$expected_owner" ] \
    || fail "shared-daemon lock was not claimed by the current session: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the shared-daemon lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "shared-daemon reclaim must record outcome=rewake"
  pass "auto-arm: a live shared-daemon lock owner is reclaimed, not mistaken for a competing session"
}

test_foreign_live_owner_notifies_once_without_arm_or_reclaim() {
  local dir other out out2 status status2 owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  # A live owner from another session must never be armed over or reclaimed,
  # but a silently inert hook is exactly how a fork handover went unnoticed:
  # the working session's hooks kept landing here while the superseded pre-fork
  # process held the lock. The first firing wakes the model once with the
  # foreign-owner diagnosis; every later firing for the same holder is silent.
  # The trailing exit keeps each body multi-command so bash cannot
  # tail-exec-collapse the fake harness away from the hook's ancestry walk.
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"; rc=$?; exit "$rc"' 2>&1); status=$?
  out2=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"; rc=$?; exit "$rc"' 2>&1); status2=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 2 "$status" "the first firing under a live foreign owner must wake the model with the diagnosis"
  assert_contains "$out" "held by another live session (pid $other" "the notice must name the live holder"
  assert_contains "$out" "recover automatically" "the notice must state how ownership recovers"
  expect_code 0 "$status2" "a repeat firing for the same holder must stay silent"
  [ -z "$out2" ] || fail "repeat firing for the same holder produced output: $out2"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "foreign-owner notice must record outcome=rewake"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the notice"
  pass "auto-arm: a live foreign owner gets one loud notice, never an arm, rewake loop, or lock replacement"
}

test_foreign_owner_notice_respects_afk_and_need_gates() {
  local dir other out status
  # AFK: the away daemon owns triage, so even the foreign-owner state stays
  # byte-for-byte inert.
  dir=$(make_primary_dir "$TMP_ROOT/foreign-afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"; rc=$?; exit "$rc"' 2>&1); status=$?
  expect_code 0 "$status" "the foreign-owner notice must not fire while AFK owns triage"
  [ -z "$out" ] || fail "foreign owner under AFK produced output: $out"
  [ ! -e "$dir/state/.claude-autoarm-foreign-lock" ] || fail "foreign marker written despite AFK"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "epoch written despite AFK"

  # Idle: with no supervision need there is nothing the model must handle, so
  # the state stays silent exactly as before.
  dir=$(make_primary_dir "$TMP_ROOT/foreign-idle")
  write_arm_fixture "$dir" actionable
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"; rc=$?; exit "$rc"' 2>&1); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "the foreign-owner notice must not fire without supervision need"
  [ -z "$out" ] || fail "foreign owner without need produced output: $out"
  [ ! -e "$dir/state/.claude-autoarm-foreign-lock" ] || fail "foreign marker written despite no need"
  pass "auto-arm: the foreign-owner notice honors the unchanged AFK and supervision-need gates"
}

test_same_session_successor_rekeys_and_arms() {
  local dir old sid out status expected_owner actual_owner
  sid='33333333-3333-3333-3333-333333333333'
  dir=$(make_primary_dir "$TMP_ROOT/fork-successor")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The id-KEEPING relaunch shape (NOT Claude's fork, which mints a new id):
  # a live predecessor process still holds the lock, the sidecar records the
  # logical session id, and the Stop payload of the firing session proves the
  # same id, so this is the SAME session in a new process. The hook must
  # re-key the pid through fm-lock.sh and arm, exactly like the stale-owner
  # path, instead of treating its own session as foreign.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  old=$!
  printf '%s\n' "$old" > "$dir/state/.lock"
  printf '%s\n' "$sid" > "$dir/state/.lock-session"
  out=$(printf '%s\n' "{\"session_id\":\"$sid\"}" \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  kill "$old" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  expect_code 2 "$status" "a same-session successor must re-key and arm to the actionable rewake"
  [ "$actual_owner" = "$expected_owner" ] \
    || fail "same-session successor did not re-key the lock: expected $expected_owner, got $actual_owner"
  [ "$(cat "$dir/state/.lock-session")" = "$sid" ] || fail "re-keying lost the recorded session id"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after the same-session re-key"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "same-session re-key must record outcome=rewake"
  pass "auto-arm: an id-keeping relaunch successor of the recorded session re-keys the lock and arms"
}

test_fork_successor_gets_notice_then_reclaims_when_holder_exits() {
  local dir old sid_old sid_new out out2 status status2 expected_owner
  sid_old='88888888-8888-8888-8888-888888888888'
  sid_new='99999999-9999-9999-9999-999999999999'
  dir=$(make_primary_dir "$TMP_ROOT/fork-new-sid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The production fork shape from docs/verification/supervision.md: Claude
  # Code's --fork-session mints the working successor a NEW session id, so the
  # sidecar (pre-fork id) can never match the successor's payload id and
  # same-session re-keying must NOT fire. While the pre-fork process lives,
  # the successor gets exactly the loud foreign-owner diagnosis and mutates
  # nothing...
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  old=$!
  printf '%s\n' "$old" > "$dir/state/.lock"
  printf '%s\n' "$sid_old" > "$dir/state/.lock-session"
  out=$(printf '%s\n' "{\"session_id\":\"$sid_new\"}" \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"; rc=$?; exit "$rc"' 2>&1); status=$?
  expect_code 2 "$status" "a fork successor must get the foreign-owner notice while the pre-fork process lives"
  assert_contains "$out" "held by another live session (pid $old, session $sid_old)" "the notice must name the pre-fork holder and its recorded session"
  [ "$(cat "$dir/state/.lock")" = "$old" ] || fail "a fork successor mutated the lock despite the live pre-fork holder"
  [ "$(cat "$dir/state/.lock-session")" = "$sid_old" ] || fail "a fork successor mutated the sidecar despite the live pre-fork holder"
  [ ! -e "$dir/state/arm-ran" ] || fail "a fork successor armed while the pre-fork process held the lock"
  # ...and the moment the superseded process exits, the ordinary stale path
  # completes the handover: reclaim, re-key to the successor's identity, arm.
  kill "$old" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  out2=$(printf '%s\n' "{\"session_id\":\"$sid_new\"}" \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status2=$?
  expected_owner=$(cat "$dir/state/expected-owner")
  expect_code 2 "$status2" "the firing after the pre-fork process exits must reclaim and arm: $out2"
  [ "$(cat "$dir/state/.lock")" = "$expected_owner" ] || fail "stale reclaim did not re-key the lock to the fork successor"
  [ "$(cat "$dir/state/.lock-session")" = "$sid_new" ] || fail "stale reclaim did not record the successor's own session id"
  [ -e "$dir/state/arm-ran" ] || fail "the fork successor did not arm after reclaiming"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "fork-successor reclaim must record outcome=rewake"
  pass "auto-arm: a fork successor (new session id) gets the loud notice, then reclaims automatically once the pre-fork process exits"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "AFK without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "AFK without positive recovery reset the attended alarm"
  pass "auto-arm: inert while AFK owns supervision"
}

test_stale_lock_recovery_preserves_afk_and_need_gates() {
  local afk_dir idle_dir out status
  afk_dir=$(make_primary_dir "$TMP_ROOT/stale-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  printf '9999999\n' > "$afk_dir/state/.lock"
  write_arm_fixture "$afk_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-afk"}' | FM_HOME="$afk_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the AFK gate"
  [ "$(cat "$afk_dir/state/.lock")" = 9999999 ] || fail "AFK stale lock was reclaimed despite away ownership"
  [ ! -e "$afk_dir/state/arm-ran" ] || fail "stale AFK home armed"

  idle_dir=$(make_primary_dir "$TMP_ROOT/stale-idle")
  printf '9999999\n' > "$idle_dir/state/.lock"
  write_arm_fixture "$idle_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-idle"}' | FM_HOME="$idle_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the supervision-need gate"
  [ "$(cat "$idle_dir/state/.lock")" = 9999999 ] || fail "idle stale lock was reclaimed without supervision need"
  [ ! -e "$idle_dir/state/arm-ran" ] || fail "stale idle home armed"
  pass "auto-arm: stale-owner recovery leaves the AFK and supervision-need gates unchanged"
}

test_resolves_outermost_claude_pid_in_nested_bgspare_chain() {
  local dir out status inner_pid lock_pid
  dir=$(make_primary_dir "$TMP_ROOT/nested-chain")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # A genuine multi-level contiguous claude-named ancestry: the hook fires
  # inside an inner fake-claude process (its recorded pid is distinct from its
  # own parent, a second, outer fake-claude process holding the session lock -
  # the bg-spare shape). Only the outer pid may own the lock; a
  # first-match-wins walk would resolve to the inner pid instead and leave the
  # hook inert. The inner process records its own pid before running the hook
  # so bash cannot tail-exec-collapse it into the outer pid, which would
  # collapse the two-hop chain this test depends on down to one hop.
  out=$(printf '%s\n' '{"session_id":"nested"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FAKE_CLAUDE" -c "
          printf \"%s\n\" \"\$\$\" > \"\$FM_HOME/state/inner-pid\"
          \"\$FM_HOME/bin/fm-claude-stop-autoarm.sh\"
        "
      ' 2>&1); status=$?
  inner_pid=$(cat "$dir/state/inner-pid" 2>/dev/null || true)
  lock_pid=$(cat "$dir/state/.lock" 2>/dev/null || true)
  [ -n "$inner_pid" ] && [ "$inner_pid" != "$lock_pid" ] \
    || fail "test setup did not produce a genuine two-hop claude chain: inner=$inner_pid lock=$lock_pid"
  expect_code 2 "$status" "a nested contiguous claude ancestry must resolve to the outer lock-owning pid and arm"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not resolve past the inner claude-named process to the outer lock owner"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "nested-chain arm must record outcome=rewake"
  pass "auto-arm: resolves the outermost pid of a nested contiguous claude ancestry (bg-spare chain)"
}

test_inert_when_fleet_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "idle state without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "idle state without positive recovery reset the attended alarm"
  pass "auto-arm: inert with nothing in flight and no X-mode need"
}

# --- the armed cycle ----------------------------------------------------------

test_actionable_close_rewakes_with_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable arm close must exit 2 so Claude rewakes"
  assert_contains "$out" "firstmate watcher wake" "rewake must carry the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "rewake must carry the arm's reason line"
  assert_contains "$out" "bin/fm-wake-drain.sh" "rewake must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "rewake must forbid a duplicate model re-arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the cycle"
  [ -e "$dir/state/arm-ran" ] || fail "hook never foregrounded the arm wrapper"
  pass "auto-arm: actionable close translates to exactly one exit-2 rewake with reason"
}

test_actionable_close_with_live_successor_rewakes_once() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/actionable-live-successor")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live successor for actionable close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  write_arm_fixture "$dir" benign-live
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?

  expect_code 2 "$status" "an actionable close must rewake when a live successor already exists"
  expect_code 0 "$status2" "a repeated non-actionable close with the live successor must stay quiet"
  [ "$(printf '%s\n' "$out" | grep -c '^firstmate watcher wake')" -eq 1 ] \
    || fail "actionable close with a live successor did not emit exactly one wake banner: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^stale: fixture-win actionable')" -eq 1 ] \
    || fail "actionable close with a live successor did not surface its reason exactly once: $out"
  [ -z "$out2" ] || fail "repeated hook duplicated the delivered actionable result: $out2"
  kill -0 "$pid" 2>/dev/null || fail "actionable delivery stopped or replaced the live successor"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "the later benign close must record outcome=clean"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "auto-arm: actionable close survives a healthy successor without duplicate delivery"
}

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "automatic supervision mechanism is broken" "failure rewake must describe the automatic mechanism failure"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "failure rewake must not create a manual arm loop"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "failure must exhaust exactly two bounded arm attempts"
  pass "auto-arm: bounded failure verification emits one automatic-mechanism alarm"
}

test_failed_cycles_notify_once_and_keep_retrying() {
  local dir out1 out2 status1 status2
  dir=$(make_primary_dir "$TMP_ROOT/failed-dedup")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out1=$(run_autoarm "$dir" 2>/dev/null); status1=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  expect_code 2 "$status1" "the first exhausted failure must notify"
  expect_code 2 "$status2" "a consecutive exhausted failure must force another Stop-owned retry"
  [ -n "$out1" ] || fail "the first exhausted failure did not notify"
  [ -z "$out2" ] || fail "consecutive exhausted failure repeated an operator notice: $out2"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 4 ] || fail "each cycle must retain bounded automatic retries"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "failure episode marker was not recorded"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "second failure must record failed-suppressed"
  pass "auto-arm: consecutive failures keep Stop-owned retry without repeating notice"
}

test_failure_notice_marker_write_refuses_delivery_and_retries() {
  local dir marker out1 out2 out3 status1 status2 status3 gen1 delivered
  dir=$(make_primary_dir "$TMP_ROOT/failed-marker-refusal")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  marker="$dir/state/.claude-autoarm-failure-notified"
  ln -s "$dir/state/missing/notice" "$marker"

  out1=$(run_autoarm "$dir" 2>/dev/null); status1=$?
  expect_code 0 "$status1" "an unrecordable failure notice must refuse delivery"
  [ -L "$marker" ] || fail "the failed marker write unexpectedly replaced its dangling symlink"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "the refused generation must leave its terminal ledger outcome"
  gen1=$(epoch_field "$dir" epoch)

  rm -f "$marker"
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  out3=$(run_autoarm "$dir" 2>/dev/null); status3=$?
  expect_code 2 "$status2" "a successor must retry and deliver after the marker path is restored"
  expect_code 2 "$status3" "a later failure must retain the Stop-owned retry"
  [ "$(epoch_field "$dir" epoch)" -gt "$gen1" ] || fail "the successor did not supersede the refused terminal entry"
  assert_present "$marker" "the successful successor did not record the failure notice"
  assert_contains "$out2" "automatic supervision mechanism is broken" "the successful successor did not deliver the failure notice"
  [ -z "$out3" ] || fail "the firing after the successful marker commit repeated the notice: $out3"
  delivered=$(printf '%s\n%s\n' "$out2" "$out3" | grep -c 'automatic supervision mechanism is broken' || true)
  [ "$delivered" -eq 1 ] || fail "the restored episode delivered $delivered failure notices instead of one"
  pass "auto-arm: marker-write refusal defers delivery until one successor commits the notice"
}

test_unverified_clean_close_exhausts_retries() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a non-actionable close without a healthy watcher must fail closed"
  assert_contains "$out" "automatic supervision mechanism is broken" "unverified close must report automatic failure"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "unverified close must exhaust exactly two bounded attempts"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  pass "auto-arm: unverified clean close exhausts retries and fails closed"
}

test_post_alarm_actionable_close_is_suppressed() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/post-alarm-actionable")
  : > "$dir/state/task.meta"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable result after attended fail-open must not continue"
  [ -z "$out" ] || fail "post-alarm actionable result produced continuation output: $out"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "post-alarm actionable result cleared the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "post-alarm actionable result cleared the attended alarm"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "post-alarm actionable result must record failed-suppressed"
  pass "auto-arm: post-alarm actionable outcomes cannot continue or reset failure state"
}

test_benign_cycle_end_with_live_watcher_is_silent() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/benign-live")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for benign close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a failed-looking cycle with a live fresh watcher must be benign"
  expect_code 0 "$status2" "the next Stop-owned cycle must remain benign with the live watcher"
  [ -z "$out" ] || fail "benign live cycle produced an operator notice: $out"
  [ -z "$out2" ] || fail "next benign live cycle produced an operator notice: $out2"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "benign live cycle must record outcome=clean, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "the next Stop-owned cycle must run its own bounded arm"
  [ ! -e "$dir/state/.turnend-claude-blocks" ] || fail "benign live cycle must clear the prior block budget"
  [ ! -e "$dir/state/.claude-autoarm-failure-notified" ] || fail "benign live cycle must not leave a failure-notice marker"
  [ ! -e "$dir/state/.claude-autoarm-failure-alarmed" ] || fail "benign live cycle must not leave an attended-alarm marker"
  pass "auto-arm: benign cycle end with a live watcher and fresh beacon stays silent across the next cycle"
}

test_positive_recovery_budget_contention_preserves_episode() {
  local dir out status pid identity holder
  dir=$(make_primary_dir "$TMP_ROOT/recovery-budget-contention")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for recovery contention"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.turnend-claude-blocks.lock"
  printf '%s\n' "$holder" > "$dir/state/.turnend-claude-blocks.lock/pid"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a healthy auto-arm must continue when the episode reset lock is busy"
  [ -z "$out" ] || fail "recovery contention produced an operator notice: $out"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "recovery contention must not record ordinary clean recovery"
  assert_present "$dir/state/.turnend-claude-blocks" "recovery contention partially cleared the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "recovery contention partially cleared the failure notice"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a later healthy auto-arm must complete the episode reset"
  assert_absent "$dir/state/.turnend-claude-blocks" "successful retry left the block budget"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "successful retry left the failure notice"
  pass "auto-arm: budget contention preserves the episode and forces a reset retry"
}

test_owner_mutex_contention_preserves_failure_episode_reset() {
  local dir out hook_pid status watcher watcher_id holder i
  dir=$(make_primary_dir "$TMP_ROOT/reset-owner-contention")
  : > "$dir/state/task.meta"
  : > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" reset-boundary
  sleep 60 &
  watcher=$!
  watcher_id=$(watcher_identity "$dir" "$watcher") || fail "could not identify reset-contention watcher"
  record_watcher_lock "$dir" "$watcher" "$watcher_id"
  touch "$dir/state/.last-watcher-beat"
  out="$dir/state/hook.out"
  run_autoarm_bg "$dir" "$out"
  hook_pid=$RUN_AUTOARM_BG_PID
  i=0
  while [ ! -e "$dir/state/arm-waiting" ]; do
    [ "$i" -lt 50 ] || fail "healthy owner never reached the reset boundary"
    sleep 0.05
    i=$((i + 1))
  done
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-autoarm.lock/pid"
  : > "$dir/state/arm-release"
  wait "$hook_pid"; status=$?
  expect_code 0 "$status" "owner-mutex contention at reset must close quietly"
  [ ! -s "$out" ] || fail "owner-mutex contention at reset produced output: $(cat "$out")"
  assert_present "$dir/state/.turnend-claude-blocks" "contended reset deleted the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "contended reset deleted the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "contended reset deleted the attended alarm"
  kill "$holder" "$watcher" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  rm -rf "$dir/state/.claude-autoarm.lock"
  pass "auto-arm: owner-mutex contention preserves successor episode state"
}

test_arms_for_x_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/x-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/x-watch.check.sh"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an X-mode relay poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the X-mode poll need"
  pass "auto-arm: X-mode poll need arms the cycle even with no tasks in flight"
}

test_arms_for_phone_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/phone-need")
  mkdir -p "$dir/config"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$dir/config/phone-mode.env"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/phone-watch.check.sh"
  write_arm_fixture "$dir" cadence-actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a Discord phone poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the Discord phone poll need"
  [ "$(cat "$dir/state/arm-cadence")" = 30 ] || fail "hook did not pass the Discord phone cadence to the arm"
  pass "auto-arm: Discord phone poll need arms at its configured cadence with no tasks in flight"
}

test_single_flight_admits_exactly_one_owner() {
  local dir rc1 rc2 count
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err1" &
    p1=$!
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    wait "$p1"; echo $? > "$FM_HOME/state/rc1"
    wait "$p2"; echo $? > "$FM_HOME/state/rc2"
  '
  rc1=$(cat "$dir/state/rc1")
  rc2=$(cat "$dir/state/rc2")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent firings must foreground exactly one arm, saw $count"
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "exactly one firing must translate the close (rc 2) and the other must no-op (rc 0), got rc1=$rc1 rc2=$rc2"
  pass "auto-arm: concurrent firings admit one owner and one rewake translation"
}

# --- abandoned single-flight claim recovery (legacy shim) ----------------------
# The 2026-08-14 lapse: one cycle armed, beat its beacon, delivered a single
# rewake, and exited, leaving its owner lock behind with a live pid. The single
# flight gate then turned every later firing into exit 0, so with two tasks in
# flight and a beacon 40 minutes cold nothing re-armed and both workers' reports
# sat unread until an operator drained the queue by hand. The lock alone is not
# enough to prove that: the ledger naming that same pid with a finished outcome,
# or a recorded pid-identity the live pid no longer matches, is what distinguishes
# an abandoned claim from one still deciding.
#
# These fixtures fabricate the LOCK-HOLDING claim shape a pre-generation build
# leaves behind, so this section pins the legacy shim: a live legacy owner
# still defers the gate, and an abandoned one is reclaimed once so the home
# re-arms - with an identity-verified live owner retired via TERM first, and
# an identityless one reclaimed without any signalling. The generation-claim
# section below pins the current contract.

# Fabricate a held owner lock: <dir> <pid> <role>. Plain-dir shape on purpose -
# the hook must reclaim whatever a crashed or blocked owner left behind.
record_autoarm_owner() {
  local dir=$1 pid=$2 role=${3:-autoarm}
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$pid" > "$dir/state/.claude-autoarm.lock/pid"
  printf '%s\n' "$role" > "$dir/state/.claude-autoarm.lock/role"
}

# Record the pid-identity a claim leaves inside its own lock: <dir> <pid>. The
# claim writes the identity of the process that took the lock, so passing a pid
# OTHER than the lock's own reproduces pid reuse - the recorded claimant is gone
# and an unrelated live process now answers to its number.
record_autoarm_owner_identity() {
  local dir=$1 pid=$2 identity
  identity=$(fm_test_pid_identity "$pid") || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" > "$dir/state/.claude-autoarm.lock/pid-identity"
}

# <dir> <epoch-seq> <owner-pid> <outcome>, aged well past any freshness window.
record_autoarm_epoch() {
  local dir=$1 seq=$2 owner=$3 outcome=$4
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=1\n' "$seq" "$owner" "$outcome" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
}

epoch_field() {
  local dir=$1 field=$2
  sed -n "s/^.*[[:space:]]\{0,1\}$field=\([A-Za-z0-9_-]*\).*\$/\1/p" \
    "$dir/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_abandoned_owner_claim_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/abandoned-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_epoch "$dir" 464 "$pid" rewake
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "an identityless abandoned owner must be reclaimed without being signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a claim whose ledger outcome is already terminal must be reclaimed, not deferred to forever"
  [ -e "$dir/state/arm-ran" ] || fail "abandoned claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "reclaimed cycle did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "reclaimed cycle did not record its own outcome: $(epoch_outcome "$dir")"
  [ "$(epoch_field "$dir" owner_pid)" != "$pid" ] || fail "reclaimed ledger still names the abandoned owner"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "reclaim left its serialization mutex behind"
  pass "auto-arm: an abandoned owner claim is reclaimed so a lapsed cycle re-arms"
}

test_arming_claim_with_fresh_beacon_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/arming-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # An owner foregrounds the arm for the whole watcher cycle, so an old "arming"
  # entry is still in progress while its watcher keeps beating the beacon.
  record_autoarm_epoch "$dir" 464 "$pid" arming
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a legacy claim still arming under a fresh beacon must keep the single-flight gate closed"
  [ -z "$out" ] || fail "deferring to an arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an arming claim was stolen and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the arming ledger entry"
  assert_present "$dir/state/.claude-autoarm.lock" "an arming claim lost its owner lock"
  pass "auto-arm: a legacy owner still arming is never reclaimed while its watcher keeps beating"
}

# The other legitimate legacy arming shape: a claim that JUST started arming
# after a real lapse, so the beacon is long stale but the entry is fresh. The
# arm's bounded startup window must never be stolen out from under it.
test_fresh_arming_claim_with_stale_beacon_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/fresh-arming-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=%s\n' "$pid" "$(date +%s)" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a freshly arming legacy claim must keep the single-flight gate closed even after a long lapse"
  [ -z "$out" ] || fail "deferring to a fresh arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a fresh arming claim was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "a fresh arming claim lost its owner lock"
  pass "auto-arm: a fresh legacy arming claim is never reclaimed while its startup window is still open"
}

test_claim_not_named_by_the_ledger_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/unnamed-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # A fresh claimant holds the lock before it writes "arming", so until it does
  # the ledger still names the PREVIOUS owner. Requiring the two pids to match is
  # what keeps that window from being mistaken for abandonment.
  record_autoarm_epoch "$dir" 464 999 rewake
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a live claim the ledger does not name is unproven and must be left alone"
  [ -z "$out" ] || fail "deferring to an unnamed claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a claim the ledger does not name was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "an unproven claim lost its owner lock"
  pass "auto-arm: a live claim the ledger does not name is never reclaimed"
}

# The same unrecoverable lapse, reached where the ledger cannot prove it: a session
# teardown kills the claim's whole process group before it records any outcome, so
# the entry still reads "arming" while the recorded pid is later handed to an
# unrelated live process. Only the identity the claim recorded inside its own lock
# separates that from a real arm in progress, so keep the beacon fresh here: this
# case must reclaim on the identity leg alone, not the stuck-arming leg. The
# reclaim must not signal the unrelated live process that inherited the number.
test_pid_reused_arming_claim_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/reused-pid-arming")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$$" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "the unrelated live process inheriting the number must never be signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a claim whose recorded identity no longer matches its live pid must be reclaimed, arming entry or not"
  [ -e "$dir/state/arm-ran" ] || fail "a reused-pid claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "reclaimed cycle did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "reclaim left its serialization mutex behind"
  pass "auto-arm: a claim whose pid was reused is reclaimed even while its ledger entry still reads arming"
}

# The other ledger-blind shape: no ledger at all (a fresh or hand-cleared home)
# plus a reused pid. Without the recorded identity nothing proves abandonment, so
# every later firing exits at the lock and the home never re-arms.
test_pid_reused_claim_with_no_ledger_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/reused-pid-no-ledger")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$$" || fail "could not record a claim pid-identity"
  assert_absent "$dir/state/.claude-autoarm-epoch" "this case must start with no ledger at all"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a reused-pid claim with no ledger to consult must still be reclaimed"
  [ -e "$dir/state/arm-ran" ] || fail "a reused-pid claim with no ledger left the home unarmed"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "reclaimed cycle did not record its own outcome: $(epoch_outcome "$dir")"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  pass "auto-arm: a reused-pid claim is reclaimed even with no ledger entry to prove it"
}

# The negative control for the identity leg: a claim whose recorded identity still
# matches the process holding the lock is genuinely in flight, so an arm that has
# legitimately been running for hours - its watcher beating the whole time - must
# keep the single-flight gate closed.
test_identity_matched_arming_claim_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/identity-matched-arming")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "an identity-matched claim still arming must keep the single-flight gate closed"
  [ -z "$out" ] || fail "deferring to an identity-matched arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an identity-matched arming claim was stolen and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the arming ledger entry"
  assert_present "$dir/state/.claude-autoarm.lock" "an identity-matched arming claim lost its owner lock"
  pass "auto-arm: an identity-matched owner still arming is never reclaimed"
}

test_terminal_check_claim_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/terminal-check-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  # The synchronous guard takes the same lock under its own role while it decides
  # the attended fail-open. Reclaiming that would race the guard's own decision.
  record_autoarm_owner "$dir" "$pid" terminal-check
  record_autoarm_epoch "$dir" 464 "$pid" failed-suppressed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "the guard's own terminal-check claim must never be reclaimed by the arm hook"
  [ -z "$out" ] || fail "deferring to a terminal-check claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a terminal-check claim was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "a terminal-check claim lost its owner lock"
  pass "auto-arm: the guard's terminal-check claim is never reclaimed"
}

# A proven-stuck legacy owner that is still ALIVE and identity-verified is
# retired with TERM before its lock is removed, because old-build code cannot
# re-check generations and would otherwise resume and act after supersession.
test_stuck_live_legacy_owner_is_retired_and_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/legacy-term")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a proven-stuck identity-verified live legacy owner must be retired and reclaimed"
  kill -0 "$pid" 2>/dev/null && fail "the stuck legacy owner was reclaimed without being retired"
  wait "$pid" 2>/dev/null || true
  [ -e "$dir/state/arm-ran" ] || fail "the reclaimed home did not re-arm"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaim left the legacy owner lock behind"
  pass "auto-arm: a stuck live legacy owner is retired via TERM and its lock reclaimed"
}

# The SIGSTOP counterfactual: a stopped legacy owner survives the bounded
# retirement wait with TERM queued, and the reclaim must proceed anyway - a
# pending TERM on the verified owner is retirement-safe because delivery
# precedes any further user code when the process continues.
test_stopped_legacy_owner_is_reclaimed_with_term_pending() {
  local dir out status pid i
  dir=$(make_primary_dir "$TMP_ROOT/legacy-term-stopped")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  kill -STOP "$pid" 2>/dev/null || fail "could not stop the legacy owner fixture"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a stopped legacy owner with TERM queued must not block the reclaim forever"
  [ -e "$dir/state/arm-ran" ] || fail "the reclaimed home did not re-arm past the stopped owner"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaim left the stopped owner's lock behind"
  kill -CONT "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 40 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && fail "the queued TERM did not retire the owner on continue"
  wait "$pid" 2>/dev/null || true
  pass "auto-arm: a SIGSTOPped legacy owner is reclaimed with TERM pending and dies on continue"
}

# --- generation claims: optimistic single-flight and supersession --------------
# The current claim is the two-line ledger entry itself (line 1 the classic
# epoch record, line 2 the owner's MANDATORY pid-identity); no lock is held
# across arming or output. A live open claim defers every firing; a stuck,
# dead, identity-mismatched, identityless, or finished claim is superseded by
# taking the next generation; a superseded owner goes completely silent.

# Fabricate a v2 generation claim: <dir> <gen> <owner-pid> <outcome>
# <identity-pid>. The identity of <identity-pid> is recorded as line 2 (the
# claim's own pid for a matched claim, another pid to reproduce pid reuse).
record_autoarm_v2_claim() {
  local dir=$1 gen=$2 owner=$3 outcome=$4 identity_pid=$5 identity
  identity=$(fm_test_pid_identity "$identity_pid") || return 1
  [ -n "$identity" ] || return 1
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=1\n%s\n' \
    "$gen" "$owner" "$outcome" "$identity" > "$dir/state/.claude-autoarm-epoch"
}

# A live open generation claim needs no lock to keep the gate closed: the
# ledger alone defers a concurrent firing, however old the entry, while the
# watcher keeps beating the beacon.
test_open_generation_claim_defers_without_any_lock() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-open-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_v2_claim "$dir" 464 "$pid" arming "$pid" || fail "could not record a v2 claim"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  assert_absent "$dir/state/.claude-autoarm.lock" "this case must start with no owner lock at all"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a live open generation claim must keep the single-flight gate closed with no lock held"
  [ -z "$out" ] || fail "deferring to an open generation claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an open generation claim was superseded and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the open claim's ledger entry"
  pass "auto-arm: a live open generation claim defers concurrent firings with no lock held"
}

# The 2026-08-26 watcher flap in the generation model: a live, identity-matched
# owner whose ledger entry and watcher beacon are both older than grace is
# stuck, and the next firing supersedes it by taking the next generation.
test_stuck_generation_claim_is_superseded_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-stuck-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_v2_claim "$dir" 464 "$pid" arming "$pid" || fail "could not record a v2 claim"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a live owner stuck arming past grace with a beacon just as stale must be superseded, not deferred to forever"
  [ -e "$dir/state/arm-ran" ] || fail "a stuck generation claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the superseding generation must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "superseding claim did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  [ "$(epoch_field "$dir" owner_pid)" != "$pid" ] || fail "superseding claim left the stuck owner on the ledger"
  assert_absent "$dir/state/.claude-autoarm.lock" "the generation claim left a lock held after finishing"
  pass "auto-arm: a hung generation owner with no watcher beat is superseded so re-arming self-heals"
}

# Identity is mandatory at read time: a bare identityless one-line arming
# ledger naming an unrelated live pid is NOT an open claim - it must neither
# defer the hook nor survive as the current entry, whatever the beacon says.
test_identityless_ledger_never_defers() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-identityless-ledger")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=1\n' "$pid" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "the unrelated live pid on an identityless ledger must never be signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "an identityless arming ledger must be superseded, never deferred to"
  [ -e "$dir/state/arm-ran" ] || fail "an identityless ledger left the home unarmed"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "the identityless entry was not superseded: $(epoch_field "$dir" epoch)"
  pass "auto-arm: an identityless arming ledger never defers the gate (reused-pid loophole closed)"
}

# A superseded owner must not start or attach another watcher: when its claim
# is superseded between arm attempts, the retry boundary goes silent instead
# of invoking the arm again.
test_superseded_owner_never_reinvokes_the_arm() {
  local dir out status count
  dir=$(make_primary_dir "$TMP_ROOT/v2-superseded-arm-boundary")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" supersede-then-fail
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an owner superseded between arm attempts must exit 0 silently"
  [ -z "$out" ] || fail "a superseded owner produced output at the arm boundary: $out"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "a superseded owner re-invoked the arm, saw $count arms"
  [ "$(epoch_field "$dir" epoch)" = 999 ] || fail "a superseded owner rewrote its successor's ledger entry: $(epoch_field "$dir" epoch)"
  pass "auto-arm: a superseded owner never re-invokes the arm and leaves its successor's claim untouched"
}

# End-to-end regression for all three concurrency edge classes at once, with a
# REAL hook process hung mid-arm:
#   1. no mutex across blocking steps - while owner A is mid-arm, a concurrent
#      firing B defers promptly instead of queueing on any lock;
#   2. stuck-owner supersession - once A's claim and the beacon age past grace
#      while A is still alive arming, firing C takes the next generation and
#      translates its own close (exit 2);
#   3. no double-translation - when A's arm finally returns, A finds itself
#      superseded and goes completely silent (exit 0, no banner, no ledger
#      write), so one supersession episode produces exactly one translation.
test_superseded_owner_goes_silent_and_never_double_translates() {
  local dir a_out a_pid b_out b_status c_out c_status a_status i count
  dir=$(make_primary_dir "$TMP_ROOT/v2-superseded-silence")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" blocking-actionable
  a_out="$dir/state/a.out"
  run_autoarm_bg "$dir" "$a_out"
  a_pid=$RUN_AUTOARM_BG_PID
  i=0
  while [ "$(epoch_outcome "$dir")" != arming ] || [ ! -e "$dir/state/arm-ran" ]; do
    [ "$i" -lt 50 ] || fail "owner A never published its arming claim"
    sleep 0.1
    i=$((i + 1))
  done
  b_out=$(run_autoarm "$dir" 2>/dev/null); b_status=$?
  expect_code 0 "$b_status" "a firing during a live open claim must defer promptly (no mutex is held across arming)"
  [ -z "$b_out" ] || fail "deferring firing produced output: $b_out"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "deferring firing must not arm, saw $count arms"
  # A is still alive mid-arm; make its claim stuck-shaped.
  kill -0 "$a_pid" 2>/dev/null || fail "owner A finished before the supersession could be exercised"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  c_out=$(run_autoarm "$dir" 2>/dev/null); c_status=$?
  expect_code 2 "$c_status" "the superseding generation must translate its own close"
  assert_contains "$c_out" "firstmate watcher wake" "the superseding generation must carry the rewake banner"
  wait "$a_pid"
  a_status=$?
  expect_code 0 "$a_status" "the superseded owner must exit 0 instead of double-translating"
  [ ! -s "$a_out" ] || fail "the superseded owner emitted output after losing its generation: $(cat "$a_out")"
  [ "$(epoch_field "$dir" epoch)" = 2 ] || fail "the superseded owner advanced the ledger past its successor: $(epoch_field "$dir" epoch)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the superseding generation's outcome was overwritten: $(epoch_outcome "$dir")"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "expected exactly the owner and superseder arms, saw $count"
  pass "auto-arm: a superseded owner goes silent - one supersession episode, one translation, no held mutex"
}

test_need_vanished_mid_cycle_closes_quietly() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/vanished")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" meta-vanishes
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable close after the fleet went idle must not rewake"
  [ -z "$out" ] || fail "vanished-need close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: need vanishing mid-cycle closes without a rewake"
}

test_afk_mid_cycle_suppresses_rewake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK appearing mid-cycle must suppress the primary rewake"
  [ -z "$out" ] || fail "AFK-suppressed close produced output: $out"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "epoch must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "auto-arm: mid-cycle AFK hands triage to the daemon with no rewake"
}

test_active_in_marked_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a marked secondmate home must get the same active auto-arm as the main primary"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a marked secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate epoch must record outcome=rewake"
  pass "auto-arm: active in a marked secondmate home"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

test_fm_lock_reclaims_a_live_shared_daemon_owner() {
  local dir daemon_pid out status
  dir="$TMP_ROOT/lock-daemon-owner"
  mkdir -p "$dir/state"
  # Session start must not be refused by a lock recorded against the shared
  # daemon. Because the daemon outlives every session, refusing here left the
  # home read-only until someone deleted the lock by hand.
  daemon_pid=$(start_fake_claude_daemon)
  printf '%s\n' "$daemon_pid" > "$dir/state/.lock"
  # The trailing exit keeps this a multi-command body so bash cannot
  # tail-exec-collapse the fake harness away from the ancestry walk.
  out=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c 'bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"' _ "$ROOT" 2>&1); status=$?
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  expect_code 0 "$status" "fm-lock.sh must reclaim a lock recorded against the shared daemon: $out"
  assert_contains "$out" "lock acquired" "fm-lock.sh must report acquisition after reclaiming a shared-daemon lock"
  [ "$(cat "$dir/state/.lock")" != "$daemon_pid" ] \
    || fail "fm-lock.sh left the shared daemon recorded as the session owner"
  out=$(FM_HOME="$dir" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock:" "fm-lock.sh status must still report a holder line"
  pass "fm-lock: a lock recorded against the shared daemon is reclaimable, not a permanent refusal"
}

test_fm_lock_records_and_clears_session_identity() {
  local dir sid out
  sid='44444444-4444-4444-4444-444444444444'
  dir="$TMP_ROOT/lock-sid-record"
  mkdir -p "$dir/state"
  # The pid-matched env pair Claude Code plants in every tool shell records the
  # session id beside the pid, so a later fork/relaunch successor can prove
  # same-session succession.
  out=$(FM_HOME="$dir" CLAUDE_CODE_SESSION_ID="$sid" "$FAKE_CLAUDE" -c 'CLAUDE_PID=$$ bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"' _ "$ROOT" 2>&1) \
    || fail "sid-recording acquisition failed: $out"
  assert_contains "$out" "session $sid" "acquisition must report the recorded session id"
  [ "$(cat "$dir/state/.lock-session")" = "$sid" ] || fail "sidecar does not hold the session id"
  out=$(FM_HOME="$dir" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "session $sid" "status must report the recorded session id"
  # An acquisition that cannot resolve its own id must clear the previous
  # owner's identity rather than let a third session match against it.
  printf '9999999\n' > "$dir/state/.lock"
  out=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c 'bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"' _ "$ROOT" 2>&1) \
    || fail "sid-less reacquisition failed: $out"
  [ ! -e "$dir/state/.lock-session" ] || fail "a sid-less owner inherited the previous session id"
  pass "fm-lock: the session-id sidecar is recorded from the trusted env pair and cleared on sid-less acquisition"
}

test_fm_lock_reconciles_same_pid_session_identity() {
  local dir sid foreign out status
  sid='45454545-4545-4545-4545-454545454545'
  foreign='46464646-4646-4646-4646-464646464646'
  dir="$TMP_ROOT/lock-same-pid-sidecar"
  mkdir -p "$dir/state"
  out=$(FM_HOME="$dir" FM_TEST_SID="$sid" FM_TEST_FOREIGN_SID="$foreign" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      rm -f "$FM_HOME/state/.lock-session"
      FM_CLAUDE_SESSION_ID_HINT="$FM_TEST_SID" bash "$1/bin/fm-lock.sh" || exit 70
      cat "$FM_HOME/state/.lock-session" > "$FM_HOME/state/backfilled" || exit 71
      printf "%s\n" "$FM_TEST_FOREIGN_SID" > "$FM_HOME/state/.lock-session"
      FM_CLAUDE_SESSION_ID_HINT="$FM_TEST_SID" bash "$1/bin/fm-lock.sh" || exit 72
    ' _ "$ROOT" 2>&1); status=$?
  expect_code 0 "$status" "same-pid reacquisition must reconcile its session sidecar: $out"
  [ "$(cat "$dir/state/backfilled")" = "$sid" ] || fail "same-pid reacquisition did not backfill a missing sidecar"
  [ "$(cat "$dir/state/.lock-session")" = "$sid" ] || fail "same-pid reacquisition preserved a foreign sidecar"
  pass "fm-lock: same-pid reacquisition backfills or replaces its session identity"
}

test_fm_lock_same_session_rekey_and_foreign_refusal() {
  local dir sid other out status
  sid='55555555-5555-5555-5555-555555555555'
  dir="$TMP_ROOT/lock-rekey"
  mkdir -p "$dir/state"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  printf '%s\n' "$sid" > "$dir/state/.lock-session"
  # A different session id refuses exactly like today, now naming the holder.
  out=$(FM_HOME="$dir" FM_CLAUDE_SESSION_ID_HINT='66666666-6666-6666-6666-666666666666' \
    "$FAKE_CLAUDE" -c 'bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"' _ "$ROOT" 2>&1); status=$?
  expect_code 1 "$status" "a live holder from another session must still refuse acquisition"
  assert_contains "$out" "another live firstmate session holds the lock" "the refusal must keep its established error text"
  assert_contains "$out" "session $sid" "the refusal must name the holder's recorded session"
  [ "$(cat "$dir/state/.lock")" = "$other" ] || fail "a refused acquisition mutated the lock"
  # The same session id re-keys the pid while the pre-fork process still lives:
  # the same logical session is by definition not a competing session.
  out=$(FM_HOME="$dir" FM_CLAUDE_SESSION_ID_HINT="$sid" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
      bash "$1/bin/fm-lock.sh"
    ' _ "$ROOT" 2>&1); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "a same-session successor must re-key over its own live pre-fork process: $out"
  [ "$(cat "$dir/state/.lock")" = "$(cat "$dir/state/expected-owner")" ] || fail "re-key did not record the successor pid"
  [ "$(cat "$dir/state/.lock-session")" = "$sid" ] || fail "re-key lost the session id"
  pass "fm-lock: same-session succession re-keys a live holder while a foreign session still refuses"
}

test_fm_lock_foreign_refusal_names_fork_lineage() {
  local dir sid other out status
  sid='77777777-7777-7777-7777-777777777777'
  dir="$TMP_ROOT/lock-lineage"
  mkdir -p "$dir/state"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  printf '%s\n' "$sid" > "$dir/state/.lock-session"
  # The acquiring process's own argv carries the fork evidence Claude Code puts
  # there (--fork-session plus the recorded session id in the --resume target),
  # which is diagnostic wording only: the refusal stands, and it tells the
  # captain the one action that hands the home over safely.
  out=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c 'bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"' _ "$ROOT" --fork-session --resume "$sid" 2>&1); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 1 "$status" "fork lineage alone must never take over a live holder"
  assert_contains "$out" "forked from the lock-holding session" "the refusal must surface the fork lineage"
  assert_contains "$out" "exit it (or close its terminal)" "the refusal must name the recovery action"
  [ "$(cat "$dir/state/.lock")" = "$other" ] || fail "fork lineage mutated the lock despite the live holder"
  pass "fm-lock: a fork-lineage successor is refused loudly with the exact recovery action"
}

test_inert_in_child_worktree
test_inert_without_session_lock
test_reclaims_stale_session_lock_before_arming
test_reclaims_live_daemon_owner_before_arming
test_foreign_live_owner_notifies_once_without_arm_or_reclaim
test_foreign_owner_notice_respects_afk_and_need_gates
test_same_session_successor_rekeys_and_arms
test_fork_successor_gets_notice_then_reclaims_when_holder_exits
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_resolves_outermost_claude_pid_in_nested_bgspare_chain
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_actionable_close_with_live_successor_rewakes_once
test_failed_close_rewakes_with_failure_banner
test_failed_cycles_notify_once_and_keep_retrying
test_failure_notice_marker_write_refuses_delivery_and_retries
test_unverified_clean_close_exhausts_retries
test_post_alarm_actionable_close_is_suppressed
test_benign_cycle_end_with_live_watcher_is_silent
test_positive_recovery_budget_contention_preserves_episode
test_owner_mutex_contention_preserves_failure_episode_reset
test_arms_for_x_mode_poll_need_without_inflight
test_arms_for_phone_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_abandoned_owner_claim_is_reclaimed_and_rearms
test_arming_claim_with_fresh_beacon_is_never_reclaimed
test_fresh_arming_claim_with_stale_beacon_is_never_reclaimed
test_claim_not_named_by_the_ledger_is_never_reclaimed
test_pid_reused_arming_claim_is_reclaimed_and_rearms
test_pid_reused_claim_with_no_ledger_is_reclaimed_and_rearms
test_identity_matched_arming_claim_is_never_reclaimed
test_terminal_check_claim_is_never_reclaimed
test_stuck_live_legacy_owner_is_retired_and_reclaimed
test_stopped_legacy_owner_is_reclaimed_with_term_pending
test_open_generation_claim_defers_without_any_lock
test_stuck_generation_claim_is_superseded_and_rearms
test_identityless_ledger_never_defers
test_superseded_owner_never_reinvokes_the_arm
test_superseded_owner_goes_silent_and_never_double_translates
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_fm_lock_status_still_works_with_shared_lib
test_fm_lock_reclaims_a_live_shared_daemon_owner
test_fm_lock_records_and_clears_session_identity
test_fm_lock_reconciles_same_pid_session_identity
test_fm_lock_same_session_rekey_and_foreign_refusal
test_fm_lock_foreign_refusal_names_fork_lineage

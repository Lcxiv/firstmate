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
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
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
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
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
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
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

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "watcher cycle FAILED" "failure rewake must carry the failure banner"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_contains "$out" "repair supervision" "failure rewake must direct the manual repair"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: watcher: FAILED translates to an exit-2 alarm rewake"
}

test_clean_close_exits_silently() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a clean arm close with no actionable reason must not rewake"
  [ -z "$out" ] || fail "clean close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: clean close exits silently with a clean epoch"
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
test_failed_close_rewakes_with_failure_banner
test_clean_close_exits_silently
test_arms_for_x_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_fm_lock_status_still_works_with_shared_lib
test_fm_lock_reclaims_a_live_shared_daemon_owner
test_fm_lock_records_and_clears_session_identity
test_fm_lock_same_session_rekey_and_foreign_refusal
test_fm_lock_foreign_refusal_names_fork_lineage

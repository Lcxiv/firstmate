#!/usr/bin/env bash
# Behavior tests for the supervision handoff that never arrives.
#
# Watcher continuity for a Claude primary is triggered ONLY by a turn end
# (bin/fm-claude-stop-autoarm.sh), and so is the turn-end guard that would
# otherwise catch a blind stop. A turn that is cut short rather than completed
# runs no Stop hooks, and such a session then stops producing turn ends at all,
# so the auto-arm is never invoked, its ledger freezes on a TERMINAL outcome,
# and nothing downstream of a turn end can recover it.
#
# These tests pin three things: the auto-arm does NOT stop claiming while its
# preconditions hold (so a frozen ledger can only mean it was never invoked),
# the overdue predicate separates that state from the ordinary between-cycles
# one, and the PreToolUse notice reaches the model on a trigger the Stop failure
# cannot seal.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-handoff)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

PRETOOL="$ROOT/bin/fm-supervision-pretool-check.sh"
TURNEND="$ROOT/bin/fm-turnend-guard.sh"
ANCIENT=202001010000

# A genuine primary home: plain checkout, AGENTS.md, bin/, state/.
make_home() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  fm_write_meta "$dir/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

# The shape the auto-arm leaves behind when it hands off and expects the next
# turn end to pick the work up.
record_handoff() {
  local dir=$1 outcome=${2:-rewake}
  printf 'epoch=13 owner_pid=%s outcome=%s updated_at=%s\nfixture-identity\n' \
    "$$" "$outcome" "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
}

# Age every trace of supervision: the handoff, the last cycle's beacon, and any
# record that this session was taking turns.
park_session() {
  local dir=$1
  touch -t "$ANCIENT" "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  touch -t "$ANCIENT" "$dir/state/.last-watcher-beat"
  rm -f "$dir/state/.session-activity"
}

# Sets PRETOOL_OUT and PRETOOL_RC in the caller's shell: a command
# substitution would run this in a subshell and lose the exit status, which is
# half of what these tests assert.
run_pretool() {
  local dir=$1 rc=0
  PRETOOL_OUT=$(printf '%s\n' '{"session_id":"sess-handoff","tool_name":"Bash","tool_input":{"command":"true"}}' \
    | FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" "$PRETOOL" --claude 2>/dev/null) || rc=$?
  PRETOOL_RC=$rc
  return 0
}

overdue_verdict() {
  local dir=$1
  FM_HOME="$dir" bash -c '
    . "$1"/bin/fm-supervision-lib.sh
    fm_supervision_handoff_status "$2/state" 300
    printf "%s %s\n" "$FM_SUP_HANDOFF_OVERDUE" "$FM_SUP_HANDOFF_AGE"
  ' _ "$ROOT" "$dir"
}

# --- the state the report called "stopped claiming" --------------------------

# The auto-arm takes a NEW generation on every firing while its preconditions
# hold. It has no path that declines to claim and leaves the ledger untouched,
# so a ledger frozen on a terminal outcome is proof the hook never ran - not
# proof that it ran and refused.
test_autoarm_claims_a_new_generation_on_every_firing() {
  local dir gens prev
  dir=$(make_home autoarm-claims)
  for f in fm-claude-stop-autoarm.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
    fm-wake-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh fm-lock.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture actionable\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"

  gens=""
  for _ in 1 2 3 4 5; do
    printf '%s\n' '{"session_id":"11111111-2222-3333-4444-555555555555","stop_hook_active":false}' \
      | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
          printf "%s\n" "$$" > "$FM_HOME/state/.lock"
          "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1
        ' >/dev/null 2>&1
    gens="$gens$(sed -n '1s/^epoch=\([0-9][0-9]*\) .*/\1/p' "$dir/state/.claude-autoarm-epoch") "
  done

  prev=0
  for g in $gens; do
    [ "$g" -gt "$prev" ] || fail "auto-arm stopped claiming while its preconditions held: generations were '$gens'"
    prev=$g
  done
  pass "auto-arm takes a new generation on every firing while preconditions hold"
}

# --- the predicate that separates the two shapes -----------------------------

test_fresh_handoff_between_turns_is_not_overdue() {
  local dir verdict
  dir=$(make_home fresh-handoff)
  record_handoff "$dir"
  : > "$dir/state/.last-watcher-beat"
  touch -t "$ANCIENT" "$dir/state/.last-watcher-beat"
  rm -f "$dir/state/.session-activity"
  verdict=$(overdue_verdict "$dir")
  assert_contains "$verdict" "false" "a handoff seconds old is the ordinary between-cycles shape, not a lapse"
  pass "a fresh handoff with no running cycle is not overdue"
}

test_active_session_mid_turn_is_not_overdue() {
  local dir verdict
  dir=$(make_home active-session)
  record_handoff "$dir"
  park_session "$dir"
  # The session is working: it just took a step.
  : > "$dir/state/.session-activity"
  verdict=$(overdue_verdict "$dir")
  assert_contains "$verdict" "false" "a session still taking steps has a turn end coming that will arm the next cycle"
  pass "a long turn with a stale beacon is not overdue while the session is active"
}

test_parked_session_is_overdue() {
  local dir verdict
  dir=$(make_home parked-session)
  record_handoff "$dir"
  park_session "$dir"
  verdict=$(overdue_verdict "$dir")
  assert_contains "$verdict" "true" "an old handoff with no cycle and no session activity is the unrecoverable state"
  pass "a parked session with an abandoned handoff is overdue"
}

test_idle_home_is_never_overdue() {
  local dir verdict
  dir=$(make_home idle-home)
  record_handoff "$dir"
  park_session "$dir"
  rm -f "$dir/state/task.meta"
  verdict=$(overdue_verdict "$dir")
  assert_contains "$verdict" "false" "an idle home has nothing to supervise"
  pass "a home with no work in flight is never overdue"
}

test_live_arming_claim_is_not_overdue() {
  local dir verdict
  dir=$(make_home live-arming)
  # A claim still arming, owned by a live process, belongs to the auto-arm's own
  # generation contract rather than to this predicate.
  printf 'epoch=13 owner_pid=%s outcome=arming updated_at=%s\nfixture-identity\n' \
    "$$" "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  park_session "$dir"
  verdict=$(overdue_verdict "$dir")
  assert_contains "$verdict" "false" "a live arming claim is a handoff in progress"
  pass "a live arming claim is not treated as an abandoned handoff"
}

test_abandoned_arming_claim_is_overdue() {
  local dir verdict dead
  dir=$(make_home abandoned-arming)
  dead=$(bash -c 'echo $$')
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf 'epoch=13 owner_pid=%s outcome=arming updated_at=%s\nfixture-identity\n' \
    "$dead" "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  park_session "$dir"
  verdict=$(overdue_verdict "$dir")
  assert_contains "$verdict" "true" "a claim whose owner is gone is as abandoned as a terminal one"
  pass "an arming claim with a dead owner is overdue"
}

test_home_that_never_ran_the_autoarm_is_not_overdue() {
  local dir verdict
  dir=$(make_home no-ledger)
  : > "$dir/state/.last-watcher-beat"
  touch -t "$ANCIENT" "$dir/state/.last-watcher-beat"
  verdict=$(overdue_verdict "$dir")
  assert_contains "$verdict" "false" "no ledger means no handoff was ever expected here"
  pass "a home with no auto-arm ledger reports no overdue handoff"
}

# --- the notice on a trigger the Stop failure cannot seal --------------------

test_pretool_is_silent_while_supervision_is_healthy() {
  local dir out
  dir=$(make_home pretool-healthy)
  record_handoff "$dir"
  : > "$dir/state/.last-watcher-beat"
  run_pretool "$dir"; out=$PRETOOL_OUT
  expect_code 0 "$PRETOOL_RC" "the notice must never fail a tool call"
  [ -z "$out" ] || fail "expected silence while a cycle is running, got: $out"
  pass "the pre-tool notice is silent while supervision is healthy"
}

test_pretool_reports_the_unrecoverable_state() {
  local dir out context
  dir=$(make_home pretool-parked)
  record_handoff "$dir"
  park_session "$dir"
  run_pretool "$dir"; out=$PRETOOL_OUT
  expect_code 0 "$PRETOOL_RC" "the notice must never deny the tool call that carries it"
  assert_contains "$out" "SUPERVISION IS OFF" "the notice must name the condition"
  assert_contains "$out" "1 task(s) in flight" "the notice must name what is unsupervised"
  assert_contains "$out" "cannot recover on its own" "the notice must say waiting will not help"
  assert_contains "$out" "systemMessage" "an attending operator must still see the notice"
  assert_contains "$out" '"hookEventName":"PreToolUse"' "the model-facing channel must name its hook event"
  assert_contains "$out" '"additionalContext":"' "the notice must reach the model, not only the operator UI"
  context=$(printf '%s\n' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  [ -n "$context" ] && [ "$context" != null ] || fail "additionalContext must parse as a string, got: $out"
  assert_contains "$context" "SUPERVISION IS OFF" "the model-facing text must name the condition"
  assert_contains "$context" "Repair supervision" "the model-facing text must name the repair step"
  assert_not_contains "$out" "permissionDecision" "the notice must never carry a permission decision"
  pass "the pre-tool notice reports an abandoned handoff on both channels without blocking the call"
}

test_pretool_speaks_once_per_episode() {
  local dir first second
  dir=$(make_home pretool-once)
  record_handoff "$dir"
  park_session "$dir"
  run_pretool "$dir"; first=$PRETOOL_OUT
  assert_contains "$first" "SUPERVISION IS OFF" "the first call must speak"
  # The ledger and beacon are still ancient; only the activity record the first
  # call refreshed keeps the next call in the same episode quiet.
  run_pretool "$dir"; second=$PRETOOL_OUT
  [ -z "$second" ] || fail "the same episode must not be announced twice, got: $second"
  pass "the pre-tool notice speaks once per handoff episode"
}

test_pretool_speaks_again_after_a_fresh_park() {
  local dir first second third
  dir=$(make_home pretool-new-episode)
  record_handoff "$dir"
  park_session "$dir"
  run_pretool "$dir"; first=$PRETOOL_OUT
  assert_contains "$first" "SUPERVISION IS OFF" "the first park must speak"
  run_pretool "$dir"; second=$PRETOOL_OUT
  [ -z "$second" ] || fail "a session still taking steps must not be told twice, got: $second"
  # The session went a whole window without a step again on the SAME ledger
  # entry: nothing armed in between, so it is blind again and must hear it.
  touch -t "$ANCIENT" "$dir/state/.session-activity"
  run_pretool "$dir"; third=$PRETOOL_OUT
  assert_contains "$third" "SUPERVISION IS OFF" "a session that parks again must be told again"
  pass "the pre-tool notice speaks again after a fresh park"
}

test_pretool_records_session_activity() {
  local dir
  dir=$(make_home pretool-activity)
  record_handoff "$dir"
  assert_absent "$dir/state/.session-activity" "fixture should start with no activity record"
  run_pretool "$dir"
  assert_present "$dir/state/.session-activity" "a tool call is what proves the session is taking steps"
  pass "the pre-tool check keeps the session-activity record current"
}

test_pretool_recovery_path_goes_quiet_once_a_cycle_is_armed() {
  local dir out
  dir=$(make_home pretool-recovery)
  record_handoff "$dir"
  park_session "$dir"
  run_pretool "$dir"; out=$PRETOOL_OUT
  assert_contains "$out" "SUPERVISION IS OFF" "the blind state must be announced"
  # The model repaired supervision: a watcher is beating again.
  : > "$dir/state/.last-watcher-beat"
  touch -t "$ANCIENT" "$dir/state/.session-activity"
  run_pretool "$dir"; out=$PRETOOL_OUT
  [ -z "$out" ] || fail "a repaired home must go quiet, got: $out"
  pass "the notice stops once a cycle is armed again"
}

test_pretool_is_inert_under_away_mode() {
  local dir out
  dir=$(make_home pretool-afk)
  record_handoff "$dir"
  park_session "$dir"
  : > "$dir/state/.afk"
  run_pretool "$dir"; out=$PRETOOL_OUT
  expect_code 0 "$PRETOOL_RC" "away mode must not fail the call"
  [ -z "$out" ] || fail "the away daemon owns supervision; the notice must not speak over it, got: $out"
  pass "the pre-tool notice stands down under away mode"
}

test_pretool_is_inert_in_a_task_worktree() {
  local base dir out
  base=$(make_home pretool-base)
  dir="$TMP_ROOT/pretool-worktree"
  fm_git_worktree "$base" "$dir" fm/handoff-test-branch
  mkdir -p "$dir/state" "$dir/bin"
  : > "$dir/AGENTS.md"
  fm_write_meta "$dir/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  record_handoff "$dir"
  park_session "$dir"
  run_pretool "$dir"; out=$PRETOOL_OUT
  expect_code 0 "$PRETOOL_RC" "a crew worktree must not fail the call"
  [ -z "$out" ] || fail "a crew worktree has no supervision to lose, got: $out"
  pass "the pre-tool notice stays inert inside a task worktree"
}

# --- the turn-end banner stays worth reading ---------------------------------

# Same contract as run_pretool: TURNEND_OUT and TURNEND_RC in the caller.
run_turnend() {
  local dir=$1 rc=0
  TURNEND_OUT=$(printf '%s\n' '{"session_id":"sess-handoff","stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
      FM_CLAUDE_AUTOARM_EPOCH_FRESH=1 "$TURNEND" --claude 2>&1) || rc=$?
  TURNEND_RC=$rc
  return 0
}

test_turnend_banner_names_an_abandoned_handoff() {
  local dir out
  dir=$(make_home turnend-parked)
  record_handoff "$dir"
  park_session "$dir"
  run_turnend "$dir"; out=$TURNEND_OUT
  expect_code 2 "$TURNEND_RC" "a blind stop must still be refused"
  assert_contains "$out" "Nothing has armed a watcher for" "the banner must say how long continuity has been stopped"
  assert_contains "$out" "runs only at a turn end" "the banner must say what the re-arm depends on"
  pass "the turn-end banner names an abandoned handoff"
}

test_turnend_banner_omits_the_lapse_line_between_cycles() {
  local dir out
  dir=$(make_home turnend-between)
  record_handoff "$dir"
  : > "$dir/state/.last-watcher-beat"
  touch -t "$ANCIENT" "$dir/state/.last-watcher-beat"
  : > "$dir/state/.session-activity"
  # Past the guard's own "this very Stop just handed off" window, but nowhere
  # near the handoff window: the ordinary shape of a stop between two cycles.
  sleep 2
  run_turnend "$dir"; out=$TURNEND_OUT
  expect_code 2 "$TURNEND_RC" "a blind stop is still refused"
  assert_not_contains "$out" "Nothing has armed a watcher for" \
    "an ordinary between-cycles stop must not be dressed up as stopped continuity"
  pass "the turn-end banner does not claim a lapse between ordinary cycles"
}

# Pin the supervision model and the primary harness rather than letting the
# host runner's ancestry pick them: the handoff lines belong to the auto-arm
# model, and the ledger-derived ones to a Claude primary only.
run_guard() {
  local dir=$1 model=${2:-autoarm} harness=${3:-claude} rc=0
  local -a marker
  case "$harness" in
    cursor) marker=(CURSOR_AGENT=1) ;;
    *) marker=(CLAUDECODE=1) ;;
  esac
  GUARD_OUT=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE "${marker[@]}" \
    FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_SUPERVISION_MODEL="$model" "$ROOT/bin/fm-guard.sh" 2>&1) || rc=$?
  GUARD_RC=$rc
  return 0
}

test_guard_warning_names_the_unrecoverable_state() {
  local dir out
  dir=$(make_home guard-parked)
  record_handoff "$dir"
  park_session "$dir"
  run_guard "$dir"; out=$GUARD_OUT
  assert_contains "$out" "WATCHER DOWN" "the guard must still alarm"
  assert_contains "$out" "Nothing has armed a watcher for" "the guard must say how long nothing has armed"
  assert_contains "$out" "cannot recover on its own" "the guard must say waiting will not help"
  pass "the watcher-down warning names the unrecoverable state"
}

test_guard_warning_does_not_cry_lapse_between_cycles() {
  local dir out
  dir=$(make_home guard-between)
  record_handoff "$dir"
  : > "$dir/state/.last-watcher-beat"
  touch -t "$ANCIENT" "$dir/state/.last-watcher-beat"
  : > "$dir/state/.session-activity"
  run_guard "$dir"; out=$GUARD_OUT
  assert_contains "$out" "WATCHER DOWN" "the guard still reports that no cycle is running"
  assert_not_contains "$out" "Nothing has armed a watcher for" \
    "an ordinary gap between cycles must not be reported as stopped continuity"
  assert_contains "$out" "the next turn end arms one" "the guard must say why this gap is ordinary"
  pass "the watcher-down warning separates an ordinary gap from a lapse"
}

# The ledger is never removed, so a home that once ran under Claude and was
# re-spawned under a persistent-watcher harness still carries it; the guard must
# not read a Claude-specific diagnosis into that home.
test_guard_warning_keeps_handoff_lines_to_the_autoarm_model() {
  local dir out
  dir=$(make_home guard-persistent)
  record_handoff "$dir"
  park_session "$dir"
  run_guard "$dir" persistent; out=$GUARD_OUT
  assert_contains "$out" "WATCHER DOWN" "the guard must still alarm under a persistent model"
  assert_not_contains "$out" "Nothing has armed a watcher for" \
    "a stale Claude ledger must not be diagnosed in a persistent-watcher home"
  assert_not_contains "$out" "cannot recover on its own" \
    "the Claude turn-end diagnosis must not reach a persistent-watcher home"
  assert_not_contains "$out" "the next turn end arms one" \
    "the between-cycles wording is also autoarm-only"
  pass "the watcher-down warning keeps the handoff lines to the auto-arm model"
}

# Cursor shares the auto-arm model, but its stop-hook park never advances the
# Claude ledger, so a formerly-Claude home now on Cursor carries a frozen one
# whose age says nothing about when a cycle was last armed.
test_guard_warning_keeps_the_claude_ledger_out_of_a_cursor_home() {
  local dir out
  dir=$(make_home guard-cursor)
  record_handoff "$dir"
  park_session "$dir"
  run_guard "$dir" autoarm cursor; out=$GUARD_OUT
  assert_contains "$out" "WATCHER DOWN" "the guard must still alarm in a Cursor home"
  assert_not_contains "$out" "Nothing has armed a watcher for" \
    "a stale Claude ledger must not be aged in a Cursor home"
  assert_not_contains "$out" "cannot recover on its own" \
    "the Claude turn-end diagnosis must not reach a Cursor home"
  assert_contains "$out" "the next turn end arms one" \
    "a Cursor home keeps the generic between-cycles line"
  pass "the watcher-down warning keeps the Claude ledger out of a Cursor home"
}

test_autoarm_claims_a_new_generation_on_every_firing
test_fresh_handoff_between_turns_is_not_overdue
test_active_session_mid_turn_is_not_overdue
test_parked_session_is_overdue
test_idle_home_is_never_overdue
test_live_arming_claim_is_not_overdue
test_abandoned_arming_claim_is_overdue
test_home_that_never_ran_the_autoarm_is_not_overdue
test_pretool_is_silent_while_supervision_is_healthy
test_pretool_reports_the_unrecoverable_state
test_pretool_speaks_once_per_episode
test_pretool_speaks_again_after_a_fresh_park
test_pretool_records_session_activity
test_pretool_recovery_path_goes_quiet_once_a_cycle_is_armed
test_pretool_is_inert_under_away_mode
test_pretool_is_inert_in_a_task_worktree
test_turnend_banner_names_an_abandoned_handoff
test_turnend_banner_omits_the_lapse_line_between_cycles
test_guard_warning_names_the_unrecoverable_state
test_guard_warning_does_not_cry_lapse_between_cycles
test_guard_warning_keeps_handoff_lines_to_the_autoarm_model
test_guard_warning_keeps_the_claude_ledger_out_of_a_cursor_home

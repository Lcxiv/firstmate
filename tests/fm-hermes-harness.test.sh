#!/usr/bin/env bash
# Behavior tests for the verified Hermes Agent crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HERMES_HOOK="$ROOT/bin/fm-hermes-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
HERMES_RUNTIME_TASK_TMP=
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_hermes_harness() {
  [ -z "$HERMES_RUNTIME_TASK_TMP" ] || rm -rf "$HERMES_RUNTIME_TASK_TMP"
  rm -rf "$TMP_ROOT"
}
trap cleanup_hermes_harness EXIT

write_hermes_validator() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
config="${HERMES_HOME:?}/config.yaml"
if grep -Fq 'hooks: [broken' "$config"; then
  printf 'Failed to parse %s. Falling back to default config.\n' "$config"
  exit 0
fi
if grep -Fq 'fm-turn-end.sh' "$config"; then
  printf 'Configured shell hooks (1 total):\n'
  cat "$config"
else
  printf 'No shell hooks configured.\n'
fi
SH
  chmod +x "$1"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_HERMES_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Hermes Agent!\n ⚕ test │ ctx -- │ ⚠ YOLO\n────────────────────\n❯ \n────────────────────\n'
      ;;
    pointer-typed)
      printf ' ⚕ test │ ctx -- │ ⚠ YOLO\n────────────────────\n❯ Read the brief at %s and follow it exactly.\n────────────────────\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    delivered)
      printf '● Read the brief at %s and follow it exactly.\n⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '2\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    previous=
    literal=
    for argument in "$@"; do
      if [ "$previous" = -l ]; then literal=$argument; break; fi
      previous=$argument
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *' --yolo --accept-hooks')
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_HERMES_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_HERMES_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched) printf 'ready\n' > "$FM_FAKE_HERMES_STATE" ;;
          pointer-typed) printf 'delivered\n' > "$FM_FAKE_HERMES_STATE" ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  write_hermes_validator "$fakebin/hermes"
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.hermes"
  printf 'theme: dark\n' > "$home/.hermes/config.yaml"
  printf 'brief for Hermes\n' > "$home/data/$id/brief.md"
  printf 'hermes\n' > "$home/config/crew-harness"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/hermes.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 project=$3 worktree=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" HERMES_HOME="$home/.hermes" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_HERMES_STATE="$case_dir/hermes.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/brief.md" \
    FM_HERMES_READY_POLLS=2 FM_HERMES_DELIVERY_POLLS=2 \
    FM_HERMES_POLL_INTERVAL=0 PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$project" --harness hermes "$@" 2>&1
}

test_hermes_launch_then_send_is_verified() {
  local id record output launch pointer brief_real metadata task_tmp
  id="hermes-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  HERMES_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  record=$(make_spawn_case success "$id")
  read_spawn_record "$record"
  output=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --model poolside/laguna-s-2.1:free --effort high)
  expect_code 0 "$?" "verified Hermes launch-then-send should succeed"
  assert_contains "$output" "spawned $id harness=hermes" "Hermes spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "HERMES_HOME='$HOME_DIR/.hermes' '$FAKEBIN_DIR/hermes' --cli -m 'poolside/laguna-s-2.1:free' --yolo --accept-hooks" ] \
    || fail "Hermes launch did not use the verified interactive shape: $launch"
  assert_not_contains "$launch" "--effort" "Hermes launch emitted a nonexistent effort flag"
  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "Hermes pointer was not the exact absolute-path instruction: $pointer"
  metadata="$HOME_DIR/state/$id.meta"
  assert_grep 'model=poolside/laguna-s-2.1:free' "$metadata" "Hermes meta lost the model"
  assert_grep 'effort=high' "$metadata" "Hermes meta lost the unsupported effort axis"
  assert_grep 'BEGIN FIRSTMATE HERMES TURN-END HOOK' "$HOME_DIR/.hermes/config.yaml" \
    "Hermes spawn did not install its guarded global hook region"
  assert_grep 'token=' "$WT_DIR/.fm-hermes-turnend" "Hermes spawn did not write its token pointer"
  assert_present "$HOME_DIR/state/$id.hermes-turnend-token" "Hermes spawn did not record its token"
  pass "fm-spawn: Hermes launches interactively, receives its brief, and registers a turn-end token"
}

test_hermes_hook_is_surgical_idempotent_and_authenticated() {
  local home config original once hook worktree target token output validator
  home="$TMP_ROOT/hook-surgery"
  config="$home/.hermes/config.yaml"
  original="$home/original.yaml"
  once="$home/once.yaml"
  worktree="$home/worktree"
  target="$home/task.turn-ended"
  mkdir -p "$home/.hermes" "$worktree"
  validator="$home/hermes"
  write_hermes_validator "$validator"
  cat > "$config" <<'EOF'
# Captain comment.
hooks:
  pre_tool_call:
    - command: "printf foreign"
      timeout: 7
  post_llm_call:
    - command: "printf existing"
      timeout: 3
theme: dark
EOF
  cp "$config" "$original"

  HOME="$home" HERMES_HOME="$home/.hermes" FM_HERMES_BINARY="$validator" \
    "$HERMES_HOOK" install \
    || fail "Hermes hook install refused a realistic config"
  cp "$config" "$once"
  HOME="$home" HERMES_HOME="$home/.hermes" FM_HERMES_BINARY="$validator" \
    "$HERMES_HOOK" install \
    || fail "second Hermes hook install failed"
  cmp -s "$once" "$config" || fail "second Hermes hook install changed config bytes"
  assert_grep 'command: "printf existing"' "$config" "Hermes install changed a foreign hook"

  token=fm.abcdefghijkl
  printf '%s\n' "$target" > "$home/.hermes/fm-turn-end.d/$token"
  printf 'token=%s\n' "$token" > "$worktree/.fm-hermes-turnend"
  hook="$home/.hermes/fm-turn-end.sh"
  output=$(printf '{"hook_event_name":"post_llm_call","session_id":"crew","cwd":"%s"}\n' "$worktree" \
    | HOME="$home" bash "$hook" 2>&1)
  [ -z "$output" ] || fail "registered Hermes hook printed output: $output"
  assert_present "$target" "registered Hermes hook did not touch the turn-end marker"

  rm "$target"
  output=$(printf '{"hook_event_name":"post_llm_call","session_id":"other","cwd":"%s"}\n' "$home" \
    | HOME="$home" bash "$hook" 2>&1)
  [ -z "$output" ] || fail "tokenless Hermes hook printed output: $output"
  assert_absent "$target" "tokenless Hermes hook touched a task marker"

  rm "$home/.hermes/fm-turn-end.d/$token"
  HOME="$home" HERMES_HOME="$home/.hermes" FM_HERMES_BINARY="$validator" \
    "$HERMES_HOOK" remove \
    || fail "Hermes hook removal failed"
  cmp -s "$original" "$config" \
    || fail "Hermes hook removal did not restore the foreign config byte-for-byte"
  pass "Hermes hook install is surgical, idempotent, authenticated, and removable"
}

test_hermes_hook_restores_no_newline_and_refuses_malformed_yaml() {
  local home config original output status validator
  home="$TMP_ROOT/hook-boundaries"
  config="$home/.hermes/config.yaml"
  original="$home/original.yaml"
  mkdir -p "$home/.hermes"
  validator="$home/hermes"
  write_hermes_validator "$validator"
  printf 'theme: dark' > "$config"
  cp "$config" "$original"
  HOME="$home" HERMES_HOME="$home/.hermes" FM_HERMES_BINARY="$validator" \
    "$HERMES_HOOK" install \
    || fail "Hermes hook install refused YAML without a final newline"
  HOME="$home" HERMES_HOME="$home/.hermes" FM_HERMES_BINARY="$validator" \
    "$HERMES_HOOK" remove \
    || fail "Hermes hook removal failed for YAML without a final newline"
  cmp -s "$original" "$config" \
    || fail "Hermes hook removal did not restore the absent final newline"

  printf 'hooks: [broken\n' > "$config"
  cp "$config" "$original"
  status=0
  output=$(HOME="$home" HERMES_HOME="$home/.hermes" FM_HERMES_BINARY="$validator" \
    "$HERMES_HOOK" install 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "Hermes hook accepted malformed YAML"
  assert_contains "$output" "invalid YAML" "malformed Hermes config refusal lacked its reason"
  cmp -s "$original" "$config" || fail "malformed Hermes config refusal changed config bytes"
  assert_absent "$home/.hermes/fm-turn-end.sh" "malformed config refusal wrote a hook script"
  pass "Hermes hook restores newline boundaries and refuses malformed YAML without writing"
}

test_hermes_busy_composer_detection_and_liveness_are_scoped() {
  local capture output
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/hermes-pane"
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      list-windows) printf 'fm-task\n' ;;
      display-message) printf 'hermes\n' ;;
      *) return 0 ;;
    esac
  }

  printf '⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\n' > "$capture"
  fm_pane_is_busy fake hermes || fail "Hermes ASCII cancel row was not recognized as busy"
  if fm_pane_is_busy fake codex; then
    fail "Hermes busy signature leaked into another harness"
  fi
  printf '────────────────────\n❯ \n────────────────────\n' > "$capture"
  output=$(fm_tmux_composer_row_state '❯' 0 0)
  [ "$output" = empty ] || fail "Hermes's bare idle composer was classified as '$output'"
  output=$(fm_backend_tmux_agent_state firstmate:fm-task)
  [ "$output" = alive ] || fail "Hermes tmux liveness was '$output'"
  pass "Hermes busy, composer, and tmux liveness signatures are correctly scoped"
}

test_watcher_scopes_hermes_busy_row_to_recorded_harness() (
  local state="$TMP_ROOT/watch-state"
  local busy_capture='⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel'
  mkdir -p "$state"
  printf 'window=fake\nharness=hermes\n' > "$state/hermes-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  # shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
  fm_backend_busy_state() { printf 'unknown'; }
  window_is_busy fake "$busy_capture" \
    || fail "fm-watch did not recognize Hermes's real busy row"
  printf 'window=fake\nharness=codex\n' > "$state/hermes-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch applied Hermes's busy signature to a recorded Codex task"
  fi
  pass "fm-watch scopes Hermes's ASCII busy row to recorded Hermes tasks"
)

test_hermes_detection_prefers_verified_marker_and_supports_ancestry() {
  local directory fakebin config output
  directory="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$directory")
  config="$directory/config"
  mkdir -p "$config"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -o ] && field=$argument
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$field:$pid" in
  comm=:4242) printf 'python\n' ;;
  args=:4242) printf '/opt/hermes/venv/bin/python /opt/hermes/hermes --cli\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  args=:*) printf 'bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  output=$(HERMES_INTERACTIVE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-harness.sh")
  [ "$output" = hermes ] || fail "Hermes env-marker detection returned '$output'"
  output=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u HERMES_INTERACTIVE \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh")
  [ "$output" = hermes ] || fail "Hermes interpreter-ancestry detection returned '$output'"
  pass "fm-harness detects Hermes through its verified marker and interpreter ancestry"
}

test_hermes_session_lock_identity() {
  local home fakebin output
  home="$TMP_ROOT/session-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'python'; exit 0 ;;
  *"args="*) printf '%s\n' '/opt/hermes/venv/bin/python /opt/hermes/hermes --cli'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from Hermes ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the Hermes harness ancestor" ;;
  esac
  printf '%s\n' "$$" > "$home/state/.lock"
  output=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$output" "lock: held by live harness pid" \
    "fm-lock did not recognize Hermes as a live holder"
  pass "fm-lock recognizes Hermes ancestry and live lock holders"
}

test_hermes_teardown_removes_pointer_and_registry_token() {
  local id record output token
  id=hermes-teardown-z8
  record=$(make_spawn_case teardown "$id")
  read_spawn_record "$record"
  output=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 "$?" "Hermes spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-hermes-turnend")

  HOME="$HOME_DIR" HERMES_HOME="$HOME_DIR/.hermes" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    PATH="$FAKEBIN_DIR:$BASE_PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "Hermes teardown failed"
  assert_absent "$WT_DIR/.fm-hermes-turnend" "Hermes token pointer survived teardown"
  assert_absent "$HOME_DIR/.hermes/fm-turn-end.d/$token" "Hermes registry token survived teardown"
  assert_absent "$HOME_DIR/state/$id.hermes-turnend-token" "Hermes token state survived teardown"
  pass "fm-teardown removes the Hermes task pointer and registry token"
}

test_hermes_launch_then_send_is_verified
test_hermes_hook_is_surgical_idempotent_and_authenticated
test_hermes_hook_restores_no_newline_and_refuses_malformed_yaml
test_hermes_busy_composer_detection_and_liveness_are_scoped
test_watcher_scopes_hermes_busy_row_to_recorded_harness
test_hermes_detection_prefers_verified_marker_and_supports_ancestry
test_hermes_session_lock_identity
test_hermes_teardown_removes_pointer_and_registry_token

#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true,
      "todos": [
        { "text": "Your call: perishable-first admission", "state": "current", "by": "captain" },
        { "text": "Firstmate acts on your answer", "state": "todo", "by": "firstmate" }
      ]
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true,
      "todos": [
        { "text": "Validation passed, checks green", "state": "done", "by": "worker" },
        { "text": "Your merge word", "state": "current", "by": "captain" },
        { "text": "Merge and clean up", "state": "todo", "by": "firstmate" }
      ]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true,
      "todos": [ { "text": "Start: dispatch a worker", "state": "todo", "by": "firstmate" } ] }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "alarm"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown charted kind was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "warning"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a dispatchable warning row was accepted"

  write_valid_payload "$data"
  jq '.charted_warning_more = -1' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a negative omitted-warning count was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: the payload extracted from the built page is byte-for-byte the
  # same JSON document, and the escaped </script> string can no longer
  # terminate the data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data runtime origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  runtime="$home/runtime"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = arm ]; then
  artifact=${2:-}
  "$REAL_LAVISH_ADAPTER" arm "$artifact" >/dev/null
  sid=$("$REAL_LAVISH_ADAPTER" source-id "$artifact")
  "$REAL_PROCEVENT" start "$sid" >/dev/null
  exit 0
fi
exec "$REAL_LAVISH_ADAPTER" "$@"
SH
  chmod +x "$runtime/bin/fm-procevent-lavish.sh"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != poll ]; then
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$runtime" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    FM_BEARINGS_BOARD_TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html" \
    REAL_LAVISH_ADAPTER="$ROOT/bin/fm-procevent-lavish.sh" \
    REAL_PROCEVENT="$ROOT/bin/fm-procevent.sh" ORDER_PROOF_HOLD="$hold" \
    "$runtime/bin/fm-bearings-board.sh" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  show=$(cd "$home" && tasks-axi show "$hold" --full) \
    || fail "the order-proof captain hold disappeared"
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_charted_kind_is_optional_and_accepts_both_values() {
  local home data
  home=$(make_home chartedkind)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.charted = ([
        {"id":"a","repo":"sample","title":"Queued","reason":"","dispatchable":true},
        {"id":"b","repo":"sample","title":"Queued too","reason":"gated","dispatchable":true,"kind":"queued"},
        {"id":"c","repo":"sample","title":"Integrity notice","reason":"main inventory","dispatchable":false,"kind":"warning"}
      ] | map(.todos = [{"text":"Start","state":"todo"}])) | .charted_warning_more = 2' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null \
    || fail "an omitted, queued, and warning charted kind was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.charted[] | .kind // "queued"]) == ["queued", "queued", "warning"]
      and .charted_warning_more == 2
  ' >/dev/null || fail "the built board did not carry the charted kinds and omitted-warning count it was given"
  pass "charted kind is optional and accepts queued and warning"
}

test_a_recommendation_is_checked_against_the_options_that_exist() {
  local home data rc out
  home=$(make_home recommend)
  data="$home/payload.json"

  # A card WITH options still has to recommend one of its own values.
  write_valid_payload "$data"
  jq '.captains_call[0].recommend_value = "maybe"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a recommendation naming no existing option was accepted: $out"

  # A card that leans on its freeform box carries no options to check it
  # against, and the recommendation is itself the answer value the board
  # offers, so it must reach the board rather than refusing the whole build.
  write_valid_payload "$data"
  jq '.captains_call[0].options = []
      | .captains_call[0].allow_freeform = true
      | .captains_call[0].close = "release"
      | .captains_call[0].recommend_value = "release"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null \
    || fail "a recommended freeform card was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    (.captains_call[0] | .options == [] and .recommend_value == "release" and .close == "release")
  ' >/dev/null || fail "the built board dropped the recommended freeform card's answer value"
  pass "a recommendation is checked against the options that exist, and stands alone without them"
}

# A payload with one malformed todos list, refused with a message naming the
# item and the step.
refuse_todos() {  # <home> <jq-edit> <expected message> <what>
  local home=$1 data="$1/payload.json" rc out
  write_valid_payload "$data"
  jq "$2" "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "$4 was accepted"
  assert_contains "$out" "$3" "the refusal of $4 did not name the problem: $out"
}

test_build_refuses_malformed_todos_and_names_what_is_wrong() {
  local home
  home=$(make_home todos-refusal)
  refuse_todos "$home" 'del(.charted[0].todos)' \
    "charted[0] (sample-queued) has no todos list" "a queued row without todos"
  refuse_todos "$home" '.captains_call[1].todos = []' \
    "captains_call[1] (merge.sample-task) todos is empty" "an empty todos list"
  refuse_todos "$home" '.captains_call[0].todos = "later"' \
    "todos is not a list" "a todos string"
  refuse_todos "$home" '.captains_call[0].todos[1].text = ""' \
    "perishable-first-admission-choice) todos[1] has no text" "a step with no text"
  refuse_todos "$home" '.captains_call[1].todos[0].state = "maybe"' \
    'todos[0] state "maybe" is not one of done, current, blocked, todo' "an unknown step state"
  refuse_todos "$home" '.captains_call[1].todos[0].by = "crew"' \
    'todos[0] by "crew" is not one of captain, firstmate, worker' "an unknown step owner"
  refuse_todos "$home" '.captains_call[1].todos[0].state = "current"' \
    "merge.sample-task) todos marks more than one step current" "two current steps"
  refuse_todos "$home" '.captains_call[0].todos[0] = "step"' \
    "todos[0] is not a step object" "a bare-string step"
  refuse_todos "$home" '.captains_call[0].blocks = [""]' \
    "perishable-first-admission-choice) blocks is not a list of ids" "an empty blocks id"
  refuse_todos "$home" '.captains_call[1].blocks = "sample-queued"' \
    "captains_call[1] (merge.sample-task) blocks is not a list of ids" "a blocks string"
  refuse_todos "$home" '.captains_call[0].blocks = ["sample-queued", 7]' \
    "blocks is not a list of ids" "a non-string blocks id"
  refuse_todos "$home" '.underway = [{"id":"u","repo":"sample","state":"working","doing":"x","kind":"ship","title":7,
      "todos":[{"text":"Build","state":"current"}]}]' \
    "does not satisfy fm-bearings-board.v1" "a non-string underway title"
  assert_absent "$home/.lavish/bearings-board.html" "a refused todos payload still produced a board"
  pass "build refuses malformed todos, naming the item and the step to fix"
}

test_several_blocked_prerequisites_are_accepted() {
  local home data out
  home=$(make_home todos-blocked)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.charted[0].todos = [
        {"text":"Waits on a","state":"blocked"},{"text":"Waits until 2026-10-01","state":"blocked"},
        {"text":"Start","state":"todo"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" validate "$data") || fail "several blocked prerequisites were refused: $out"
  assert_contains "$out" "valid: $data" "validate did not confirm the payload: $out"
  pass "a queued row may carry several blocked prerequisites, and validate confirms it"
}

# A compact fm-bearings.v1 snapshot covering each generated shape.
write_snapshot() {  # <path>
  cat > "$1" <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [
    { "id": "u-build", "kind": "ship", "state": "working", "doing": "harness busy (claude-hook)" },
    { "id": "u-valid", "kind": "ship", "state": "working", "doing": "review step running" },
    { "id": "u-pr", "kind": "ship", "state": "failed", "doing": "run cancelled" },
    { "id": "u-done", "kind": "ship", "state": "done", "doing": "checks green" },
    { "id": "u-scout", "kind": "scout", "state": "paused", "doing": "waiting on an upstream release" },
    { "id": "u-mate", "kind": "secondmate", "state": "active_child_work", "doing": "jt-1: building" }
  ],
  "decisions_open": [ { "id": "call-a", "key": "call-a", "verb": "captain-hold", "summary": "Call A" } ],
  "gates": [
    { "id": "q-free", "title": "Free", "blocked_by": "-", "reason": "-", "owner": "(main)" },
    { "id": "q-held", "title": "Held", "blocked_by": "call-a,u-build", "reason": "until 2026-10-01: after the release", "owner": "(main)" }
  ],
  "recorded_prs": [ { "id": "u-pr", "url": "https://github.com/example/sample/pull/3" } ]
}
JSON
}

test_todos_are_generated_from_the_snapshot() {
  local home data snap filled
  home=$(make_home todos-generate)
  data="$home/payload.json"
  snap="$home/snapshot.json"
  write_snapshot "$snap"
  jq -n '{schema:"fm-bearings-board.v1", home:"h", generated:"g", prs_live:false,
    captains_call:[
      {key:"call-a", type:"decision", repo:"sample", title:"Delete the scratch",
       options:[{value:"yes", label:"Yes"}]},
      {key:"merge.u-done", type:"merge", repo:"sample", title:"Merge: done work", risk:"low",
       options:[{value:"merge", label:"Merge now"}]}],
    underway:[
      {id:"u-build", repo:"sample", kind:"ship", state:"working", doing:"harness busy (claude-hook)", title:"Build it"},
      {id:"u-valid", repo:"sample", kind:"ship", state:"working", doing:"review step running"},
      {id:"u-pr", repo:"sample", kind:"ship", state:"failed", doing:"run cancelled"},
      {id:"u-scout", repo:"sample", kind:"scout", state:"paused", doing:"waiting on an upstream release"},
      {id:"u-mate", repo:"sample", kind:"secondmate", state:"active_child_work", doing:"jt-1: building"}],
    landed:[],
    charted:[
      {id:"q-free", repo:"sample", title:"Free", reason:"", dispatchable:true},
      {id:"q-held", repo:"sample", title:"Held", reason:"", dispatchable:false},
      {id:"q-own", repo:"sample", title:"Own steps", reason:"", dispatchable:true,
       todos:[{text:"Composer step", state:"todo"}]},
      {id:"main-inventory", repo:null, title:"Inventory", reason:"main inventory", dispatchable:false, kind:"warning"}]}' > "$data"
  filled=$(run_board "$home" todos "$snap" "$data") || fail "todos generation failed"
  printf '%s' "$filled" > "$home/filled.json"
  run_board "$home" validate "$home/filled.json" >/dev/null \
    || fail "the generated todos do not satisfy the contract: $filled"
  printf '%s' "$filled" | jq -e '
    def steps($id): [(.underway[], .charted[]) | select(.id == $id) | .todos[] | "\(.state): \(.text)"];
    (.captains_call[0] | .blocks == ["q-held"]
      and ([.todos[] | "\(.state)/\(.by): \(.text)"]
        == ["current/captain: Your call: Delete the scratch", "todo/firstmate: Firstmate acts on your answer"]))
    and ([.captains_call[1].todos[] | .state] == ["done", "current", "todo"])
    and (.captains_call[1].todos[1] | .text == "Your merge word" and .by == "captain")
    and (.captains_call[1] | has("blocks") | not)
    and (steps("u-build")[0:3] == ["done: Instructions written, worker started",
      "current: Build the change: the worker is active", "todo: Validate: review, tests, docs, CI"])
    and (steps("u-valid")[2] == "current: Validate: review, tests, docs, CI: review step running")
    and (steps("u-pr")[3] == "blocked: PR open with checks green: the validation run was cancelled")
    and (steps("u-scout") == ["done: Instructions written, worker started",
      "current: Investigate: waiting on an upstream release (waiting on an outside delay)",
      "todo: Report written", "todo: Findings relayed to you"])
    and (steps("u-mate") == ["current: Second mate working: jt-1: building"])
    and (steps("q-free") == ["todo: Start: dispatch a worker"])
    and (steps("q-held") == ["blocked: Waits on your call: Delete the scratch", "blocked: Waits on Build it",
      "blocked: Waits until 2026-10-01: after the release", "todo: Start: dispatch a worker"])
    and (steps("q-own") == ["todo: Composer step"])
    and (steps("main-inventory") == ["current: Repair: main inventory"])
  ' >/dev/null || fail "the generated todos did not follow the fill rules: $filled"
  pass "todos generates each row's steps and each call's blocks from the snapshot, keeping composed ones"
}

test_todos_never_carry_snapshot_truncated_text() {
  local home data snap filled
  home=$(make_home todos-untruncated)
  data="$home/payload.json"
  snap="$home/snapshot.json"
  jq -n '{schema:"fm-bearings.v1",
    in_flight:[
      {id:"u-full", kind:"ship", state:"working", doing:"rewriting the importer so that every vendor fe…"},
      {id:"u-short", kind:"ship", state:"working", doing:"polishing the unreadable part of the long…"}],
    gates:[
      {id:"q-hold", title:"Hold", blocked_by:"-", reason:"waiting for the vendor contract to be co…", owner:"(main)"},
      {id:"q-date", title:"Date", blocked_by:"-", reason:"until 2026-10-01: after the quarterly rel…", owner:"(main)"},
      {id:"q-bare", title:"Bare", blocked_by:"u-full,fm-mangled-blo…", reason:"held for a reason nobody copied in fu…", owner:"(main)"}]}' > "$snap"
  jq -n '{schema:"fm-bearings-board.v1", home:"h", generated:"g", prs_live:false,
    captains_call:[],
    underway:[
      {id:"u-full", repo:"sample", kind:"ship", state:"working", title:"Importer",
       doing:"rewriting the importer so that every vendor feed is parsed the same way"},
      {id:"u-short", repo:"sample", kind:"ship", state:"working", doing:"polishing"}],
    landed:[],
    charted:[
      {id:"q-hold", repo:"sample", title:"Hold", dispatchable:false,
       reason:"waiting for the vendor contract to be countersigned"},
      {id:"q-date", repo:"sample", title:"Date", dispatchable:false,
       reason:"until 2026-10-01: after the quarterly release is out"},
      {id:"q-bare", repo:"sample", title:"Bare", dispatchable:false, reason:""}]}' > "$data"
  filled=$(run_board "$home" todos "$snap" "$data") || fail "todos generation failed"
  printf '%s' "$filled" | jq -e '
    def steps($id): [(.underway[], .charted[]) | select(.id == $id) | .todos[] | "\(.state): \(.text)"];
    ([(.underway[], .charted[]) | .todos[].text | select(contains("…"))] == [])
    and (steps("u-full")[1]
      == "current: Build the change: rewriting the importer so that every vendor feed is parsed the same way")
    and (steps("u-short")[1] == "current: Build the change: polishing")
    and (steps("q-hold") == ["blocked: Held: waiting for the vendor contract to be countersigned",
      "todo: Start: dispatch a worker"])
    and (steps("q-date") == ["blocked: Waits until 2026-10-01: after the quarterly release is out",
      "todo: Start: dispatch a worker"])
    and (steps("q-bare") == ["blocked: Waits on Importer", "blocked: Held: the task record carries the reason",
      "todo: Start: dispatch a worker"])
  ' >/dev/null || fail "a generated step carried snapshot-truncated text: $filled"
  pass "todos prefers the composer's full text and never carries a snapshot value cut short"
}

test_a_call_in_a_long_blocker_list_keeps_its_blocks_link() {
  local home data snap filled
  home=$(make_home todos-long-blockers)
  data="$home/payload.json"
  snap="$home/snapshot.json"
  jq -n '{schema:"fm-bearings.v1", in_flight:[],
    gates:[{id:"q-long", title:"Long", reason:"-", owner:"(main)",
      blocked_by:([range(0; 8) | "fm-a-rather-long-prerequisite-task-identifier-\(.)"] + ["fm-the-call-at-the-end"] | join(","))}]}' > "$snap"
  jq -n '{schema:"fm-bearings-board.v1", home:"h", generated:"g", prs_live:false,
    captains_call:[{key:"fm-the-call-at-the-end", type:"decision", repo:"sample", title:"Pick the vendor",
      options:[{value:"yes", label:"Yes"}]}],
    underway:[], landed:[],
    charted:[{id:"q-long", repo:"sample", title:"Long", reason:"", dispatchable:false}]}' > "$data"
  filled=$(run_board "$home" todos "$snap" "$data") || fail "todos generation failed"
  printf '%s' "$filled" | jq -e '
    (.captains_call[0].blocks == ["q-long"])
    and (.charted[0].todos | length == 10)
    and (.charted[0].todos[8] | .text == "Waits on your call: Pick the vendor" and .by == "captain")
    and (.charted[0].todos[7].text == "Waits on fm-a-rather-long-prerequisite-task-identifier-7")
  ' >/dev/null || fail "a call at the end of a long blocker list lost its blocks link: $filled"
  pass "a call whose id ends a long blocker list still links to the work it holds up"
}

test_todos_treats_a_missing_section_as_empty() {
  local home data snap filled rc
  home=$(make_home todos-no-sections)
  data="$home/payload.json"
  snap="$home/snapshot.json"
  write_snapshot "$snap"
  jq -n '{schema:"fm-bearings-board.v1", home:"h", generated:"g", prs_live:false, landed:[]}' > "$data"
  set +e; filled=$(run_board "$home" todos "$snap" "$data" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "todos failed on a payload with no call, underway, or charted section: $filled"
  printf '%s' "$filled" | jq -e '.captains_call == [] and .underway == [] and .charted == []' >/dev/null \
    || fail "a missing section was not filled as an empty list: $filled"
  pass "todos treats a missing call, underway, or charted section as an empty list"
}

test_todos_generation_refuses_missing_inputs() {
  local home rc out
  home=$(make_home todos-missing)
  set +e; out=$(run_board "$home" todos "$home/none.json" "$home/none.json" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "todos accepted missing inputs"
  assert_contains "$out" "does not exist" "the missing-input refusal did not say why: $out"
  pass "todos generation refuses missing inputs"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_charted_kind_is_optional_and_accepts_both_values
test_a_recommendation_is_checked_against_the_options_that_exist
test_build_refuses_malformed_todos_and_names_what_is_wrong
test_several_blocked_prerequisites_are_accepted
test_todos_are_generated_from_the_snapshot
test_todos_never_carry_snapshot_truncated_text
test_a_call_in_a_long_blocker_list_keeps_its_blocks_link
test_todos_treats_a_missing_section_as_empty
test_todos_generation_refuses_missing_inputs
test_build_injects_binds_then_arms
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot

#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from <charted-json> and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 charted=$2 more=${3:-0} warning_more=${4:-0} data="$1/payload.json"
  jq -n --argjson charted "$charted" --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <maps-json> and return what the renderer produced. The
# effort-map band is fork-only material that no fleet snapshot owns, so it is
# driven independently of the charted rows.
render_maps() {  # <home> <maps-json>
  local home=$1 maps=$2 data="$1/payload.json"
  jq -n --argjson maps "$maps" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[],
    maps:$maps}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}


test_an_effort_map_renders_its_destination_counts_and_fog() {
  local home out
  home=$(make_home effort-map)
  out=$(render_maps "$home" '[
    {"title":"agent factory","destination":"One agent the captain talks to.",
     "decided":3,"open":2,"fog":["headless turn","capability scope"],
     "out_of_scope":["voice relay"]}
  ]')
  printf '%s' "$out" | jq -e '
    .maps.shown == true
      and (.maps.cards | length) == 1
      and (.maps.cards[0].title == "agent factory")
      and (.maps.cards[0].dest == "One agent the captain talks to.")
      and ([.maps.cards[0].badges[] | .text] == ["3 decided", "2 open"])
      and (.maps.cards[0].notes | length) == 2
      and (.maps.cards[0].notes[0] == "Fog: headless turn; capability scope")
      and (.maps.cards[0].notes[1] == "Out of scope: voice relay")
  ' >/dev/null || fail "an effort map did not render its own material: $out"
  pass "an effort map renders its destination, counts, fog, and out-of-scope notes"
}

test_a_map_with_no_fog_says_the_remaining_work_is_sharp() {
  local home out
  home=$(make_home sharp-map)
  out=$(render_maps "$home" '[
    {"title":"sharp effort","destination":"Nothing unknown left.","decided":5,"open":0}
  ]')
  printf '%s' "$out" | jq -e '
    .maps.shown == true
      and (.maps.cards[0].notes == ["Fog: none - remaining work is sharp"])
      and ([.maps.cards[0].badges[] | .text] == ["5 decided", "0 open"])
  ' >/dev/null || fail "a fog-free map did not say so: $out"
  pass "a map with no remaining fog says the work is sharp rather than rendering nothing"
}

test_a_home_with_no_effort_maps_renders_no_band_at_all() {
  local home out_absent out_empty
  home=$(make_home no-maps)
  # An omitted key and an empty array are both "this home keeps no maps", and
  # neither may leave an empty band on the captain's board.
  out_empty=$(render_maps "$home" '[]')
  printf '%s' "$out_empty" | jq -e '
    .maps.shown == false and (.maps.cards | length) == 0
  ' >/dev/null || fail "an empty maps array still rendered a band: $out_empty"
  out_absent=$(render "$home" '[]')
  printf '%s' "$out_absent" | jq -e '
    .maps.shown == false and (.maps.cards | length) == 0
  ' >/dev/null || fail "an omitted maps key still rendered a band: $out_absent"
  pass "a home with no effort maps renders no band at all"
}

test_more_than_one_effort_map_each_gets_its_own_card() {
  local home out
  home=$(make_home many-maps)
  out=$(render_maps "$home" '[
    {"title":"first effort","destination":"A.","decided":1,"open":1},
    {"title":"second effort","destination":"B.","decided":2,"open":0}
  ]')
  printf '%s' "$out" | jq -e '
    (.maps.cards | length) == 2
      and ([.maps.cards[].title] == ["first effort", "second effort"])
      and (.maps.sub == "2 efforts")
  ' >/dev/null || fail "multiple maps did not each render: $out"
  pass "each effort map gets its own card"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_an_effort_map_renders_its_destination_counts_and_fog
test_a_map_with_no_fog_says_the_remaining_work_is_sharp
test_a_home_with_no_effort_maps_renders_no_band_at_all
test_more_than_one_effort_map_each_gets_its_own_card

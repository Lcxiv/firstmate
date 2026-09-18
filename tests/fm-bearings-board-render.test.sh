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

# Build the board from <captains-call-json> and return what the renderer
# produced after driving <action>... through the rendered controls.
render_call() {  # <home> <captains-call-json> [action...]
  local home=$1 call=$2 data="$1/payload.json"
  shift 2
  jq -n --argjson call "$call" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$call, underway:[], landed:[], charted:[]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" "$@" \
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


# The captain's own reported shape: a captain-gated work item that leans on its
# freeform box, carries no preset options, and still recommends an answer. It
# used to reach the board with no option controls on it at all.
RELEASE_CARD='[{"key":"held-item","type":"decision","repo":"sample",
  "title":"Release the held item","about":"held since yesterday",
  "decide":"release it or keep holding","allow_freeform":true,
  "freeform_hint":"Or type your own instruction",
  "close":"release","recommend_value":"release","options":[]}]'

test_a_freeform_release_card_still_renders_an_answer_control() {
  local home out
  home=$(make_home freeform-release)
  out=$(render_call "$home" "$RELEASE_CARD")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the card: $out"
  printf '%s' "$out" | jq -e '
    (.call.cards | length) == 1
      and (.call.cards[0] | .title == "Release the held item"
        and (.options | length) == 1
        and (.options[0] | .value == "release" and .rec == true)
        and .freeform == true)
  ' >/dev/null || fail "a recommended freeform card rendered no option control: $out"
  pass "a freeform release card renders its recommended answer as a real option"
}

test_that_recommended_answer_is_the_one_that_gets_queued() {
  local home out
  home=$(make_home freeform-release-answer)
  out=$(render_call "$home" "$RELEASE_CARD" pick:0:0 submit:0)
  printf '%s' "$out" | jq -e '
    (.queued | length) == 1
      and (.queued[0] | .question == "held-item" and .answer == "release" and .close == "release")
      and .sent == 0
      and (.call.cards[0].queued == true)
  ' >/dev/null || fail "the rendered control did not queue the release answer: $out"
  pass "picking the rendered control queues the release answer and sends nothing"
}

test_an_answerless_submit_says_so_instead_of_doing_nothing() {
  local home out
  home=$(make_home empty-submit)
  out=$(render_call "$home" "$RELEASE_CARD" submit:0)
  printf '%s' "$out" | jq -e '
    (.queued | length) == 0
      and (.call.cards[0] | .limitShown == true and (.limit | test("Pick an option")))
  ' >/dev/null || fail "an empty submit stayed silent: $out"
  pass "a card with nothing chosen says what it needs instead of doing nothing"
}

# The reachable no-options shape: the builder accepts an empty options list only
# when the card leans on its freeform box, and with no recommendation to offer
# as an option the card has nothing but that box.
FREEFORM_ONLY_CARD='[{"key":"wording","type":"decision","repo":"sample",
  "title":"Word the release note","about":"draft is ready",
  "decide":"give the wording","allow_freeform":true,"options":[]}]'

test_a_freeform_only_card_says_so_and_queues_what_is_typed() {
  local home out
  home=$(make_home freeform-only)
  out=$(render_call "$home" "$FREEFORM_ONLY_CARD")
  printf '%s' "$out" | jq -e '
    .error == ""
      and (.call.cards | length) == 1
      and (.call.cards[0] | (.options | length) == 0
        and (.noOptionsNote | length) > 0
        and .freeform == true)
  ' >/dev/null || fail "a freeform-only card did not render its note and box alone: $out"
  out=$(render_call "$home" "$FREEFORM_ONLY_CARD" "type:0:ship it tonight" submit:0)
  printf '%s' "$out" | jq -e '
    (.queued | length) == 1
      and (.queued[0] | .question == "wording" and .answer == "ship it tonight")
      and .sent == 0
      and (.call.cards[0].queued == true)
  ' >/dev/null || fail "a freeform-only card did not queue the typed answer: $out"
  pass "a freeform-only card renders its note plus box and queues the typed answer"
}

# Two cards with an ordinary options list, one of them recommended, so the bulk
# control has something to skip.
BULK_CARDS='[
  {"key":"land-it","type":"decision","repo":"sample","title":"Land the branch",
   "about":"reviews are in","decide":"land or hold","close":"done","recommend_value":"land",
   "options":[{"value":"land","label":"Land it"},{"value":"hold","label":"Hold"}]},
  {"key":"naming","type":"decision","repo":"sample","title":"Pick a naming scheme",
   "about":"two candidates","decide":"which one",
   "options":[{"value":"short","label":"Short"},{"value":"long","label":"Long"}]},
  {"key":"held-item","type":"decision","repo":"sample","title":"Release the held item",
   "about":"held since yesterday","decide":"release or hold","allow_freeform":true,
   "close":"release","recommend_value":"release","options":[]}
]'

test_an_ordinary_card_keeps_rendering_and_queueing_exactly_as_before() {
  local home out
  home=$(make_home single-answer)
  out=$(render_call "$home" "$BULK_CARDS" pick:0:1 submit:0)
  printf '%s' "$out" | jq -e '
    ([.call.cards[0].options[] | .label] == ["Land it", "Hold"])
      and ([.call.cards[0].options[] | .rec] == [true, false])
      and (.call.cards[1].options | length) == 2
      and (.queued | length) == 1
      and (.queued[0] | .question == "land-it" and .answer == "hold" and .close == "done")
      and .sent == 0
  ' >/dev/null || fail "an ordinary card changed how it renders or queues: $out"
  pass "an ordinary options card renders and queues one answer exactly as before"
}

test_queue_all_stages_the_recommended_answers_without_queueing_them() {
  local home out
  home=$(make_home bulk-stage)
  out=$(render_call "$home" "$BULK_CARDS" bulk-open)
  printf '%s' "$out" | jq -e '
    .bulk.shown == true
      and .bulk.staging == true
      and (.bulk.staged | length) == 2
      and (.bulk.staged[0] | test("Land the branch") and test("land"))
      and (.bulk.staged[1] | test("Release the held item") and test("release"))
      and (.queued | length) == 0
      and .sent == 0
      and ([.call.cards[] | .queued] == [false, false, false])
  ' >/dev/null || fail "queue-all queued or sent something before it was confirmed: $out"
  pass "queue-all stages every recommended answer and queues nothing on its own"
}

test_cancelling_a_queue_all_leaves_nothing_queued() {
  local home out
  home=$(make_home bulk-cancel)
  out=$(render_call "$home" "$BULK_CARDS" bulk-open bulk-cancel)
  printf '%s' "$out" | jq -e '
    .bulk.staging == false
      and (.bulk.staged | length) == 0
      and (.bulk.note | test("nothing was queued"))
      and (.queued | length) == 0
      and .sent == 0
      and ([.call.cards[] | .queued] == [false, false, false])
  ' >/dev/null || fail "cancelling a queue-all did not clear it: $out"
  pass "cancelling a queue-all clears the staged answers and queues nothing"
}

test_confirming_a_queue_all_queues_every_recommendation_and_sends_nothing() {
  local home out
  home=$(make_home bulk-confirm)
  out=$(render_call "$home" "$BULK_CARDS" bulk-open bulk-confirm)
  printf '%s' "$out" | jq -e '
    (.queued | length) == 2
      and ([.queued[] | .question] == ["land-it", "held-item"])
      and ([.queued[] | .answer] == ["land", "release"])
      and ([.queued[] | .close] == ["done", "release"])
      and .sent == 0
      and ([.call.cards[] | .queued] == [true, false, true])
      and (.bulk.note | test("nothing has been sent"))
      and .bulk.canQueueAll == false
  ' >/dev/null || fail "confirming a queue-all did not stage exactly the recommendations: $out"
  pass "a confirmed queue-all queues every recommendation for review and sends nothing"
}

test_queue_all_never_queues_a_card_the_captain_already_answered() {
  local home out
  home=$(make_home bulk-skip-answered)
  out=$(render_call "$home" "$BULK_CARDS" pick:0:1 submit:0 bulk-open bulk-confirm)
  printf '%s' "$out" | jq -e '
    (.queued | length) == 2
      and ([.queued[] | .question] == ["land-it", "held-item"])
      and ([.queued[] | .answer] == ["hold", "release"])
  ' >/dev/null || fail "queue-all overwrote or duplicated an answered card: $out"
  pass "queue-all skips cards the captain already answered"
}

test_an_answer_given_while_staged_is_never_overwritten_on_confirm() {
  local home out
  home=$(make_home bulk-stale-stage)
  out=$(render_call "$home" "$BULK_CARDS" bulk-open pick:0:1 submit:0 bulk-open bulk-confirm)
  printf '%s' "$out" | jq -e '
    (.queued | length) == 2
      and ([.queued[] | .question] == ["land-it", "held-item"])
      and ([.queued[] | .answer] == ["hold", "release"])
      and .sent == 0
      and .bulk.staging == false
      and ([.call.cards[] | .queued] == [true, false, true])
  ' >/dev/null || fail "confirming a queue-all after answering a staged card re-queued it: $out"
  pass "a card answered while queue-all is staged keeps the captain's own answer"
}

test_answering_a_card_closes_an_open_queue_all_stage() {
  local home out
  home=$(make_home bulk-stage-closes)
  out=$(render_call "$home" "$BULK_CARDS" bulk-open pick:0:1 submit:0)
  printf '%s' "$out" | jq -e '
    .bulk.staging == false
      and (.bulk.staged | length) == 0
      and (.queued | length) == 1
      and (.queued[0] | .question == "land-it" and .answer == "hold")
      and .sent == 0
      and (.bulk.staged | length) == 0
      and .bulk.canQueueAll == true
  ' >/dev/null || fail "answering a card left a stale staged list open: $out"
  out=$(render_call "$home" "$BULK_CARDS" bulk-open pick:0:1 submit:0 bulk-confirm)
  printf '%s' "$out" | jq -e '
    (.queued | length) == 1
      and (.queued[0] | .question == "land-it" and .answer == "hold")
      and .bulk.note == ""
  ' >/dev/null || fail "a confirm on a closed stage still queued the stale list: $out"
  pass "answering a card by hand closes the staged queue-all list"
}

test_a_board_with_no_recommendations_offers_no_queue_all() {
  local home out
  home=$(make_home bulk-absent)
  out=$(render_call "$home" '[
    {"key":"naming","type":"decision","repo":"sample","title":"Pick a naming scheme",
     "about":"two candidates","decide":"which one",
     "options":[{"value":"short","label":"Short"},{"value":"long","label":"Long"}]}
  ]')
  printf '%s' "$out" | jq -e '.bulk.shown == false' >/dev/null \
    || fail "a board with nothing recommended still offered queue-all: $out"
  pass "a board with no recommended answers offers no queue-all control"
}

test_a_long_queue_keeps_every_row_reachable() {
  local home out rows
  rows=$(jq -nc '[range(0; 23) | {
    id: ("queued-" + (. | tostring)), repo: "sample",
    title: ("Queued item " + (. | tostring)), reason: "waiting on prep",
    dispatchable: false }]')
  home=$(make_home long-queue)
  out=$(render "$home" "$rows")
  printf '%s' "$out" | jq -e '
    (.charted | length) == 23
      and (.more | length) == 0
      and (.chartedRegion | .scroll == true and .focusable == true
        and (.label | test("scroll")))
      and (.chartedRegion.sub | test("23 queued"))
  ' >/dev/null || fail "a long queue was truncated or left unreachable: $out"
  [ "$(charted_next_count "$out")" = 23 ] \
    || fail "the charted next tally disagreed with the rendered rows: $out"
  pass "every row of a long queue renders and stays reachable by scrolling"
}

test_a_short_queue_does_not_become_a_scroll_region() {
  local home out
  home=$(make_home short-queue)
  out=$(render "$home" '[
    {"id":"one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"two","repo":"sample","title":"Two","reason":"gated","dispatchable":true}
  ]')
  printf '%s' "$out" | jq -e '
    .chartedRegion.scroll == false
      and (.chartedRegion.sub == "2 queued")
  ' >/dev/null || fail "a short queue was turned into a scroll region: $out"
  pass "a short queue stays a plain list"
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

test_a_freeform_release_card_still_renders_an_answer_control
test_that_recommended_answer_is_the_one_that_gets_queued
test_an_answerless_submit_says_so_instead_of_doing_nothing
test_a_freeform_only_card_says_so_and_queues_what_is_typed
test_an_ordinary_card_keeps_rendering_and_queueing_exactly_as_before
test_queue_all_stages_the_recommended_answers_without_queueing_them
test_cancelling_a_queue_all_leaves_nothing_queued
test_confirming_a_queue_all_queues_every_recommendation_and_sends_nothing
test_queue_all_never_queues_a_card_the_captain_already_answered
test_an_answer_given_while_staged_is_never_overwritten_on_confirm
test_answering_a_card_closes_an_open_queue_all_stage
test_a_board_with_no_recommendations_offers_no_queue_all
test_a_long_queue_keeps_every_row_reachable
test_a_short_queue_does_not_become_a_scroll_region
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_an_effort_map_renders_its_destination_counts_and_fog
test_a_map_with_no_fog_says_the_remaining_work_is_sharp
test_a_home_with_no_effort_maps_renders_no_band_at_all
test_more_than_one_effort_map_each_gets_its_own_card

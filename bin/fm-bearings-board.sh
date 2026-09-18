#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh todos <snapshot.json|-> <data.json>
#   fm-bearings-board.sh validate <data.json>
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh path
#
# build      Validate the payload and inject it into a fresh copy of the shipped
#            template at the stable board path. Establish or resume the Lavish
#            session on that board BEFORE binding and arming its answer source,
#            so a registered poll can never race a session that does not exist.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
# path       Print the stable board path for this home.
# validate   Run build's payload checks alone and print `valid: <path>`.
# todos      Print <data.json> with every row's todos (and each call's blocks)
#            generated from a `fm-bearings-snapshot.sh --json` snapshot; the
#            fill rules are documented above command_todos below.
#
# The optional `maps` array carries one card per hand-maintained effort map
# under data/maps/*.md - destination, decided and open counts, remaining fog,
# and out-of-scope notes. No fleet snapshot owns that material, so the composer
# reads the maps directly (`effort-maps` owns the file format). Omitting the
# key renders no band at all, which is what a home with no maps produces.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# A Captain's Call item's `recommend_value` must name one of that item's own
# `options` values whenever the item carries options. An item that leans on its
# freeform box and carries none may still declare one: the recommendation is
# itself an answer value, and the template offers it as that card's option
# rather than rendering a card the captain cannot click.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def todo_step:
      type == "object" and (.text | nonempty_string)
      and (.state == "done" or .state == "current" or .state == "blocked" or .state == "todo")
      and ((has("by") | not) or (.by == "captain" or .by == "firstmate" or .by == "worker"));
    def todos_list:
      has("todos") and (.todos | type == "array") and (.todos | length > 0)
      and ([.todos[] | todo_step] | all)
      and ([.todos[] | select(.state == "current")] | length <= 1);
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and ((.options | length) == 0
            or (.recommend_value as $recommend | [.options[].value] | index($recommend) != null))))
      and ((has("blocks") | not)
        or ((.blocks | type == "array") and ([.blocks[] | nonempty_string] | all)))
      and todos_list
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def underway_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string)
      and optional_string("title") and todos_list;
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url");
    def map_item:
      type == "object"
      and (.title | nonempty_string)
      and (.destination | type == "string")
      and (.decided | type == "number") and (.decided >= 0) and (.decided | floor == .)
      and (.open | type == "number") and (.open >= 0) and (.open | floor == .)
      and ((has("fog") | not) or ((.fog | type == "array") and ([.fog[] | nonempty_string] | all)))
      and ((has("out_of_scope") | not)
        or ((.out_of_scope | type == "array") and ([.out_of_scope[] | nonempty_string] | all)));
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and (if .kind == "warning" then .dispatchable == false else true end)
      and todos_list;
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
    and ((has("maps") | not)
      or ((.maps | type == "array") and ([.maps[] | map_item] | all)))
  ' "$1" >/dev/null
}

# Name every malformed todos list, so a refused board says which item and which
# step to fix instead of only that the payload failed the contract.
todos_errors() {  # <data.json>
  jq -r '
    def where($section; $i): "\($section)[\($i)] (\(.key // .id // "no id"))";
    def step_problems($w):
      if (has("todos") | not) then "\($w) has no todos list; give it at least one step"
      elif (.todos | type) != "array" then "\($w) todos is not a list"
      elif (.todos | length) == 0 then "\($w) todos is empty; give it at least one step"
      else
        (.todos | to_entries[] | .key as $n | .value
          | if type != "object" then "\($w) todos[\($n)] is not a step object"
            elif ((.text | type) != "string" or (.text | length) == 0) then "\($w) todos[\($n)] has no text"
            elif (.state | IN("done", "current", "blocked", "todo") | not) then
              "\($w) todos[\($n)] state \(.state | tojson) is not one of done, current, blocked, todo"
            elif has("by") and (.by | IN("captain", "firstmate", "worker") | not) then
              "\($w) todos[\($n)] by \(.by | tojson) is not one of captain, firstmate, worker"
            else empty end),
        (if ([.todos[] | objects | select(.state == "current")] | length) > 1
         then "\($w) todos marks more than one step current; mark only the step the item is at"
         else empty end)
      end;
    def blocks_problems($w):
      if has("blocks") and ((.blocks | type) != "array"
          or ([.blocks[] | type == "string" and length > 0] | all | not))
      then "\($w) blocks is not a list of ids" else empty end;
    def section($name):
      (.[$name] // []) | if type == "array" then to_entries[]
        | .key as $i | .value | objects | where($name; $i) as $w
        | step_problems($w), (if $name == "captains_call" then blocks_problems($w) else empty end)
        else empty end;
    if type == "object" then section("captains_call"), section("underway"), section("charted") else empty end
  ' "$1"
}

check_payload() {  # <data.json>
  local data=$1 problems
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  problems=$(todos_errors "$data") || fail "cannot read the board data todos: $data"
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed 's/^/fm-bearings-board: /' >&2
    fail "board data does not satisfy $BOARD_SCHEMA: malformed todos in $data"
  fi
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
}

# Fill each Captain's Call, Underway, and Charted Next row's `todos` - and each
# call's `blocks` - from the fm-bearings.v1 snapshot, so steps are generated
# from structured records instead of hand-authored. A row that already carries
# its own todos or blocks keeps them. The fill rules:
#   call        decision/credential: "Your call: <title>" (current, captain),
#               then firstmate acting on the answer. merge.<id>: checks green
#               (done), the captain's merge word (current), merge and clean up.
#   sources     prose comes only from the composer's own row text (an underway
#               `doing`, a queued `reason`), never from the snapshot's shortened
#               display strings. Dates and ids come only from the snapshot's
#               structured fields (a gate's `until` and `blocker_ids`), never
#               from parsing `reason` or splitting `blocked_by`.
#   underway    the kind's lifecycle. ship: instructions and worker, build,
#               validate, PR open with checks green, the captain's merge word,
#               merge and clean up. scout: instructions and worker, investigate,
#               report written, findings relayed. The step it is AT is: done ->
#               merge word (ship) or relay (scout); a recorded PR -> PR step; a
#               parked state or a detail naming validation -> validate; else
#               build/investigate. That step's text carries the row's `doing`;
#               working is current, paused is current with its outside wait, and
#               parked, blocked, failed, and unknown are blocked. A secondmate
#               row is one current step naming its child work.
#   charted     prerequisites only: one blocked step per unresolved blocker id
#               (a blocker that is an open call reads "your call" and is owned
#               by the captain), then "Waits until <date>: <row reason>" for a
#               gate with an `until` date, or "Held: <row reason>" for a gate
#               that carries a hold with no date (either without the reason
#               when the row gives none), then "Start: dispatch a worker". A
#               warning row is one repair step.
#   blocks      a call's key is added to the blocks of every call whose task id
#               appears in a queued row's unresolved blockers.
command_todos() {  # <snapshot.json|-> <payload.json>
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  local snap=$1 data=$2
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  if [ "$snap" = - ]; then snap=/dev/stdin
  else [ -f "$snap" ] || fail "snapshot does not exist: $snap"; fi
  jq -n --slurpfile snapdoc "$snap" --slurpfile board "$data" '
    ($snapdoc[0] // {}) as $snap
    | $board[0] as $b
    | def step($text; $state; $by): {text: $text, state: $state, by: $by};
      ($snap.recorded_prs // [] | map(.id)) as $pr_ids
    | ($b.captains_call // [] | map({key: .key, value: .title}) | from_entries) as $call_titles
    | ([$b.underway[]?, $b.charted[]?] | map({key: .id, value: (.title // .doing // .id)}) | from_entries) as $row_titles
    | ($snap.gates // [] | map({key: .id, value: .}) | from_entries) as $gates
    | ($snap.in_flight // [] | map({key: .id, value: .}) | from_entries) as $flight
    | def plain($d):
        if ($d | test("^harness busy")) then "the worker is active"
        elif $d == "harness idle" then "the worker is idle"
        elif $d == "run cancelled" then "the validation run was cancelled"
        else $d end;
      def blockers($g): $g.blocker_ids // [];
      def lifecycle($names; $bys; $at; $state; $detail):
        [range(0; $names | length) as $i
          | if $i < $at then step($names[$i]; "done"; $bys[$i])
            elif $i > $at then step($names[$i]; "todo"; $bys[$i])
            else step($names[$i] + (if $detail == "" then "" else ": " + $detail end)
                   + (if $state == "paused" then " (waiting on an outside delay)" else "" end);
                   (if $state == "working" or $state == "paused" or $state == "done" then "current" else "blocked" end);
                   $bys[$i]) end];
      def underway_todos($t):
        ($flight[$t.id] // {}) as $f
        | (($f.state // $t.state // "unknown")) as $state
        | (plain($t.doing // "")) as $detail
        | (($f.kind // $t.kind // "ship")) as $kind
        | if $kind == "secondmate" then [step("Second mate working: " + $detail; "current"; "worker")]
          elif $kind == "scout" then
            lifecycle(["Instructions written, worker started", "Investigate", "Report written", "Findings relayed to you"];
              ["firstmate", "worker", "worker", "firstmate"];
              (if $state == "done" then 3 else 1 end); $state;
              (if $state == "done" then "" else $detail end))
          else
            lifecycle(["Instructions written, worker started", "Build the change", "Validate: review, tests, docs, CI",
                "PR open with checks green", "Your merge word", "Merge and clean up"];
              ["firstmate", "worker", "worker", "worker", "captain", "firstmate"];
              (if $state == "done" then 4
               elif ($pr_ids | index($t.id)) != null then 3
               elif $state == "parked" or ($detail | test("\\b(run|validat\\w*|review|tests?|lint|ci|checks?|pipeline|gate)\\b"; "i")) then 2
               else 1 end); $state;
              (if $state == "done" then "" else $detail end))
          end;
      def call_todos($c):
        if $c.type == "merge" then
          [step("Validation passed, checks green"; "done"; "worker"),
           step("Your merge word"; "current"; "captain"),
           step("Merge and clean up"; "todo"; "firstmate")]
        elif $c.type == "credential" then
          [step("Provide it: " + $c.title; "current"; "captain"),
           step("Firstmate resumes the work that waits on it"; "todo"; "firstmate")]
        else
          [step("Your call: " + $c.title; "current"; "captain"),
           step("Firstmate acts on your answer"; "todo"; "firstmate")]
        end;
      def charted_todos($t):
        if $t.kind == "warning" then
          [step("Repair: " + (if ($t.reason // "") != "" then $t.reason else $t.title end); "current"; "firstmate")]
        else
          ($gates[$t.id] // {}) as $g
          | [blockers($g)[] as $id
              | if $call_titles[$id] != null then step("Waits on your call: " + $call_titles[$id]; "blocked"; "captain")
                else step("Waits on " + ($row_titles[$id] // $id); "blocked"; "firstmate") end]
            + ((if ($t.reason // "") != "" then ": " + $t.reason else "" end) as $why
               | if ($g.until // null) != null then [step("Waits until " + $g.until + $why; "blocked"; "firstmate")]
                 elif ($g.reason // "-") != "-" and $g.reason != "" then [step("Held" + $why; "blocked"; "firstmate")]
                 else [] end)
            + [step("Start: dispatch a worker"; "todo"; "firstmate")]
        end;
      ([$gates[] | . as $g | blockers($g)[] | select($call_titles[.] != null) | {call: ., id: $g.id}]
        | group_by(.call) | map({key: .[0].call, value: map(.id)}) | from_entries) as $blocks
    | $b
    | .captains_call //= [] | .underway //= [] | .charted //= []
    | .captains_call |= map(
        (if has("todos") then . else .todos = call_todos(.) end)
        | (if has("blocks") or ($blocks[.key] // null) == null then . else .blocks = $blocks[.key] end))
    | .underway |= map(if has("todos") then . else .todos = underway_todos(.) end)
    | .charted |= map(if has("todos") then . else .todos = charted_todos(.) end)
  '
}

command_validate() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  check_payload "$1"
  printf 'valid: %s\n' "$1"
}

command_build() {
  local data=${1-} board json tmp sid extracted
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  check_payload "$data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact the board data"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  lavish-axi "$board" || fail "cannot establish the board Lavish session"
  printf 'served: %s\n' "$board"

  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  if "$SCRIPT_DIR/fm-procevent.sh" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid"; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  validate) shift; command_validate "$@" ;;
  todos) shift; command_todos "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

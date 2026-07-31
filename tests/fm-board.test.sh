#!/usr/bin/env bash
# Behavior tests for the captain-facing kanban board generator (bin/fm-board.sh).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    printf 'work in progress\nesc to interrupt\n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/build-worktree" "$home/projects/review-worktree" "$home/data/maps"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] build-task - Build The Widget (repo: alpha) (kind: ship) (since 2026-07-29)
  Widget assembly in progress.
- [ ] review-task - Review The Rudder (repo: alpha) (kind: ship) (since 2026-07-29)

## Queued
- [ ] decide-task - Pick The Mast Color (repo: alpha) (kind: captain) (since 2026-07-30) (hold: Two finishes fit; captain picks one) (hold-kind: captain)
  Decision key: mast-color
- [ ] queued-task - Queued Chore blocked-by: build-task (repo: alpha) (kind: ship) (since 2026-07-30)

## Done
- [x] landed-task - Landed Improvement https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-28)
EOF
  fm_write_meta "$home/state/build-task.meta" \
    "window=firstmate:fm-build-task" \
    "worktree=$home/projects/build-worktree" \
    "project=alpha" \
    "harness=codex" \
    "model=opus" \
    "effort=high" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf 'working: assembling the widget\n' > "$home/state/build-task.status"
  fm_write_meta "$home/state/review-task.meta" \
    "window=firstmate:fm-review-task" \
    "worktree=$home/projects/review-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'done: PR https://github.com/kunchenguid/firstmate/pull/9 checks green\n' > "$home/state/review-task.status"
  cat > "$home/data/maps/alpha-refit.md" <<'EOF'
# Effort map: alpha refit

## Destination
Alpha sails clean: refit landed and every mast decision settled.

## Decisions so far
- keel shape approved
- sail cut approved

## Not yet specified
- rigging vendor

## Out of scope
- new hull

## Open captain decisions (live tickets)
- mast color
EOF
}

test_board_renders_columns_and_cards() {
  local home fakebin out html
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out="$home/board.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$BOARD" --out "$out" >/dev/null \
    || fail "board generation failed"
  [ -f "$out" ] || fail "board output file missing"
  html=$(cat "$out")

  local col
  for col in Decide Queued Building Review Landed; do
    assert_contains "$html" "$col" "board must contain the $col column"
  done

  assert_contains "$html" "Pick The Mast Color" "captain hold card must land in the board"
  assert_contains "$html" 'data-lavish-question="mast-color"' \
    "approval panel must carry the decision key from the backlog body"
  assert_contains "$html" 'type="radio"' "approval panel must offer radio options"
  assert_contains "$html" 'name="freetext"' "approval panel must offer a free-text override"
  assert_contains "$html" "window.lavish.queuePrompt" "interactions must queue Lavish prompts"

  assert_contains "$html" "Build The Widget" "in-flight card must render"
  assert_contains "$html" "crew: codex · opus · high effort" \
    "building card must show the assigned harness, model, and effort"
  assert_contains "$html" "Queued Chore" "queued card must render"
  assert_contains "$html" "blocked-by: build-task" "queued card must surface its blocker"
  assert_contains "$html" 'href="https://github.com/kunchenguid/firstmate/pull/9"' \
    "review card must link the armed PR"
  assert_contains "$html" "Landed Improvement" "done card must render in Landed"

  assert_contains "$html" "Alpha sails clean" "effort-map destination must render in the top band"
  assert_contains "$html" "2 decided" "effort-map decided count must render"
  assert_contains "$html" "1 open" "effort-map open count must render"

  assert_contains "$html" 'draggable="true"' "cards must be draggable"
  assert_contains "$html" "fbDrop" "columns must accept drops that queue move orders"
  pass "board renders all five columns, cards, decision panels, and effort maps"
}

test_review_and_decide_routing() {
  local home fakebin out html
  home=$(make_home routing)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out="$home/board.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$BOARD" --out "$out" >/dev/null \
    || fail "board generation failed"
  html=$(cat "$out")
  # Column routing: the PR-recorded task reaches Review, the hold reaches
  # Decide, and each card appears exactly once on the board.
  local review_col decide_col
  review_col=${html#*"🌊 Review"}
  assert_contains "$review_col" "Review The Rudder" "PR-recorded card must be in or after the Review column"
  decide_col=${html%%"🧭 Queued"*}
  assert_contains "$decide_col" "Pick The Mast Color" "captain hold must be in the Decide column"
  case "$html" in
    *"Review The Rudder"*"Review The Rudder"*) fail "cards must appear exactly once" ;;
  esac
  pass "captain holds route to Decide and PR-recorded work routes to Review"
}

test_approval_panels_stay_out_of_lists() {
  local home fakebin out
  home=$(make_home clipping)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out="$home/board.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$BOARD" --out "$out" >/dev/null \
    || fail "board generation failed"
  python3 - "$out" <<'PY' || fail "an approval details block is nested inside a list (clipping bug)"
import sys
from html.parser import HTMLParser

class Check(HTMLParser):
    VOID = {"meta", "link", "input", "br", "img", "progress", "hr"}
    def __init__(self):
        super().__init__()
        self.stack = []
        self.bad = False
    def handle_starttag(self, tag, attrs):
        if tag == "details" and "ul" in self.stack:
            self.bad = True
        if tag not in self.VOID:
            self.stack.append(tag)
    def handle_endtag(self, tag):
        if self.stack and self.stack[-1] == tag:
            self.stack.pop()

check = Check()
with open(sys.argv[1], encoding="utf-8") as f:
    check.feed(f.read())
sys.exit(1 if check.bad else 0)
PY
  pass "approval panels are siblings of the todo list, never nested in it"
}

test_default_output_path_and_empty_home() {
  local home fakebin
  home=$(make_home empty)
  fakebin=$(make_fakebin "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" "$BOARD" >/dev/null \
    || fail "board generation must succeed on an empty home"
  [ -f "$home/.lavish/fleet-board.html" ] \
    || fail "default output must land in \$FM_HOME/.lavish/fleet-board.html"
  assert_contains "$(cat "$home/.lavish/fleet-board.html")" "nothing here" \
    "empty columns must render an explicit placeholder"
  pass "default output path works and an empty fleet renders explicit placeholders"
}

test_board_renders_columns_and_cards
test_review_and_decide_routing
test_approval_panels_stay_out_of_lists
test_default_output_path_and_empty_home

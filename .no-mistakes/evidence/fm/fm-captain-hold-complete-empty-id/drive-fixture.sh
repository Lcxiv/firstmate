#!/usr/bin/env bash
# Manual driver: build a fixture of the reported shape and drive the real
# bin/fm-captain-hold.sh against it. Prints a transcript.
set -u
ROOT=$1; SCRIPT_TAG=$2
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-drive)
TASKS_AXI_BIN=$(command -v tasks-axi)
make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home"); fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}
run_captain() { local home=$1; shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
run_teardown() { local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-teardown.sh" "$id"; }
write_origin_meta() { fm_write_meta "$1/state/$2.meta" "window=firstmate:fm-$2" "worktree=$1/projects/missing-$2" \
  "project=$1/projects/sample" "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$2"; }
show() { echo "\$ fm-captain-hold.sh $*"; run_captain "$HOME_" "$@" 2>&1 | sed 's/^/  /'; echo "  [exit ${PIPESTATUS[0]}]"; }

echo "=== script under test: $SCRIPT_TAG ==="
echo
echo "### Shape A: durable meta whose recorded inventory names a task no longer in the backlog"
HOME_=$(make_home shapeA); id=jt-personal-data-purge-plan
mkdir -p "$HOME_/data/$id"; write_origin_meta "$HOME_" "$id"
run_captain "$HOME_" hold jt-personal-data-purge-execute --title "Choose purge scope" --reason "captain purge scope choice pending" --repo sample >/dev/null
printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$id" >> "$HOME_/state/$id.meta"
printf 'done: plan written; captain calls held\n' > "$HOME_/state/$id.status"
printf '# plan\n' > "$HOME_/data/$id/report.md"
show complete "$id" --none
show complete "$id" jt-personal-data-purge-execute
show verify "$id"
echo "### Neighbours given an empty id"
show answer '' --decision-file /dev/null
show hold '' --title x --reason y
show binding ''
echo "\$ fm-decision-hold.sh complete '' --none"; PATH="$HOME_/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_" FM_STATE_OVERRIDE="$HOME_/state" FM_DATA_OVERRIDE="$HOME_/data" FM_CONFIG_OVERRIDE="$HOME_/config" "$ROOT/bin/fm-decision-hold.sh" complete '' --none 2>&1 | sed 's/^/  /'; echo "  [exit ${PIPESTATUS[0]}]"
echo
echo "### Shape B: calls answered on a different task; complete both forms, verify, teardown"
HOME_=$(make_home shapeB); id=jt-personal-data-purge-plan; ans=jt-personal-data-purge-execute
mkdir -p "$HOME_/data/$id"
(cd "$HOME_" && tasks-axi add "$id" "Plan the purge" --kind scout --repo sample --start >/dev/null)
write_origin_meta "$HOME_" "$id"
printf 'working: surveying\nneeds-decision [key=scope]: purge exports only, or filter content too\n' > "$HOME_/state/$id.status"
printf '# plan\n\nThe captain must choose the purge scope.\n' > "$HOME_/data/$id/report.md"
run_captain "$HOME_" hold "$ans" --title "Choose purge scope" --reason "captain purge scope choice pending" --repo sample --origin "$id" >/dev/null
printf 'Filter content as well as paths.\n' > "$HOME_/decision.txt"
run_captain "$HOME_" answer "$ans" --decision-file "$HOME_/decision.txt" >/dev/null
FM_STATE_OVERRIDE="$HOME_/state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$HOME_/state" "$HOME_/state/$id.status"
show complete "$id" "$ans"
echo "  meta now: $(grep -E '^decision' "$HOME_/state/$id.meta" | tr '\n' ' ')"
show complete "$id" --none
show verify "$id"
echo "\$ fm-teardown.sh $id"; run_teardown "$HOME_" "$id" 2>&1 | sed 's/^/  /'; echo "  [exit ${PIPESTATUS[0]}]"
[ -e "$HOME_/state/$id.meta" ] && echo "  meta STILL PRESENT" || echo "  state/$id.meta removed: cleanup proceeded"

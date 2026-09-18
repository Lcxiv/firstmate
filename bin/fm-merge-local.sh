#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# Local-origin mirrors (bin/fm-home-seed.sh <project>=<checkout>): a secondmate
# home whose registry marks a local-only project +local-origin holds a clone
# whose origin is the main home's checkout. That clone is not the project's
# authority, so this script refuses to land anything into it; the worker pushes
# fm/<id> to that origin instead. The main home then lands the pushed branch
# with --secondmate, which reads the task record from that secondmate's own home,
# confirms the local-origin shape from both registries, and fast-forwards the
# checkout the mirror's origin names under exactly the same guards. Landing
# therefore stays in one home, and the registry flag, not a guess from the
# clone, decides which path applies.
# Usage: fm-merge-local.sh <task-id>
#        fm-merge-local.sh --secondmate <secondmate-id> <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
USAGE="usage: fm-merge-local.sh [--secondmate <secondmate-id>] <task-id>"
SECONDMATE=
if [ "${1:-}" = --secondmate ]; then
  SECONDMATE=${2:?$USAGE}
  shift 2
fi
ID=${1:?$USAGE}
[ $# -eq 1 ] || { echo "$USAGE" >&2; exit 1; }

project_origin_in_home() {  # <home> <data-dir> <project>; that home's registered clone shape
  FM_HOME="$1" FM_DATA_OVERRIDE="$2" "$FM_ROOT/bin/fm-project-mode.sh" --origin "$3" 2>/dev/null || echo default
}

if [ -n "$SECONDMATE" ]; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$SECONDMATE" \
    || { echo "error: secondmate $SECONDMATE has no single parseable route in $DATA/secondmates.md" >&2; exit 1; }
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] \
    || { echo "error: secondmate $SECONDMATE is a remote route; a local-origin mirror exists only in a local home" >&2; exit 1; }
  SM_HOME=$SECONDMATE_REGISTRY_HOME
  [ -d "$SM_HOME" ] || { echo "error: secondmate $SECONDMATE home $SM_HOME is not a directory" >&2; exit 1; }
  [ "$(cat "$SM_HOME/.fm-secondmate-home" 2>/dev/null || true)" = "$SECONDMATE" ] \
    || { echo "error: $SM_HOME is not the seeded home of secondmate $SECONDMATE" >&2; exit 1; }
  META="$SM_HOME/state/$ID.meta"
  [ -f "$META" ] || { echo "error: no meta for task $ID in secondmate $SECONDMATE at $META" >&2; exit 1; }
else
  META="$STATE/$ID.meta"
  [ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
PROJ_NAME=$(basename "$PROJ")

if [ -n "$SECONDMATE" ]; then
  [ "$(project_origin_in_home "$SM_HOME" "$SM_HOME/data" "$PROJ_NAME")" = local-origin ] || {
    echo "error: $PROJ_NAME is not registered +local-origin in secondmate $SECONDMATE; only a local-origin mirror's pushed branch is landed from the main home" >&2
    exit 1
  }
  read -r main_mode _ <<EOF
$(FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME" 2>/dev/null || true)
EOF
  [ "$main_mode" = local-only ] || {
    echo "error: $PROJ_NAME is registered ${main_mode:-unknown} in this home, not local-only; refusing to land a mirror's branch into it" >&2
    exit 1
  }
  ORIGIN_PATH=$(git -C "$PROJ" remote get-url origin 2>/dev/null || true)
  case "$ORIGIN_PATH" in
    /*) ;;
    *) echo "error: secondmate $SECONDMATE's $PROJ_NAME clone has origin '${ORIGIN_PATH:-none}', not a local checkout path" >&2; exit 1 ;;
  esac
  # A bare repository has no top level, so this also refuses one.
  ORIGIN_TOP=$(git -C "$ORIGIN_PATH" rev-parse --show-toplevel 2>/dev/null) \
    && [ "$(cd "$ORIGIN_PATH" && pwd -P)" = "$(cd "$ORIGIN_TOP" && pwd -P)" ] \
    || { echo "error: local origin $ORIGIN_PATH for $PROJ_NAME is not the top of a working checkout" >&2; exit 1; }
  # The checkout the mirror was cloned from is the one landing advances.
  PROJ=$ORIGIN_PATH
elif [ "$(project_origin_in_home "$FM_HOME" "$DATA" "$PROJ_NAME")" = local-origin ]; then
  echo "REFUSED: $PROJ_NAME in this home is a local-origin mirror, not the project's authority; nothing lands here." >&2
  echo "Have the worker push fm/$ID to origin, then the main firstmate lands it with: bin/fm-merge-local.sh --secondmate <this secondmate's id> $ID" >&2
  exit 1
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

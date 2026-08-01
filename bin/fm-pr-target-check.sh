#!/usr/bin/env bash
# fm-pr-target-check.sh - fail closed when no-mistakes would open a PR against
# a repository other than the target worktree's origin.
#
# no-mistakes owns PR creation and stores its PR base separately from git after
# initialization.
# A later origin change can therefore leave the gate pushing one repository's
# branch while passing a different repository to `gh pr create --repo`.
# This check reads the public `no-mistakes status` surface and requires its
# registered `remote:` PR base to identify the same repository as git origin.
# Equivalent HTTPS and SSH spellings compare by normalized host/project identity.
#
# The human-readable `remote:` line of `no-mistakes status` is LOAD-BEARING here:
# no-mistakes exposes no structured or JSON form of the stored PR base (neither
# `status` nor the agent-facing `axi` surface has a machine-readable field for
# it), so scraping that prose line is the only way to read the registration.
# Verified against the version firstmate requires, no-mistakes v1.41.2; a layout
# change in a future version fails this check closed rather than passing blind.
# Only status stdout is parsed - stderr is captured separately, because git
# sideband progress lines literally begin with "remote: " and would otherwise be
# scraped as extra PR bases.
#
# Usage:
#   fm-pr-target-check.sh [worktree]
#
# The worktree defaults to the current directory.
# This is a task-worktree check: it reads the no-mistakes registration of the
# worktree it is pointed at, so it is meaningful only where that worktree is an
# initialized no-mistakes repo (the crewmate's own checkout after
# `no-mistakes init`, per the generated brief's setup preflight). It is not a
# gate-side guard: a no-mistakes gate worktree is a checkout of the bare gate
# repo and is never itself initialized, so it has no registration to compare.
# To target another repository deliberately, change origin, run
# `no-mistakes init`, and then rerun this check.
set -u

die() {
  printf 'fm-pr-target-check: %s\n' "$*" >&2
  exit 1
}

normalize_remote_identity() {
  local raw=$1 rest authority path identity
  raw=${raw%/}
  case "$raw" in
    *://*)
      rest=${raw#*://}
      authority=${rest%%/*}
      [ "$rest" != "$authority" ] || return 1
      path=${rest#*/}
      authority=${authority##*@}
      identity="$authority/$path"
      ;;
    *:*)
      authority=${raw%%:*}
      path=${raw#*:}
      authority=${authority##*@}
      [ -n "$authority" ] && [ -n "$path" ] || return 1
      identity="$authority/$path"
      ;;
    *)
      identity=$raw
      ;;
  esac
  identity=${identity%/}
  identity=${identity%.git}
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

[ "$#" -le 1 ] || die "usage: fm-pr-target-check.sh [worktree]"
WORKTREE=${1:-.}
ROOT=$(cd "$WORKTREE" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git worktree: $WORKTREE"
command -v no-mistakes >/dev/null 2>&1 \
  || die "no-mistakes is required to verify the registered PR base"
ORIGIN=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null) \
  || die "origin is missing in $ROOT"
[ -n "$ORIGIN" ] || die "origin has an empty URL in $ROOT"

STATUS_ERR="$(mktemp)" || die "could not create a temporary file"
trap 'rm -f "$STATUS_ERR"' EXIT
STATUS=$(cd "$ROOT" && NO_COLOR=1 TERM=dumb no-mistakes status 2>"$STATUS_ERR") \
  || die "no-mistakes status failed in $ROOT: $(cat "$STATUS_ERR")"
REGISTERED=$(printf '%s\n' "$STATUS" \
  | sed -n 's/^[[:space:]]*remote:[[:space:]]*//p')
[ -n "$REGISTERED" ] \
  || die "no-mistakes status did not report a registered remote PR base"
case "$REGISTERED" in
  *$'\n'*) die "no-mistakes status reported more than one remote PR base" ;;
esac

ORIGIN_ID=$(normalize_remote_identity "$ORIGIN") \
  || die "could not normalize origin URL: $ORIGIN"
REGISTERED_ID=$(normalize_remote_identity "$REGISTERED") \
  || die "could not normalize registered PR base: $REGISTERED"

if [ "$ORIGIN_ID" != "$REGISTERED_ID" ]; then
  die "refusing no-mistakes delivery: registered PR base $REGISTERED does not match origin $ORIGIN; set origin deliberately, run 'no-mistakes init', and rerun this check"
fi

printf 'fm-pr-target-check: registered PR base %s matches origin %s\n' \
  "$REGISTERED" "$ORIGIN"

#!/usr/bin/env bash
# Behavior tests for the GitHub default-repository pin.
#
# Regression origin: task worktrees carry both origin (the fork firstmate pushes
# to) and upstream (the parent it was forked from). With no gh-resolved pin, gh
# ranks remotes by NAME and places upstream above origin, so every unqualified
# lookup answered from the parent. Because the fork inherited the parent's
# history the same low PR numbers exist in both, so three separate workers were
# shown a real, plausible PR of the same number and each concluded its own PR
# did not exist.
#
# Every assertion below reads the repository an unqualified lookup actually
# resolves to, through gh itself, so a test passes only when a real lookup would
# land on origin.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-gh-default-repo-lib.sh
. "$ROOT/bin/fm-gh-default-repo-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gh-default-repo)

ORIGIN_URL=https://github.com/Lcxiv/firstmate.git
UPSTREAM_URL=https://github.com/kunchenguid/firstmate.git
ORIGIN_NWO=Lcxiv/firstmate
UPSTREAM_NWO=kunchenguid/firstmate

command -v gh >/dev/null 2>&1 ||
  fail "gh is not on PATH; this suite resolves repositories through gh and must not pass without it"

# Echo the repository an unqualified lookup from <dir> targets, or "unset" when
# no pin decides it and gh would fall back to its own remote ranking.
resolved_repo() {  # <dir>
  fm_gh_default_repo_resolved "$1" || echo unset
}

make_fork_clone() {  # <dir> [<extra-remote-name>]
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email firstmate@example.invalid
  git -C "$dir" config user.name firstmate
  git -C "$dir" commit -q --allow-empty -m base
  git -C "$dir" remote add origin "$ORIGIN_URL"
  git -C "$dir" remote add upstream "$UPSTREAM_URL"
}

test_unpinned_fork_clone_does_not_resolve_to_origin() {
  local dir="$TMP_ROOT/unpinned"
  make_fork_clone "$dir"
  [ "$(resolved_repo "$dir")" != "$ORIGIN_NWO" ] ||
    fail "a fork clone with no pin already resolved to origin; the reproduction no longer reproduces"
  pass "an unpinned fork clone does not resolve lookups to origin"
}

test_pin_resolves_lookups_to_origin() {
  local dir="$TMP_ROOT/pinned" got
  make_fork_clone "$dir"
  fm_gh_default_repo_ensure "$dir" || fail "pinning origin failed on a fork clone"
  got=$(resolved_repo "$dir")
  [ "$got" != "$UPSTREAM_NWO" ] ||
    fail "lookups still resolve to the upstream parent '$UPSTREAM_NWO' after pinning origin"
  [ "$got" = "$ORIGIN_NWO" ] ||
    fail "lookups resolve to '$got', not origin '$ORIGIN_NWO'"
  pass "pinning origin makes unqualified lookups resolve to the fork"
}

test_resolution_from_a_worktree_path_lands_on_origin() {
  local primary="$TMP_ROOT/wt-primary" linked="$TMP_ROOT/wt-linked" got
  make_fork_clone "$primary"
  git -C "$primary" worktree add -q "$linked" -b task
  [ "$(resolved_repo "$linked")" != "$ORIGIN_NWO" ] ||
    fail "the task worktree resolved to origin before it was pinned"
  fm_gh_default_repo_ensure "$linked" || fail "pinning origin failed from the task worktree"
  got=$(resolved_repo "$linked")
  [ "$got" != "$UPSTREAM_NWO" ] ||
    fail "a lookup from the task worktree still resolves to the upstream parent '$UPSTREAM_NWO'"
  [ "$got" = "$ORIGIN_NWO" ] ||
    fail "a lookup from the task worktree resolves to '$got', not origin '$ORIGIN_NWO'"
  pass "repository resolution from a task worktree path lands on origin"
}

test_pinning_a_worktree_also_fixes_its_primary_checkout() {
  local primary="$TMP_ROOT/shared-primary" linked="$TMP_ROOT/shared-linked" got
  make_fork_clone "$primary"
  git -C "$primary" worktree add -q "$linked" -b task
  fm_gh_default_repo_ensure "$linked" || fail "pinning origin failed from the task worktree"
  got=$(resolved_repo "$primary")
  [ "$got" != "$UPSTREAM_NWO" ] ||
    fail "the primary checkout still resolves to the upstream parent after its worktree was pinned"
  [ "$got" = "$ORIGIN_NWO" ] ||
    fail "the primary checkout resolves to '$got', not origin '$ORIGIN_NWO'"
  pass "pinning a task worktree leaves its primary checkout resolving to origin"
}

test_a_competing_upstream_pin_is_cleared() {
  local dir="$TMP_ROOT/competing" got
  make_fork_clone "$dir"
  # gh takes the first pin in its own name order, and upstream outranks origin,
  # so a stale pin here would survive writing origin's and keep winning.
  git -C "$dir" config remote.upstream.gh-resolved base
  [ "$(resolved_repo "$dir")" = "$UPSTREAM_NWO" ] ||
    fail "a pin on upstream did not capture lookups; the precedence this clears no longer holds"
  fm_gh_default_repo_ensure "$dir" || fail "pinning origin failed with a competing upstream pin"
  got=$(resolved_repo "$dir")
  [ "$got" != "$UPSTREAM_NWO" ] ||
    fail "the competing upstream pin still captures lookups after pinning origin"
  [ "$got" = "$ORIGIN_NWO" ] ||
    fail "lookups resolve to '$got', not origin '$ORIGIN_NWO'"
  pass "a competing upstream pin is cleared so origin wins"
}

test_pinning_is_idempotent() {
  local dir="$TMP_ROOT/idempotent"
  make_fork_clone "$dir"
  fm_gh_default_repo_ensure "$dir" || fail "the first pin failed"
  fm_gh_default_repo_ensure "$dir" || fail "re-pinning an already pinned clone failed"
  [ "$(resolved_repo "$dir")" = "$ORIGIN_NWO" ] ||
    fail "re-pinning moved resolution away from origin"
  pass "pinning an already pinned clone is a no-op success"
}

test_clone_without_origin_is_untouched() {
  local dir="$TMP_ROOT/remoteless"
  mkdir -p "$dir"
  git -C "$dir" init -q
  fm_gh_default_repo_ensure "$dir" || fail "a clone with no origin was refused instead of skipped"
  [ -z "$(git -C "$dir" config --get-regexp 'gh-resolved' 2>/dev/null || true)" ] ||
    fail "a clone with no origin had a default repository written into it"
  pass "a clone with no origin remote is left untouched"
}

test_non_github_origin_is_untouched() {
  local dir="$TMP_ROOT/gitlab"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin https://gitlab.com/Lcxiv/firstmate.git
  fm_gh_default_repo_ensure "$dir" || fail "a non-GitHub origin was refused instead of skipped"
  [ -z "$(git -C "$dir" config --get-regexp 'gh-resolved' 2>/dev/null || true)" ] ||
    fail "a non-GitHub origin had a GitHub default repository written into it"
  pass "an origin on another host is left untouched"
}

test_remote_url_shapes_resolve_to_the_same_repository() {
  local url got
  for url in \
    "https://github.com/Lcxiv/firstmate.git" \
    "https://github.com/Lcxiv/firstmate" \
    "git@github.com:Lcxiv/firstmate.git" \
    "ssh://git@github.com/Lcxiv/firstmate.git"; do
    got=$(fm_gh_default_repo_nwo_from_url "$url") ||
      fail "origin URL '$url' was not recognised as a GitHub repository"
    [ "$got" = "$ORIGIN_NWO" ] ||
      fail "origin URL '$url' resolved to '$got', not '$ORIGIN_NWO'"
  done
  for url in \
    "https://gitlab.com/Lcxiv/firstmate.git" \
    "/srv/local/mirror.git" \
    "https://github.com/owneronly"; do
    ! fm_gh_default_repo_nwo_from_url "$url" >/dev/null 2>&1 ||
      fail "'$url' was wrongly treated as a GitHub repository"
  done
  pass "every origin URL shape resolves to the same repository"
}

test_unpinned_fork_clone_does_not_resolve_to_origin
test_pin_resolves_lookups_to_origin
test_resolution_from_a_worktree_path_lands_on_origin
test_pinning_a_worktree_also_fixes_its_primary_checkout
test_a_competing_upstream_pin_is_cleared
test_pinning_is_idempotent
test_clone_without_origin_is_untouched
test_non_github_origin_is_untouched
test_remote_url_shapes_resolve_to_the_same_repository

#!/usr/bin/env bash
# Behavior tests for the no-mistakes PR-base guard.
#
# Regression origin: the firstmate gate pushed a feature branch to
# Lcxiv/firstmate but retained kunchenguid/firstmate as its registered PR base,
# so no-mistakes passed the parent to `gh pr create --repo` and opened PR 1438
# there.
# The public checker and the gate-context lint integration must both refuse that
# split routing before no-mistakes reaches its push and PR steps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-target-check.sh"
LINT="$ROOT/bin/fm-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-target-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] || exit 2
printf '    repo:  %s\n' "${NM_STATUS_REPO:-/fixture}"
printf '  remote:  %s\n' "$NM_STATUS_REMOTE"
if [ -n "${NM_STATUS_FORK:-}" ]; then
  printf '    fork:  %s\n' "$NM_STATUS_FORK"
fi
printf '    gate:  /fixture/gate.git\n'
printf '  daemon:  running\n'
SH

cat > "$FAKEBIN/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
fi
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/shellcheck"

make_repo() {
  local path=$1 origin=$2
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" remote add origin "$origin"
}

test_refuses_stale_parent_base() {
  local repo out rc=0
  repo="$TMP_ROOT/stale-parent"
  make_repo "$repo" https://github.com/Lcxiv/firstmate.git
  out=$(PATH="$FAKEBIN:$PATH" \
    NM_STATUS_REMOTE=https://github.com/kunchenguid/firstmate.git \
    NM_STATUS_FORK=https://github.com/Lcxiv/firstmate.git \
    "$CHECK" "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "PR-base guard accepted the stale parent registration"
  assert_contains "$out" "registered PR base https://github.com/kunchenguid/firstmate.git does not match origin https://github.com/Lcxiv/firstmate.git" \
    "PR-base guard did not explain the split routing"
  pass "PR-base guard refuses the reproduced parent/fork split"
}

test_accepts_the_origin_repository() {
  local repo out
  repo="$TMP_ROOT/matching-origin"
  make_repo "$repo" git@github.com:Lcxiv/firstmate.git
  out=$(PATH="$FAKEBIN:$PATH" \
    NM_STATUS_REMOTE=https://github.com/Lcxiv/firstmate.git \
    NM_STATUS_FORK=https://github.com/Lcxiv/firstmate.git \
    "$CHECK" "$repo" 2>&1) \
    || fail "PR-base guard rejected equivalent SSH and HTTPS repository identities"
  assert_contains "$out" "matches origin" "PR-base guard did not report its successful comparison"
  pass "PR-base guard accepts a registered base matching origin"
}

test_fails_closed_on_unreadable_registration() {
  local repo broken out rc=0
  repo="$TMP_ROOT/unreadable-registration"
  broken="$TMP_ROOT/broken-bin"
  make_repo "$repo" https://github.com/Lcxiv/firstmate.git
  mkdir -p "$broken"
  cat > "$broken/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'gate state unavailable\n'
exit 0
SH
  chmod +x "$broken/no-mistakes"
  out=$(PATH="$broken:$PATH" "$CHECK" "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "PR-base guard passed without a registered remote"
  assert_contains "$out" "did not report a registered remote PR base" \
    "PR-base guard did not explain the unreadable registration"
  pass "PR-base guard fails closed when no-mistakes omits the PR base"
}

test_gate_lint_refuses_before_shellcheck() {
  local out rc=0
  out=$(env -u FM_GATE_REFUSE_BYPASS \
    NO_MISTAKES_GATE=1 \
    NM_STATUS_REMOTE=https://github.com/kunchenguid/firstmate.git \
    NM_STATUS_FORK=https://github.com/Lcxiv/firstmate.git \
    PATH="$FAKEBIN:$PATH" \
    "$LINT" "$CHECK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "gate-context lint passed a stale parent PR base"
  assert_contains "$out" "refusing no-mistakes delivery" \
    "gate-context lint did not invoke the PR-base guard"
  pass "gate-context lint blocks the stale PR base before delivery"
}

test_normal_lint_does_not_require_gate_state() {
  local out
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    NM_STATUS_REMOTE=https://github.com/kunchenguid/firstmate.git \
    PATH="$FAKEBIN:$PATH" \
    "$LINT" "$CHECK" 2>&1) \
    || fail "ordinary lint was coupled to local no-mistakes routing"$'\n'"$out"
  pass "ordinary lint and CI remain independent of local gate state"
}

test_refuses_stale_parent_base
test_accepts_the_origin_repository
test_fails_closed_on_unreadable_registration
test_gate_lint_refuses_before_shellcheck
test_normal_lint_does_not_require_gate_state

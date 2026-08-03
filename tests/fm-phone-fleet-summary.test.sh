#!/usr/bin/env bash
# Behavior tests for the compact Discord phone fleet summary renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUMMARY="$ROOT/bin/fm-phone-fleet-summary.sh"
FIXTURES="$ROOT/tests/fixtures/fm-phone-fleet-summary"
TMP_ROOT=$(fm_test_tmproot fm-phone-fleet-summary)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

test_standard_fixture_uses_five_safe_columns() {
  local out decide queued building review landed
  out=$("$SUMMARY" --snapshot "$FIXTURES/standard.json") \
    || fail "standard fixture did not render"

  assert_contains "$out" "Captain, here's the fleet at a glance:" \
    "phone summary must be captain-facing"
  for heading in "1. Decide" "2. Queued" "3. Building" "4. Review" "5. Landed"; do
    assert_contains "$out" "$heading" "phone summary lost ordered heading $heading"
  done

  decide=${out%%"2. Queued"*}
  queued=${out#*"2. Queued"}; queued=${queued%%"3. Building"*}
  building=${out#*"3. Building"}; building=${building%%"4. Review"*}
  review=${out#*"4. Review"}; review=${review%%"5. Landed"*}
  landed=${out#*"5. Landed"}
  assert_contains "$decide" "Choose the release window" "captain hold did not route to Decide"
  assert_contains "$queued" "Prepare the migration guide" "queued work did not route to Queued"
  assert_contains "$building" "Build phone summaries" "live work without a PR did not route to Building"
  assert_contains "$building" "Remove [private detail omitted] from [private detail omitted]" \
    "captain-facing titles must redact embedded secret values and private paths"
  assert_contains "$building" "Fix the build ([private detail omitted]) at worktree=[private detail omitted]" \
    "private paths must be redacted wherever they are embedded in a title"
  assert_contains "$building" "Chase the untrusted review link" \
    "work whose recorded PR URL is untrusted must still be reported as building"
  assert_contains "$review" "Polish the fleet board" "PR-recorded work did not route to Review"
  assert_contains "$review" "Ship the phone glance" \
    "a PR URL captured with trailing sentence punctuation must still route to Review"
  assert_contains "$landed" "Launch Discord phone mode" "completed work did not route to Landed"

  assert_contains "$review" "https://github.com/Lcxiv/firstmate/pull/1539" \
    "review item must carry its complete HTTPS PR URL"
  assert_contains "$landed" "https://github.com/Lcxiv/firstmate/pull/1500" \
    "landed item must carry its complete HTTPS PR URL"
  assert_contains "$review" "https://github.com/Lcxiv/firstmate/pull/1544" \
    "a scraped PR URL must be normalized rather than dropped"
  for forbidden in \
    internal-decide-id internal-building-id forbidden-runtime-name forbidden-backend-name \
    validation-step secret-token-value synthetic-title-secret synthetic-webhook-token \
    "pull/1544." evil.example \
    /Users/private/worktree discord.com/api/webhooks; do
    assert_not_contains "$out" "$forbidden" "phone summary leaked internal detail: $forbidden"
  done
  pass "fixture snapshot renders the five ordered columns without internal details"
}

test_empty_fixture_is_one_clear_answer() {
  local out
  out=$("$SUMMARY" --snapshot "$FIXTURES/empty.json") \
    || fail "empty fixture did not render"
  [ "$out" = "Captain, nothing under way right now." ] \
    || fail "empty fleet answer was not clear and compact: $out"
  assert_not_contains "$out" "Decide" "empty answer must not print five empty headings"
  pass "empty fixture says nothing is under way"
}

test_oversized_fixture_trims_deliberately_to_one_screen() {
  local out chars
  out=$("$SUMMARY" --snapshot "$FIXTURES/oversized.json" --max-chars 500) \
    || fail "oversized fixture did not render"
  chars=$(printf '%s' "$out" | python3 -c 'import sys; print(len(sys.stdin.read()))')
  [ "$chars" -le 500 ] || fail "oversized summary exceeded its one-screen budget: $chars"
  assert_contains "$out" "Left out to fit one phone screen:" \
    "oversized summary must disclose truncation"
  assert_contains "$out" "Landed" "omission disclosure must name the first-trimmed column"
  assert_contains "$out" "Ask for one column to see the rest." \
    "omission disclosure must offer a complete narrower follow-up"
  assert_contains "$out" "Choose the launch sequence" \
    "Decide should survive while lower-priority Landed entries are dropped first"
  assert_contains "$out" "Review the navigation improvements" \
    "Review should survive while lower-priority Landed entries are dropped first"
  assert_not_contains "$out" "Landed improvement six" \
    "Landed entries should be the first omitted from an oversized summary"
  pass "oversized fixture stays on one screen and discloses what was omitted"
}

test_default_path_reads_the_canonical_snapshot() {
  local home out
  home="$TMP_ROOT/canonical-empty"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  out=$(FM_HOME="$home" "$SUMMARY") || fail "canonical snapshot path did not render"
  [ "$out" = "Captain, nothing under way right now." ] \
    || fail "default path did not consume the canonical empty snapshot: $out"
  pass "default renderer path consumes fm-fleet-snapshot JSON"
}

test_unreadable_backlog_is_not_reported_as_an_empty_fleet() {
  local home out
  home="$TMP_ROOT/canonical-unreadable"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  out=$(FM_HOME="$home" "$SUMMARY") || fail "unreadable-backlog path did not render"
  [ "$out" = "Captain, I cannot read the fleet list right now, so I cannot tell you what is under way." ] \
    || fail "unreadable fleet list was not reported honestly: $out"
  assert_not_contains "$out" "nothing under way" \
    "an unreadable fleet list must never be answered as an empty fleet"
  pass "an unreadable fleet list is reported rather than answered as an empty fleet"
}

test_budget_follows_a_lowered_reply_limit() {
  local out chars
  out=$(FM_PHONE_REPLY_MAX_CHARS=600 "$SUMMARY" --snapshot "$FIXTURES/oversized.json") \
    || fail "lowered reply limit did not render"
  chars=$(printf '%s' "$out" | python3 -c 'import sys; print(len(sys.stdin.read()))')
  [ "$chars" -le 600 ] \
    || fail "summary ignored the captain's lowered reply budget: $chars"
  assert_contains "$out" "Left out to fit one phone screen:" \
    "a lowered reply budget must still disclose what it omitted"
  pass "the glance budget follows a lowered FM_PHONE_REPLY_MAX_CHARS"
}

test_standard_fixture_uses_five_safe_columns
test_empty_fixture_is_one_clear_answer
test_oversized_fixture_trims_deliberately_to_one_screen
test_default_path_reads_the_canonical_snapshot
test_unreadable_backlog_is_not_reported_as_an_empty_fleet
test_budget_follows_a_lowered_reply_limit

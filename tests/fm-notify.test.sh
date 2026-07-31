#!/usr/bin/env bash
# Behavior tests for bin/fm-notify.sh, the captain's phone-notification sender.
#
# Every test drives the real executable with a stubbed transport on PATH. No
# test contacts a network, and the webhook URLs here are deliberately fake.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-notify)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FAKE_HOOK='https://discord.com/api/webhooks/000000000000000000/fake-test-token'

# --- harness ----------------------------------------------------------------

# make_home <name>: an isolated firstmate home with a capturing fake curl.
#
# The stub records every request payload in order and reports a status code the
# test chooses, so assertions are made against the real wire payload rather than
# against the script's source.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/capture"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Capturing stand-in for curl: understands only the flags fm-notify.sh sends.
out=; payload=; url=
printf '%s\n' "$@" >> "$FM_NOTIFY_TEST_CAPTURE/argv"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) payload=${2#@}; shift 2 ;;
    -K|--config) url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$2"); shift 2 ;;
    -w|-m|--connect-timeout|-H|-X) shift 2 ;;
    -s) shift ;;
    *) url=$1; shift ;;
  esac
done
n=$(cat "$FM_NOTIFY_TEST_CAPTURE/count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FM_NOTIFY_TEST_CAPTURE/count"
cp "$payload" "$FM_NOTIFY_TEST_CAPTURE/payload-$n.json"
printf '%s\n' "$url" >> "$FM_NOTIFY_TEST_CAPTURE/urls"
if [ "$n" = 1 ] && [ -n "${FM_NOTIFY_TEST_RATELIMIT:-}" ]; then
  printf '{"message":"You are being rate limited.","retry_after":%s,"global":false}' \
    "$FM_NOTIFY_TEST_RATELIMIT" > "$out"
  printf '429'
  exit 0
fi
if [ -n "${FM_NOTIFY_TEST_TRANSPORT_FAIL:-}" ]; then
  exit 7
fi
: > "$out"
printf '%s' "${FM_NOTIFY_TEST_CODE:-204}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$home"
}

# run_notify <home> -- <args...>: invoke the sender inside <home>.
run_notify() {
  local home=$1
  shift
  [ "${1:-}" = "--" ] && shift
  PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_NOTIFY_TEST_CAPTURE="$home/capture" \
    "$NOTIFY" "$@"
}

# run_notify_on_a_tty <home> -- <args...>: invoke the sender with stdin attached
# to a pseudo-terminal, so the interactive-caller path can be exercised. The
# child is bounded, so a regression that blocks fails the test with exit 124
# instead of hanging the suite.
run_notify_on_a_tty() {
  local home=$1
  shift
  [ "${1:-}" = "--" ] && shift
  PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_NOTIFY_TEST_CAPTURE="$home/capture" \
    python3 -c '
import os, subprocess, sys
master, slave = os.openpty()
try:
    child = subprocess.Popen(sys.argv[1:], stdin=slave,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
finally:
    os.close(slave)
try:
    err = child.communicate(timeout=15)[1]
except subprocess.TimeoutExpired:
    child.kill()
    child.wait()
    os.close(master)
    sys.exit(124)
os.close(master)
sys.stderr.buffer.write(err)
sys.exit(child.returncode)
' "$NOTIFY" "$@"
}

configure() {  # <home> <target> [events]
  local home=$1 target=$2 events=${3:-}
  printf 'FM_NOTIFY_TARGET=%s\n' "$target" > "$home/.env"
  if [ -n "$events" ]; then
    printf 'FM_NOTIFY_EVENTS=%s\n' "$events" >> "$home/.env"
  fi
}

sent_count() {  # <home>
  cat "$1/capture/count" 2>/dev/null || echo 0
}

embed() {  # <home> <n> <jq filter>
  jq -r "$3" < "$1/capture/payload-$2.json"
}

# --- inertness --------------------------------------------------------------

test_inert_without_any_config() {
  local home out rc
  home=$(make_home inert-no-env)
  # No .env at all, and curl removed from PATH entirely: an unconfigured home
  # must not even reach the transport.
  rm -f "$home/fakebin/curl"
  out=$(run_notify "$home" -- --event pr-ready "PR ready" 2>&1)
  rc=$?
  expect_code 0 "$rc" "unconfigured send"
  [ -z "$out" ] || fail "unconfigured send must be silent, got: $out"
  [ "$(sent_count "$home")" = 0 ] || fail "unconfigured send contacted the transport"
  pass "no configuration: silent successful no-op"
}

test_inert_when_env_has_no_target() {
  local home rc out
  home=$(make_home inert-empty-target)
  printf 'SOMETHING_ELSE=1\nFM_NOTIFY_EVENTS=all\n' > "$home/.env"
  out=$(run_notify "$home" -- "hello" 2>&1)
  rc=$?
  expect_code 0 "$rc" "send with a .env but no target"
  [ -z "$out" ] || fail "expected silence, got: $out"
  [ "$(sent_count "$home")" = 0 ] || fail "sent despite no target"
  pass "a .env without a target stays inert"
}

test_inert_leaves_fleet_state_untouched() {
  local home before after
  home=$(make_home inert-state)
  configure "$home" "$FAKE_HOOK"
  before=$(find "$home/state" | LC_ALL=C sort)
  run_notify "$home" -- --event merged "merged it" >/dev/null 2>&1 \
    || fail "configured send failed"
  after=$(find "$home/state" | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "the sender wrote into the fleet's state directory"
  pass "delivery never writes into the fleet's state"
}

# --- input handling ---------------------------------------------------------

test_message_from_argv_and_stdin() {
  local home
  home=$(make_home input-argv)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --event update "one" "two" "three" >/dev/null \
    || fail "argv send failed"
  [ "$(embed "$home" 1 '.embeds[0].description')" = "one two three" ] \
    || fail "argv message not passed through verbatim"

  home=$(make_home input-stdin)
  configure "$home" "$FAKE_HOOK"
  printf 'from stdin\nsecond line\n' | run_notify "$home" -- --event update >/dev/null \
    || fail "stdin send failed"
  [ "$(embed "$home" 1 '.embeds[0].description')" = "from stdin
second line" ] || fail "stdin message not passed through verbatim"
  pass "message text is accepted on argv and on stdin"
}

test_empty_message_is_a_usage_error() {
  local home rc
  home=$(make_home input-empty)
  configure "$home" "$FAKE_HOOK"
  printf '   \n' | run_notify "$home" -- --event update >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "empty message"
  [ "$(sent_count "$home")" = 0 ] || fail "empty message was still sent"
  pass "an empty message is refused before any delivery"
}

test_missing_message_on_a_terminal_is_a_usage_error() {
  local home rc out
  if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not found; the interactive-stdin case needs a pty"
    return 0
  fi
  home=$(make_home input-missing-tty)
  configure "$home" "$FAKE_HOOK"
  out=$(run_notify_on_a_tty "$home" -- --event update 2>&1)
  rc=$?
  [ "$rc" != 124 ] || fail "a missing message on a terminal blocked instead of failing fast"
  expect_code 2 "$rc" "missing message on a terminal"
  [ "$(sent_count "$home")" = 0 ] || fail "a missing message was still delivered"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "expected one short diagnostic line, got: $out"
  pass "a missing message on an interactive terminal is a usage error, not a hang"
}

test_unknown_event_class_is_a_usage_error() {
  local home rc out
  home=$(make_home input-badclass)
  configure "$home" "$FAKE_HOOK"
  out=$(run_notify "$home" -- --event invented "text" 2>&1)
  rc=$?
  expect_code 2 "$rc" "unknown event class"
  assert_contains "$out" "unknown event class" "expected a class diagnostic"
  [ "$(sent_count "$home")" = 0 ] || fail "unknown class was still sent"
  pass "an unknown event class is a usage error, never an invented mapping"
}

test_unknown_option_and_bad_url_refused() {
  local home rc
  home=$(make_home input-badflags)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --nope "text" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "unknown option"
  run_notify "$home" -- --url 'javascript:alert(1)' "text" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "non-http --url"
  [ "$(sent_count "$home")" = 0 ] || fail "a malformed call still sent something"
  pass "malformed calls are refused without delivery"
}

# --- config surface ---------------------------------------------------------

test_environment_wins_over_env_file() {
  local home
  home=$(make_home config-precedence)
  configure "$home" 'discord-webhook:https://example.invalid/from-file'
  FM_NOTIFY_TARGET='discord-webhook:https://example.invalid/from-env' \
    run_notify "$home" -- --event update "hi" >/dev/null || fail "send failed"
  assert_grep 'https://example.invalid/from-env' "$home/capture/urls" \
    "an explicit environment target must win over the .env value"
  pass "an explicit environment value wins over the .env file"
}

test_bare_and_prefixed_targets_both_resolve() {
  local home
  home=$(make_home config-target-forms)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --event update "hi" >/dev/null || fail "bare URL target failed"
  assert_grep "$FAKE_HOOK" "$home/capture/urls" "bare webhook URL did not resolve"

  home=$(make_home config-target-prefixed)
  configure "$home" 'discord-webhook:https://example.invalid/hook'
  run_notify "$home" -- --event update "hi" >/dev/null || fail "prefixed target failed"
  assert_grep 'https://example.invalid/hook' "$home/capture/urls" \
    "channel-prefixed target did not resolve"
  pass "both the bare webhook URL and the channel-prefixed form resolve"
}

test_unsupported_target_is_misconfiguration() {
  local home rc out
  home=$(make_home config-bad-target)
  configure "$home" 'carrier-pigeon:coop-4'
  out=$(run_notify "$home" -- --event update "hi" 2>&1)
  rc=$?
  expect_code 3 "$rc" "unsupported channel"
  assert_contains "$out" "no supported channel" "expected a channel diagnostic"
  [ "$(sent_count "$home")" = 0 ] || fail "unsupported channel still delivered"
  pass "a target naming no implemented channel is a reported misconfiguration"
}

test_event_filter_selects_classes() {
  local home
  home=$(make_home filter-subset)
  configure "$home" "$FAKE_HOOK" 'merged,blocked'
  run_notify "$home" -- --event pr-ready "not this one" >/dev/null \
    || fail "a filtered-out class must still exit 0"
  [ "$(sent_count "$home")" = 0 ] || fail "a filtered-out class was delivered"
  run_notify "$home" -- --event blocked "this one" >/dev/null || fail "listed class failed"
  [ "$(sent_count "$home")" = 1 ] || fail "a listed class was not delivered"

  home=$(make_home filter-all)
  configure "$home" "$FAKE_HOOK" 'all'
  run_notify "$home" -- --event dispatched "everything" >/dev/null || fail "all filter failed"
  [ "$(sent_count "$home")" = 1 ] || fail "'all' did not deliver"

  home=$(make_home filter-none)
  configure "$home" "$FAKE_HOOK" 'none'
  run_notify "$home" -- --event blocked "nothing" >/dev/null || fail "none filter failed"
  [ "$(sent_count "$home")" = 0 ] || fail "'none' still delivered"
  pass "FM_NOTIFY_EVENTS selects classes, including 'all' and 'none'"
}

test_default_event_set_matches_the_documented_default() {
  local home class
  # The documented default is every class except dispatched, because AGENTS.md
  # section 9 suppresses routine progress in captain chat.
  for class in needs-decision blocked failed pr-ready merged 'done' update; do
    home=$(make_home "default-on-$class")
    configure "$home" "$FAKE_HOOK"
    run_notify "$home" -- --event "$class" "text" >/dev/null || fail "$class send failed"
    [ "$(sent_count "$home")" = 1 ] || fail "$class is not in the default set"
  done
  home=$(make_home default-off-dispatched)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --event dispatched "text" >/dev/null || fail "dispatched send failed"
  [ "$(sent_count "$home")" = 0 ] || fail "dispatched must be opt-in, not default"
  pass "the default event set is every class except dispatched"
}

# --- presentation -----------------------------------------------------------

test_every_state_carries_emoji_word_and_colour() {
  local home class title colour word
  # Buddy's rule, adopted here: colour never stands alone. Every title has to
  # carry a glyph and an uppercase word as well, for colourblind readers and for
  # notification previews that drop the colour bar.
  for class in dispatched needs-decision blocked failed pr-ready merged 'done' update; do
    home=$(make_home "presentation-$class")
    configure "$home" "$FAKE_HOOK" 'all'
    run_notify "$home" -- --event "$class" "body text" >/dev/null || fail "$class send failed"
    title=$(embed "$home" 1 '.embeds[0].title')
    colour=$(embed "$home" 1 '.embeds[0].color')
    case "$colour" in
      ''|null|*[!0-9]*) fail "$class: expected an integer colour, got '$colour'" ;;
    esac
    word=$(printf '%s' "$title" | tr -dc 'A-Z ')
    case "$(printf '%s' "$word" | tr -d ' ')" in
      '') fail "$class: title '$title' carries no uppercase state word" ;;
    esac
    # A leading glyph means the title does not begin with the word itself.
    case "$title" in
      [A-Za-z]*) fail "$class: title '$title' carries no leading emoji" ;;
    esac
  done
  pass "every state carries an emoji, a word, and a colour - colour never alone"
}

test_title_and_link_are_applied() {
  local home
  home=$(make_home presentation-title)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --event pr-ready --title 'sniper' \
    --url 'https://github.com/owner/repo/pull/7' "ready for review" >/dev/null \
    || fail "send failed"
  assert_contains "$(embed "$home" 1 '.embeds[0].title')" 'sniper' \
    "the caller's title is missing from the embed title"
  [ "$(embed "$home" 1 '.embeds[0].url')" = 'https://github.com/owner/repo/pull/7' ] \
    || fail "the caller's link is missing from the embed"
  pass "the caller's title and link reach the embed"
}

test_long_title_is_truncated_within_the_cap() {
  local home title len
  home=$(make_home presentation-long-title)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --event blocked \
    --title "$(printf 'overlong %.0s' $(seq 1 80))" "body" >/dev/null || fail "send failed"
  title=$(embed "$home" 1 '.embeds[0].title')
  len=$(printf '%s' "$title" | jq -Rs 'length')
  [ "$len" -le 256 ] || fail "title of $len codepoints exceeds Discord's 256 cap"
  assert_contains "$title" '…' "an over-long title should be marked as truncated"
  pass "an over-long title is truncated within the title cap"
}

# --- splitting and caps -----------------------------------------------------

test_long_body_splits_within_every_cap() {
  local home n i title body tlen blen total
  home=$(make_home split-caps)
  configure "$home" "$FAKE_HOOK"
  { for i in $(seq 1 300); do
      printf 'line %s - captain-facing detail about the work under way\n' "$i"
    done; } | run_notify "$home" -- --event blocked --title 'sniper' >/dev/null \
    || fail "long send failed"
  n=$(sent_count "$home")
  [ "$n" -gt 1 ] || fail "a body far past the cap should have been split, got $n message(s)"
  i=1
  while [ "$i" -le "$n" ]; do
    title=$(embed "$home" "$i" '.embeds[0].title')
    body=$(embed "$home" "$i" '.embeds[0].description')
    tlen=$(printf '%s' "$title" | jq -Rs 'length')
    blen=$(printf '%s' "$body" | jq -Rs 'length')
    total=$((tlen + blen))
    [ "$tlen" -le 256 ] || fail "part $i: title of $tlen exceeds the 256 cap"
    [ "$blen" -le 4096 ] || fail "part $i: description of $blen exceeds the 4096 cap"
    [ "$total" -le 6000 ] || fail "part $i: $total codepoints exceeds the message-wide 6000 cap"
    assert_contains "$title" "($i/$n)" "part $i is not numbered in its title"
    i=$((i + 1))
  done
  pass "an oversized body splits into cap-compliant, numbered messages"
}

test_part_count_is_capped_and_marked() {
  local home n i last
  home=$(make_home split-max-parts)
  configure "$home" "$FAKE_HOOK"
  { for i in $(seq 1 400); do
      printf 'line %s - captain-facing detail about the work under way\n' "$i"
    done; } | FM_NOTIFY_MAX_PARTS=2 run_notify "$home" -- --event blocked >/dev/null \
    || fail "capped send failed"
  n=$(sent_count "$home")
  [ "$n" = 2 ] || fail "FM_NOTIFY_MAX_PARTS=2 produced $n message(s)"
  last=$(embed "$home" 2 '.embeds[0].description')
  case "$last" in
    *…) : ;;
    *) fail "the last kept part must be marked with an ellipsis when the body was dropped" ;;
  esac
  pass "the part count is capped and the truncated tail is marked"
}

test_pr_url_survives_splitting_unbroken() {
  local home n i found url
  url='https://github.com/owner/repo/pull/12345'
  home=$(make_home split-url)
  configure "$home" "$FAKE_HOOK"
  {
    for i in $(seq 1 120); do
      printf 'line %s - captain-facing detail about the work under way\n' "$i"
    done
    printf 'Ready for review: %s\n' "$url"
  } | run_notify "$home" -- --event pr-ready >/dev/null || fail "url send failed"
  n=$(sent_count "$home")
  found=0
  i=1
  while [ "$i" -le "$n" ]; do
    case "$(embed "$home" "$i" '.embeds[0].description')" in
      *"$url"*) found=1 ;;
    esac
    i=$((i + 1))
  done
  [ "$found" = 1 ] || fail "the full PR URL did not survive splitting intact"
  pass "a full PR URL survives splitting unbroken"
}

test_single_part_message_is_not_numbered() {
  local home
  home=$(make_home split-single)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --event merged --title 'sniper' "short and sweet" >/dev/null \
    || fail "send failed"
  assert_not_contains "$(embed "$home" 1 '.embeds[0].title')" '(1/1)' \
    "a message that fits should not be numbered"
  pass "a message that fits in one part carries no part marker"
}

# --- transport --------------------------------------------------------------

test_rate_limit_retries_once_honouring_retry_after() {
  local home rc started elapsed
  home=$(make_home transport-429)
  configure "$home" "$FAKE_HOOK"
  started=$(date +%s)
  FM_NOTIFY_TEST_RATELIMIT=1 run_notify "$home" -- --event merged "merged" >/dev/null 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "429 then success"
  [ "$(sent_count "$home")" = 2 ] || fail "a 429 should be retried exactly once"
  [ "$elapsed" -ge 1 ] || fail "the retry did not honour retry_after (waited ${elapsed}s)"
  pass "a rate limit is retried once, honouring retry_after"
}

test_rate_limit_wait_is_clamped_so_it_cannot_hang() {
  local home rc started elapsed
  home=$(make_home transport-429-clamp)
  configure "$home" "$FAKE_HOOK"
  started=$(date +%s)
  FM_NOTIFY_TEST_RATELIMIT=99999 FM_NOTIFY_RETRY_CAP_SECS=1 \
    run_notify "$home" -- --event merged "merged" >/dev/null 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "clamped 429 retry"
  [ "$elapsed" -lt 30 ] || fail "an absurd retry_after was not clamped (waited ${elapsed}s)"
  pass "an absurd retry_after is clamped, so delivery cannot hang a turn"
}

test_repeated_rate_limit_gives_up_after_one_retry() {
  local home rc
  home=$(make_home transport-429-persistent)
  configure "$home" "$FAKE_HOOK"
  FM_NOTIFY_TEST_CODE=429 FM_NOTIFY_TEST_RATELIMIT=0 \
    run_notify "$home" -- --event merged "merged" >/dev/null 2>&1
  rc=$?
  expect_code 4 "$rc" "persistent rate limit"
  [ "$(sent_count "$home")" = 2 ] || fail "a persistent 429 should stop after one retry"
  pass "a persistent rate limit gives up after one retry instead of looping"
}

test_forbidden_and_missing_targets_are_tolerated_quietly() {
  local home rc out code
  for code in 403 404; do
    home=$(make_home "transport-$code")
    configure "$home" "$FAKE_HOOK"
    out=$(FM_NOTIFY_TEST_CODE=$code run_notify "$home" -- --event merged "merged" 2>&1)
    rc=$?
    expect_code 5 "$rc" "HTTP $code"
    [ "$(sent_count "$home")" = 1 ] || fail "HTTP $code should not be retried"
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
      || fail "HTTP $code should print one short line, got: $out"
    assert_contains "$out" "$code" "the diagnostic should name the status"
  done
  pass "403 and 404 are tolerated quietly: one line, no retry, no stack trace"
}

test_transport_and_server_failures_are_quiet_and_non_zero() {
  local home rc out
  home=$(make_home transport-error)
  configure "$home" "$FAKE_HOOK"
  out=$(FM_NOTIFY_TEST_TRANSPORT_FAIL=1 run_notify "$home" -- --event failed "boom" 2>&1)
  rc=$?
  expect_code 4 "$rc" "transport error"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "a transport error should print one short line, got: $out"

  home=$(make_home transport-500)
  configure "$home" "$FAKE_HOOK"
  out=$(FM_NOTIFY_TEST_CODE=500 run_notify "$home" -- --event failed "boom" 2>&1)
  rc=$?
  expect_code 4 "$rc" "HTTP 500"
  assert_contains "$out" "500" "the diagnostic should name the status"
  pass "delivery failures exit non-zero with one short diagnostic"
}

test_failure_leaves_no_state_and_stays_bounded() {
  local home before after started elapsed
  home=$(make_home failure-nonblocking)
  configure "$home" "$FAKE_HOOK"
  before=$(find "$home/state" | LC_ALL=C sort)
  started=$(date +%s)
  FM_NOTIFY_TEST_CODE=500 run_notify "$home" -- --event failed "boom" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - started ))
  after=$(find "$home/state" | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "a failed delivery wrote into the fleet's state"
  [ "$elapsed" -lt 30 ] || fail "a failed delivery took ${elapsed}s instead of returning promptly"
  pass "a failed delivery is bounded and leaves the fleet's state untouched"
}

test_wire_request_carries_the_required_headers() {
  local home
  # Discord rejects a webhook POST with no User-Agent at the edge, so the header
  # set is part of the transport contract rather than decoration.
  home=$(make_home transport-headers)
  configure "$home" "$FAKE_HOOK"
  cat > "$home/fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_NOTIFY_TEST_CAPTURE/argv"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '204'
SH
  chmod +x "$home/fakebin/curl"
  run_notify "$home" -- --event merged "merged" >/dev/null || fail "send failed"
  assert_grep 'Content-Type: application/json' "$home/capture/argv" \
    "the request must declare a JSON content type"
  assert_grep 'User-Agent: firstmate-notify' "$home/capture/argv" \
    "the request must carry a User-Agent"
  assert_grep '-m' "$home/capture/argv" "the request must carry a bounded timeout"
  pass "the wire request carries the JSON content type, User-Agent, and a timeout"
}

test_webhook_address_never_reaches_the_process_arguments() {
  local home
  # The webhook is a write capability that lives only in the home's gitignored
  # .env, so it must not be visible in `ps` for the life of the request.
  home=$(make_home transport-argv-secrecy)
  configure "$home" "$FAKE_HOOK"
  run_notify "$home" -- --event merged "merged" >/dev/null || fail "send failed"
  assert_grep "$FAKE_HOOK" "$home/capture/urls" "the request did not reach the target"
  assert_no_grep "$FAKE_HOOK" "$home/capture/argv" \
    "the webhook address must not be passed to curl as a command-line argument"
  assert_grep '--config' "$home/capture/argv" \
    "the target should be handed to curl through a config file"
  pass "the webhook address is handed to curl by file, never through argv"
}

test_delivery_leaves_no_temporary_files_behind() {
  local home scratch left
  # The staged target and the response body are both scratch files; a failed
  # delivery must clean up after itself just as a successful one does.
  home=$(make_home transport-tempfiles)
  scratch="$home/scratch"
  mkdir -p "$scratch"
  configure "$home" "$FAKE_HOOK"
  TMPDIR="$scratch" run_notify "$home" -- --event merged "merged" >/dev/null \
    || fail "send failed"
  TMPDIR="$scratch" FM_NOTIFY_TEST_CODE=500 \
    run_notify "$home" -- --event failed "boom" >/dev/null 2>&1
  left=$(find "$scratch" -type f | LC_ALL=C sort)
  [ -z "$left" ] || fail "delivery left temporary files behind: $left"
  pass "delivery leaves no staged target or response file behind"
}

# --- help -------------------------------------------------------------------

test_help_and_list_events_need_no_config() {
  local home out
  home=$(make_home help-surface)
  out=$(run_notify "$home" -- --help)
  assert_contains "$out" "FM_NOTIFY_TARGET" "--help should document the opt-in key"
  out=$(run_notify "$home" -- --list-events)
  assert_contains "$out" "needs-decision" "--list-events should list the classes"
  pass "--help and --list-events work with no configuration"
}

test_inert_without_any_config
test_inert_when_env_has_no_target
test_inert_leaves_fleet_state_untouched
test_message_from_argv_and_stdin
test_empty_message_is_a_usage_error
test_missing_message_on_a_terminal_is_a_usage_error
test_unknown_event_class_is_a_usage_error
test_unknown_option_and_bad_url_refused
test_environment_wins_over_env_file
test_bare_and_prefixed_targets_both_resolve
test_unsupported_target_is_misconfiguration
test_event_filter_selects_classes
test_default_event_set_matches_the_documented_default
test_every_state_carries_emoji_word_and_colour
test_title_and_link_are_applied
test_long_title_is_truncated_within_the_cap
test_long_body_splits_within_every_cap
test_part_count_is_capped_and_marked
test_pr_url_survives_splitting_unbroken
test_single_part_message_is_not_numbered
test_rate_limit_retries_once_honouring_retry_after
test_rate_limit_wait_is_clamped_so_it_cannot_hang
test_repeated_rate_limit_gives_up_after_one_retry
test_forbidden_and_missing_targets_are_tolerated_quietly
test_transport_and_server_failures_are_quiet_and_non_zero
test_failure_leaves_no_state_and_stays_bounded
test_wire_request_carries_the_required_headers
test_webhook_address_never_reaches_the_process_arguments
test_delivery_leaves_no_temporary_files_behind
test_help_and_list_events_need_no_config

#!/usr/bin/env bash
# Behavior tests for Discord-only phone mode.
#
# The suite is hermetic: fake curl returns synthetic Discord objects and records
# only request class, timeout, cursor, and outbound JSON. It never opens a port
# or uses a real token, webhook, account, or channel.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-phone-mode-tests)

CAPTAIN_ID=710000000000000001
CHANNEL_ID=720000000000000001
OTHER_AUTHOR_ID=710000000000000099
OTHER_CHANNEL_ID=720000000000000099
PHONE_TOKEN="synthetic-phone-$PPID-$$"

write_phone_env() {
  local home=$1
  mkdir -p "$home"
  {
    printf 'FM_PHONE_DISCORD_TOKEN=%s\n' "$PHONE_TOKEN"
    printf 'FM_PHONE_CAPTAIN_ID=%s\n' "$CAPTAIN_ID"
    printf 'FM_PHONE_CHANNEL_ID=%s\n' "$CHANNEL_ID"
  } > "$home/.env"
  chmod 600 "$home/.env"
}

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile=
method=GET
config=
data_file=
auth_file=
timeout=
connect_timeout=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --config) config=$2; shift 2 ;;
    --data-binary) data_file=${2#@}; shift 2 ;;
    -H)
      case "$2" in @*) auth_file=${2#@} ;; esac
      shift 2
      ;;
    -m) timeout=$2; shift 2 ;;
    --connect-timeout) connect_timeout=$2; shift 2 ;;
    -w) shift 2 ;;
    -s) shift ;;
    *) shift ;;
  esac
done

url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$config")
auth=$(cat "$auth_file" 2>/dev/null || true)
expected="Authorization: Bot ${FAKE_PHONE_EXPECTED_TOKEN:-}"
[ "$auth" = "$expected" ] || { [ -n "$ofile" ] && : > "$ofile"; printf '401'; exit 0; }

if [ -n "${FAKE_PHONE_CALL_LOG:-}" ]; then
  printf '%s timeout=%s connect=%s\n' "$method" "$timeout" "$connect_timeout" >> "$FAKE_PHONE_CALL_LOG"
fi

if [ "$method" = POST ]; then
  if [ -n "${FAKE_PHONE_POST_LOG:-}" ]; then
    jq -c '.' "$data_file" >> "$FAKE_PHONE_POST_LOG"
  fi
  [ -n "$ofile" ] && printf '%s' "${FAKE_PHONE_POST_BODY:-{}}" > "$ofile"
  printf '%s' "${FAKE_PHONE_POST_CODE:-200}"
  exit 0
fi

after=$(printf '%s' "$url" | sed -n 's/^.*[?&]after=\([0-9][0-9]*\).*$/\1/p')
if [ -n "${FAKE_PHONE_CURSOR_LOG:-}" ]; then
  printf 'after=%s\n' "${after:-0}" >> "$FAKE_PHONE_CURSOR_LOG"
fi
[ -n "$ofile" ] && printf '%s' "${FAKE_PHONE_POLL_BODY:-[]}" > "$ofile"
printf '%s' "${FAKE_PHONE_POLL_CODE:-200}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

run_poll() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FAKE_PHONE_EXPECTED_TOKEN="$PHONE_TOKEN" \
    "$@" "$ROOT/bin/fm-phone-poll.sh"
}

test_inert_by_default() {
  local home fakebin out calls
  home="$TMP_ROOT/inert"
  mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  calls="$home/calls.log"

  out=$(FAKE_PHONE_CALL_LOG="$calls" run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "unconfigured phone poll must be silent"
  assert_absent "$calls" "unconfigured phone poll must not call Discord"
  assert_absent "$home/state" "unconfigured phone poll must not create state"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "PHONE:" "bootstrap must be silent about never-configured phone mode"
  assert_absent "$home/state/phone-watch.check.sh" "bootstrap must not generate a phone shim"
  assert_absent "$home/state/phone-watch.check-trust" "bootstrap must not generate phone trust"
  assert_absent "$home/config/phone-mode.env" "bootstrap must not generate phone cadence"
  pass "Discord phone mode is completely inert without opt-in keys"
}

test_two_part_filter_and_bot_loop_guard_are_silent() {
  local home fakebin out posts inbox body
  home="$TMP_ROOT/filter"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  posts="$home/posts.log"
  body=$(jq -cn \
    --arg captain "$CAPTAIN_ID" \
    --arg channel "$CHANNEL_ID" \
    --arg other_author "$OTHER_AUTHOR_ID" \
    --arg other_channel "$OTHER_CHANNEL_ID" '
      [
        {id:"1001",channel_id:$channel,author:{id:$other_author,bot:false},content:"not the captain"},
        {id:"1002",channel_id:$other_channel,author:{id:$captain,bot:false},content:"wrong channel"},
        {id:"1003",channel_id:$channel,author:{id:$captain,bot:true},content:"bot loop"}
      ]
    ')

  out=$(FAKE_PHONE_POST_LOG="$posts" FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "rejected Discord messages must not wake firstmate"
  assert_absent "$posts" "rejected Discord messages must receive no acknowledgement or reply"
  inbox=$(find "$home/state/phone-inbox" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$inbox" = 0 ] || fail "rejected Discord messages must not enter the inbox"
  [ "$(cat "$home/state/phone-cursor")" = 1003 ] || fail "rejected messages must still advance the channel cursor"
  pass "non-captain, wrong-channel, and bot-authored messages are dropped without a reply"
}

test_accepted_message_stashes_acks_and_wakes() {
  local home fakebin out posts body inbox
  home="$TMP_ROOT/accepted"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  posts="$home/posts.log"
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"2001",channel_id:$channel,author:{id:$captain,bot:false},content:"Prioritize the release review."}]
  ')

  out=$(FAKE_PHONE_POST_LOG="$posts" FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-message 2001" ] || fail "accepted command emitted the wrong wake: $out"
  inbox="$home/state/phone-inbox/2001.json"
  assert_present "$inbox" "accepted command must be durably stashed"
  [ "$(jq -r .content "$inbox")" = "Prioritize the release review." ] \
    || fail "accepted command content was not preserved"
  [ "$(cat "$home/state/phone-cursor")" = 2001 ] || fail "accepted command did not advance the cursor"
  [ "$(wc -l < "$posts" | tr -d ' ')" = 1 ] || fail "accepted poll must send at most one acknowledgement"
  [ "$(jq -r .content "$posts")" = "⚓ received" ] || fail "acknowledgement text changed"
  pass "two-part-authenticated Discord commands are durable before acknowledgement and wake"
}

test_cursor_is_monotonic_and_inbox_is_idempotent() {
  local home fakebin out body count cursor_log
  home="$TMP_ROOT/cursor"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  cursor_log="$home/cursor.log"
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"3001",channel_id:$channel,author:{id:$captain,bot:false},content:"First command"}]
  ')
  out=$(FM_PHONE_ACK=0 FAKE_PHONE_CURSOR_LOG="$cursor_log" FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-message 3001" ] || fail "first cursor poll did not wake"

  out=$(FM_PHONE_ACK=0 FAKE_PHONE_CURSOR_LOG="$cursor_log" FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "replayed message at the cursor must be silent"
  count=$(find "$home/state/phone-inbox" -name '3001.json' -type f | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "replayed message created a duplicate inbox entry"

  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"2999",channel_id:$channel,author:{id:$captain,bot:false},content:"Older command"}]
  ')
  out=$(FM_PHONE_ACK=0 FAKE_PHONE_CURSOR_LOG="$cursor_log" FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "message below the cursor must be silent"
  [ "$(cat "$home/state/phone-cursor")" = 3001 ] || fail "cursor regressed on an older response"
  assert_grep 'after=3001' "$cursor_log" "subsequent polls must send the durable cursor"
  pass "monotonic cursor plus create-once inbox gives idempotent at-least-once polling"
}

test_one_page_coalesces_to_one_wake() {
  local home fakebin out body count
  home="$TMP_ROOT/coalesce"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [
      {id:"4002",channel_id:$channel,author:{id:$captain,bot:false},content:"Second"},
      {id:"4001",channel_id:$channel,author:{id:$captain,bot:false},content:"First"}
    ]
  ')
  out=$(FM_PHONE_ACK=0 FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-message 4002" ] || fail "page must emit one wake naming the newest accepted message"
  count=$(find "$home/state/phone-inbox" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "one coalesced wake must preserve every accepted command"
  pass "one bounded Discord page stashes every command and emits one drain wake"
}

test_poll_is_one_bounded_request_without_a_message() {
  local home fakebin out calls
  home="$TMP_ROOT/bounded"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  calls="$home/calls.log"
  out=$(FAKE_PHONE_CALL_LOG="$calls" FAKE_PHONE_POLL_BODY='[]' run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "empty Discord history poll must be silent"
  [ "$(cat "$calls")" = "GET timeout=5 connect=5" ] \
    || fail "empty sweep must make exactly one bounded request: $(cat "$calls")"
  assert_not_contains "$(cat "$calls")" "$CHANNEL_ID" "request log must not contain the configured channel id"
  assert_not_contains "$(cat "$calls")" "$PHONE_TOKEN" "request log must not contain the bot token"
  pass "the common poll path is one short bounded request with no config leakage"
}

test_reply_reads_file_verbatim_and_suppresses_mentions() {
  local home fakebin posts out text
  home="$TMP_ROOT/reply"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  posts="$home/posts.log"
  # shellcheck disable=SC2016 # Shell metacharacters must remain literal test data.
  text='Aye: literal $(whoami), `date`, and @everyone stay text.'
  printf '%s' "$text" > "$home/reply.txt"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FAKE_PHONE_EXPECTED_TOKEN="$PHONE_TOKEN" FAKE_PHONE_POST_LOG="$posts" \
    "$ROOT/bin/fm-phone-reply.sh" 5001 --text-file "$home/reply.txt")
  [ "$out" = 5001 ] || fail "phone reply did not confirm its source message id"
  [ "$(jq -r .content "$posts")" = "$text" ] || fail "phone reply changed or expanded text"
  [ "$(jq -c .allowed_mentions "$posts")" = '{"parse":[],"replied_user":false}' ] \
    || fail "phone reply did not suppress Discord mentions"
  pass "phone replies keep Discord-influenced text out of shell interpolation"
}

test_generic_errors_never_echo_configuration() {
  local home fakebin out
  home="$TMP_ROOT/error"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(FAKE_PHONE_POLL_CODE=401 run_poll "$home" "$fakebin")
  [ "$out" = "phone-mode-error Discord poll unavailable" ] || fail "auth error must stay generic"
  assert_not_contains "$out" "$PHONE_TOKEN" "error wake leaked the bot token"
  assert_not_contains "$out" "$CHANNEL_ID" "error wake leaked the channel id"
  assert_not_contains "$out" "$CAPTAIN_ID" "error wake leaked the captain id"
  pass "phone-mode errors are local, generic, and secret-free"
}

test_bootstrap_generation_identity_and_opt_out() {
  local home out before after
  home="$TMP_ROOT/bootstrap"
  write_phone_env "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PHONE: Discord phone mode on" "bootstrap must announce configured phone mode"
  assert_present "$home/state/phone-watch.check.sh" "bootstrap must generate the phone shim"
  assert_present "$home/state/phone-watch.check-trust" "bootstrap must register the phone shim"
  assert_present "$home/config/phone-mode.env" "bootstrap must generate the phone cadence"
  assert_grep 'export FM_CHECK_INTERVAL=30' "$home/config/phone-mode.env" "phone cadence must be 30 seconds"
  FM_HOME="$home" bash -c '. "$1/bin/fm-phone-lib.sh"; fm_phone_poll_shim_valid "$2/state/phone-watch.check.sh" "$2" "$1"' \
    _ "$ROOT" "$home" || fail "generated phone shim failed exact identity validation"
  FM_HOME="$home" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2/state" phone-watch' \
    _ "$ROOT" "$home" || fail "generated phone shim is not authenticated by its trust record"
  before=$(shasum "$home/state/phone-watch.check.sh" "$home/state/phone-watch.check-trust" "$home/config/phone-mode.env")
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  after=$(shasum "$home/state/phone-watch.check.sh" "$home/state/phone-watch.check-trust" "$home/config/phone-mode.env")
  [ "$before" = "$after" ] || fail "phone bootstrap setup must be idempotent"

  : > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PHONE: Discord phone mode off" "opt-out must announce generated-artifact removal"
  assert_absent "$home/state/phone-watch.check.sh" "opt-out must remove the phone shim"
  assert_absent "$home/state/phone-watch.check-trust" "opt-out must remove the trust record"
  assert_absent "$home/config/phone-mode.env" "opt-out must remove the cadence config"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "PHONE:" "steady-state opt-out must be silent"
  pass "bootstrap generates an identity-bound shim idempotently and removes every generated artifact on opt-out"
}

test_partial_bootstrap_config_stays_off_without_leaking_values() {
  local home out
  home="$TMP_ROOT/partial"
  mkdir -p "$home"
  {
    printf 'FM_PHONE_DISCORD_TOKEN=%s\n' "$PHONE_TOKEN"
    printf 'FM_PHONE_CAPTAIN_ID=%s\n' "$CAPTAIN_ID"
  } > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PHONE: Discord phone mode off - incomplete or invalid configuration" \
    "partial phone config must be refused"
  assert_not_contains "$out" "$PHONE_TOKEN" "partial-config diagnostic leaked the token"
  assert_not_contains "$out" "$CAPTAIN_ID" "partial-config diagnostic leaked a configured id"
  assert_absent "$home/state/phone-watch.check.sh" "partial config must not arm a shim"
  assert_absent "$home/state/phone-watch.check-trust" "partial config must not register trust"
  assert_absent "$home/config/phone-mode.env" "partial config must not enable fast cadence"
  pass "partial Discord configuration stays off and reports no configured value"
}

test_inert_by_default
test_two_part_filter_and_bot_loop_guard_are_silent
test_accepted_message_stashes_acks_and_wakes
test_cursor_is_monotonic_and_inbox_is_idempotent
test_one_page_coalesces_to_one_wake
test_poll_is_one_bounded_request_without_a_message
test_reply_reads_file_verbatim_and_suppresses_mentions
test_generic_errors_never_echo_configuration
test_bootstrap_generation_identity_and_opt_out
test_partial_bootstrap_config_stays_off_without_leaking_values

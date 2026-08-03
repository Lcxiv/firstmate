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

if [ -n "${FAKE_PHONE_URL_LOG:-}" ]; then
  printf '%s %s\n' "$method" "$url" >> "$FAKE_PHONE_URL_LOG"
fi

if [ "$method" = POST ]; then
  if [ -n "${FAKE_PHONE_POST_LOG:-}" ]; then
    jq -c '.' "$data_file" >> "$FAKE_PHONE_POST_LOG"
  fi
  # Assigned before use: "${VAR:-{}}" parses its braces wrong and appends a
  # stray '}', which corrupts any body a test actually reads back.
  post_body=${FAKE_PHONE_POST_BODY:-}
  [ -n "$post_body" ] || post_body='{}'
  [ -n "$ofile" ] && printf '%s' "$post_body" > "$ofile"
  printf '%s' "${FAKE_PHONE_POST_CODE:-200}"
  exit 0
fi

if [ "$method" = PUT ]; then
  [ -n "$ofile" ] && : > "$ofile"
  case "$url" in
    */reactions/*)
      [ -n "${FAKE_PHONE_REACT_LOG:-}" ] && printf '%s\n' "$url" >> "$FAKE_PHONE_REACT_LOG"
      printf '%s' "${FAKE_PHONE_REACT_CODE:-204}"
      ;;
    */pins/*)
      [ -n "${FAKE_PHONE_PIN_LOG:-}" ] && printf '%s\n' "$url" >> "$FAKE_PHONE_PIN_LOG"
      printf '%s' "${FAKE_PHONE_PIN_CODE:-204}"
      ;;
    *) printf '404' ;;
  esac
  exit 0
fi

if [ "$method" = PATCH ]; then
  if [ -n "${FAKE_PHONE_PATCH_LOG:-}" ]; then
    printf '%s ' "$url" >> "$FAKE_PHONE_PATCH_LOG"
    jq -c '.' "$data_file" >> "$FAKE_PHONE_PATCH_LOG"
  fi
  patch_body=${FAKE_PHONE_PATCH_BODY:-}
  [ -n "$patch_body" ] || patch_body='{}'
  [ -n "$ofile" ] && printf '%s' "$patch_body" > "$ofile"
  # A per-message code lets a test model "that message is not ours to edit".
  edit_id=${url##*/}
  eval "code=\${FAKE_PHONE_PATCH_CODE_$edit_id:-}"
  [ -n "$code" ] || code=${FAKE_PHONE_PATCH_CODE:-200}
  printf '%s' "$code"
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

directory_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

# Every steady-state delivery test starts from an already baselined home; the
# baseline sweep itself is covered by its own tests below.
seed_phone_cursor() {
  local home=$1 cursor=$2
  FM_HOME="$home" bash -c '. "$1/bin/fm-phone-lib.sh"; fm_phone_cursor_set "$2/state" "$3"' \
    _ "$ROOT" "$home" "$cursor" \
    || fail "could not seed the phone cursor for $home"
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
  seed_phone_cursor "$home" 1000
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
  local home fakebin out posts reacts body inbox
  home="$TMP_ROOT/accepted"
  write_phone_env "$home"
  seed_phone_cursor "$home" 2000
  fakebin=$(make_fake_curl "$home")
  posts="$home/posts.log"
  reacts="$home/reacts.log"
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"2001",channel_id:$channel,author:{id:$captain,bot:false},content:"Prioritize the release review."}]
  ')

  out=$(FAKE_PHONE_POST_LOG="$posts" FAKE_PHONE_REACT_LOG="$reacts" \
    FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-message 2001" ] || fail "accepted command emitted the wrong wake: $out"
  inbox="$home/state/phone-inbox/2001.json"
  assert_present "$inbox" "accepted command must be durably stashed"
  [ "$(jq -r .content "$inbox")" = "Prioritize the release review." ] \
    || fail "accepted command content was not preserved"
  [ "$(cat "$home/state/phone-cursor")" = 2001 ] || fail "accepted command did not advance the cursor"
  # The receipt is a reaction on the captain's own message, not a message of its
  # own: that is what removes the acknowledgement traffic from the channel.
  assert_absent "$posts" "an accepted command must not produce an acknowledgement message"
  [ "$(wc -l < "$reacts" | tr -d ' ')" = 1 ] || fail "accepted poll must add exactly one receipt"
  assert_grep '/messages/2001/reactions/' "$reacts" \
    "the receipt must be placed on the captain's own message"
  pass "two-part-authenticated Discord commands are durable before the receipt and wake"
}

test_receipt_is_a_reaction_and_never_claims_an_action_succeeded() {
  local home fakebin out reacts calls body order
  home="$TMP_ROOT/receipt-order"
  write_phone_env "$home"
  seed_phone_cursor "$home" 8000
  fakebin=$(make_fake_curl "$home")
  reacts="$home/reacts.log"
  calls="$home/urls.log"
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"8001",channel_id:$channel,author:{id:$captain,bot:false},content:"Merge it"}]
  ')

  out=$(FAKE_PHONE_URL_LOG="$calls" FAKE_PHONE_REACT_LOG="$reacts" \
    FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-message 8001" ] || fail "accepted command emitted the wrong wake: $out"
  # Durable first, receipt second: the receipt reports storage, never an outcome.
  assert_present "$home/state/phone-inbox/8001.json" "the command must be durable"
  order=$(awk 'NR==1 {print $1}' "$calls")
  [ "$order" = GET ] || fail "the receipt was attempted before the command was read"
  [ "$(grep -c PUT "$calls")" = 1 ] || fail "the receipt must be one bounded extra request"

  # A refused reaction must stay silent and must not disturb the wake.
  home="$TMP_ROOT/receipt-refused"
  write_phone_env "$home"
  seed_phone_cursor "$home" 8100
  fakebin=$(make_fake_curl "$home")
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"8101",channel_id:$channel,author:{id:$captain,bot:false},content:"Merge it"}]
  ')
  out=$(FAKE_PHONE_REACT_CODE=403 FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin" 2>&1)
  [ "$out" = "phone-message 8101" ] \
    || fail "a refused receipt must not add output or lose the wake: $out"
  assert_present "$home/state/phone-inbox/8101.json" "a refused receipt must not lose the command"
  pass "the receipt is a reaction placed after durable storage, and its failure is silent"
}

test_ack_can_still_be_turned_off() {
  local home fakebin out reacts body
  home="$TMP_ROOT/receipt-off"
  write_phone_env "$home"
  seed_phone_cursor "$home" 8200
  fakebin=$(make_fake_curl "$home")
  reacts="$home/reacts.log"
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"8201",channel_id:$channel,author:{id:$captain,bot:false},content:"Status?"}]
  ')
  out=$(FM_PHONE_ACK=0 FAKE_PHONE_REACT_LOG="$reacts" FAKE_PHONE_POLL_BODY="$body" \
    run_poll "$home" "$fakebin")
  [ "$out" = "phone-message 8201" ] || fail "the wake was lost with receipts off"
  assert_absent "$reacts" "FM_PHONE_ACK=0 must suppress the receipt reaction"
  pass "receipts remain opt-out through the existing setting"
}

test_cursor_is_monotonic_and_inbox_is_idempotent() {
  local home fakebin out body count cursor_log
  home="$TMP_ROOT/cursor"
  write_phone_env "$home"
  seed_phone_cursor "$home" 3000
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
  seed_phone_cursor "$home" 4000
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

test_first_sweep_baselines_instead_of_replaying_history() {
  local home fakebin out posts body inbox cursor next
  home="$TMP_ROOT/baseline"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  posts="$home/posts.log"
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [
      {id:"5001",channel_id:$channel,author:{id:$captain,bot:false},content:"merge PR #7"},
      {id:"5002",channel_id:$channel,author:{id:$captain,bot:false},content:"stale direction"}
    ]
  ')
  out=$(FAKE_PHONE_POST_LOG="$posts" FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "first sweep must not wake on pre-existing channel history: $out"
  assert_absent "$posts" "first sweep must not acknowledge pre-existing channel history"
  inbox=$(find "$home/state/phone-inbox" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$inbox" = 0 ] || fail "first sweep must not stash pre-existing channel history"
  cursor=$(cat "$home/state/phone-cursor")
  [ "$cursor" = 5002 ] \
    || fail "first sweep must baseline at Discord's channel head, not a local clock value: $cursor"

  next=$((cursor + 1))
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" --arg id "$next" '
    [{id:$id,channel_id:$channel,author:{id:$captain,bot:false},content:"Fresh direction"}]
  ')
  out=$(FM_PHONE_ACK=0 FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-message $next" ] || fail "a command sent after the baseline must be delivered: $out"
  pass "opt-in baselines at the channel head instead of replaying history or trusting the local clock"
}

test_baselined_empty_channel_still_delivers_the_next_command() {
  local home fakebin out body cursor next
  home="$TMP_ROOT/baseline-empty"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(FAKE_PHONE_POLL_BODY='[]' run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "first sweep of an empty channel must be silent: $out"
  cursor=$(cat "$home/state/phone-cursor")
  [ "${#cursor}" -ge 17 ] || fail "an empty first page must still baseline the cursor: $cursor"

  next=$((cursor + 1))
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" --arg id "$next" '
    [{id:$id,channel_id:$channel,author:{id:$captain,bot:false},content:"First real command"}]
  ')
  out=$(FM_PHONE_ACK=0 FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-message $next" ] || fail "the first command after an empty baseline was swallowed: $out"
  pass "baselining an empty channel never swallows the first real command"
}

test_unreadable_message_content_reports_a_generic_error() {
  local home fakebin out body inbox
  home="$TMP_ROOT/content"
  write_phone_env "$home"
  seed_phone_cursor "$home" 6000
  fakebin=$(make_fake_curl "$home")
  body=$(jq -cn --arg captain "$CAPTAIN_ID" --arg channel "$CHANNEL_ID" '
    [{id:"6001",channel_id:$channel,author:{id:$captain,bot:false},content:""}]
  ')
  out=$(FAKE_PHONE_POLL_BODY="$body" run_poll "$home" "$fakebin")
  [ "$out" = "phone-mode-error Discord message content unavailable" ] \
    || fail "an authenticated message with no readable content must not fail silently: $out"
  assert_not_contains "$out" "$PHONE_TOKEN" "content diagnostic leaked the bot token"
  assert_not_contains "$out" "$CHANNEL_ID" "content diagnostic leaked the channel id"
  assert_not_contains "$out" "$CAPTAIN_ID" "content diagnostic leaked the captain id"
  inbox=$(find "$home/state/phone-inbox" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$inbox" = 0 ] || fail "an empty-content message must not become a command"
  pass "a missing Discord message-content intent reports a generic local error"
}

test_watcher_shim_pins_identity_to_the_home_env() {
  local home fakebin out body shim
  home="$TMP_ROOT/pinned"
  write_phone_env "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PHONE: Discord phone mode on" "pinning test needs an armed phone mode"
  shim="$home/state/phone-watch.check.sh"
  assert_present "$shim" "pinning test needs the generated shim"
  seed_phone_cursor "$home" 7000
  fakebin=$(make_fake_curl "$home")
  {
    printf 'FM_PHONE_DISCORD_TOKEN=%s\n' "$PHONE_TOKEN"
    printf 'FM_PHONE_CAPTAIN_ID=%s\n' "$OTHER_AUTHOR_ID"
    printf 'FM_PHONE_CHANNEL_ID=%s\n' "$OTHER_CHANNEL_ID"
  } > "$home/forged.env"
  body=$(jq -cn \
    --arg captain "$CAPTAIN_ID" \
    --arg channel "$CHANNEL_ID" \
    --arg other_author "$OTHER_AUTHOR_ID" \
    --arg other_channel "$OTHER_CHANNEL_ID" '
      [
        {id:"7001",channel_id:$other_channel,author:{id:$other_author,bot:false},content:"env-injected sender"},
        {id:"7002",channel_id:$channel,author:{id:$captain,bot:false},content:"Configured captain"}
      ]
    ')
  out=$(PATH="$fakebin:$BASE_PATH" \
    FAKE_PHONE_EXPECTED_TOKEN="$PHONE_TOKEN" \
    FAKE_PHONE_POLL_BODY="$body" \
    FM_PHONE_ACK=1 \
    FM_PHONE_CAPTAIN_ID="$OTHER_AUTHOR_ID" \
    FM_PHONE_CHANNEL_ID="$OTHER_CHANNEL_ID" \
    FM_PHONE_ENV_FILE="$home/forged.env" \
    "$shim")
  [ "$out" = "phone-message 7002" ] || fail "watcher shim honored an injected identity: $out"
  assert_absent "$home/state/phone-inbox/7001.json" "an environment-injected sender must not command the home"
  assert_present "$home/state/phone-inbox/7002.json" "the .env-configured captain must still command the home"
  pass "the generated watcher shim authenticates only from the arming home .env"
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

# --- the live summary -------------------------------------------------------

run_summary() {  # <home> <fakebin> -- <args...>
  local home=$1 fakebin=$2
  shift 2
  [ "${1:-}" = "--" ] && shift
  PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FAKE_PHONE_EXPECTED_TOKEN="$PHONE_TOKEN" \
    "$ROOT/bin/fm-phone-summary.sh" "$@"
}

test_summary_is_created_once_then_edited_in_place() {
  local home fakebin out urls first second
  home="$TMP_ROOT/summary-edit"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  urls="$home/urls.log"
  printf '3 running, 1 needs you, 2 green\n' > "$home/summary.txt"

  first=$(FAKE_PHONE_URL_LOG="$urls" \
    FAKE_PHONE_POST_BODY='{"id":"9001"}' \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt")
  [ "$first" = 9001 ] || fail "the first publish did not report its message: $first"
  [ "$(grep -c ' POST ' "$urls")" = 0 ] || true
  [ "$(grep -c POST "$urls")" = 1 ] || fail "the first publish should post exactly one message"

  # Second run: same message, edited. No second post, ever.
  printf '4 running, none need you\n' > "$home/summary.txt"
  second=$(FAKE_PHONE_URL_LOG="$urls" \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt")
  [ "$second" = 9001 ] || fail "the update did not reuse the same message: $second"
  [ "$(grep -c POST "$urls")" = 1 ] || fail "the update posted a second summary instead of editing"
  [ "$(grep -c PATCH "$urls")" = 1 ] || fail "the update did not edit the existing message"
  assert_grep '/messages/9001' "$urls" "the edit must target the recorded message"
  pass "one summary is created once and then edited in place, never reposted"
}

test_summary_survives_a_restart_through_its_durable_record() {
  local home fakebin urls again record
  home="$TMP_ROOT/summary-restart"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  urls="$home/urls.log"
  printf 'first line\n' > "$home/summary.txt"
  FAKE_PHONE_POST_BODY='{"id":"9101"}' \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt" >/dev/null \
    || fail "initial publish failed"

  record="$home/state/phone-summary-id"
  assert_present "$record" "the summary's identity must be recorded on disk"
  [ "$(cat "$record")" = 9101 ] || fail "the recorded identity is wrong"

  # A restart carries no memory: a fresh process must find the message on disk.
  printf 'after a restart\n' > "$home/summary.txt"
  again=$(FAKE_PHONE_URL_LOG="$urls" \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt")
  [ "$again" = 9101 ] || fail "a restart lost the summary and started a new one: $again"
  [ "$(grep -c POST "$urls")" = 0 ] || fail "a restart reposted the summary"
  pass "the summary is found again after a restart from its durable record"
}

test_summary_recovers_from_history_rather_than_posting_a_second_one() {
  local home fakebin out urls history
  home="$TMP_ROOT/summary-recover"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  urls="$home/urls.log"
  # The durable record is gone, and the channel holds a stale receipt from an
  # older build alongside the real summary. Only the summary may be adopted.
  history=$(jq -cn --arg channel "$CHANNEL_ID" '
    [
      {id:"9203",channel_id:$channel,content:"⚓ received"},
      {id:"9202",channel_id:$channel,content:"⚓ 2 running, 1 needs you"},
      {id:"9201",channel_id:$channel,content:"an ordinary message"}
    ]')
  printf 'recovered summary\n' > "$home/summary.txt"

  out=$(FAKE_PHONE_URL_LOG="$urls" FAKE_PHONE_POLL_BODY="$history" \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt")
  [ "$out" = 9202 ] || fail "recovery adopted the wrong message: $out"
  [ "$(grep -c POST "$urls")" = 0 ] || fail "recovery posted a second live summary"
  [ "$(cat "$home/state/phone-summary-id")" = 9202 ] \
    || fail "recovery did not record the adopted message"
  pass "a lost record recovers the existing summary instead of adding another"
}

test_summary_never_overwrites_a_message_it_did_not_author() {
  local home fakebin out urls history
  home="$TMP_ROOT/summary-foreign"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  urls="$home/urls.log"
  # The only marked message belongs to someone else, so Discord refuses the
  # edit. The summary must be created rather than forced onto that message.
  history=$(jq -cn --arg channel "$CHANNEL_ID" '
    [{id:"9301",channel_id:$channel,content:"⚓ my own pinned note"}]')
  printf 'a fresh summary\n' > "$home/summary.txt"

  out=$(FAKE_PHONE_URL_LOG="$urls" \
    FAKE_PHONE_POLL_BODY="$history" \
    FAKE_PHONE_PATCH_CODE_9301=403 \
    FAKE_PHONE_POST_BODY='{"id":"9302"}' \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt")
  [ "$out" = 9302 ] || fail "a refused edit did not fall through to a new summary: $out"
  [ "$(cat "$home/state/phone-summary-id")" = 9302 ] \
    || fail "the newly created summary was not recorded"
  pass "a message this home did not author is never overwritten"
}

test_summary_degrades_when_pinning_is_refused() {
  local home fakebin out rc err
  home="$TMP_ROOT/summary-nopin"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'pinless summary\n' > "$home/summary.txt"

  err=$(FAKE_PHONE_PIN_CODE=403 FAKE_PHONE_POST_BODY='{"id":"9401"}' \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt" 2>&1 >/dev/null)
  rc=$?
  expect_code 6 "$rc" "a summary whose pin was refused"
  assert_contains "$err" "Manage Messages" \
    "a refused pin must name the permission that would fix it"
  [ "$(cat "$home/state/phone-summary-id")" = 9401 ] \
    || fail "a refused pin must not cost the summary its identity"

  # The next update still edits in place: pinning is optional, editing is not.
  out=$(run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt")
  rc=$?
  expect_code 0 "$rc" "an update after a refused pin"
  [ "$out" = 9401 ] || fail "an unpinned summary lost its identity: $out"
  pass "a refused pin degrades to an edited message and names the permission needed"
}

test_summary_repin_retries_only_when_asked() {
  local home fakebin pins out rc
  home="$TMP_ROOT/summary-repin"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  pins="$home/pins.log"
  printf 'summary\n' > "$home/summary.txt"
  FAKE_PHONE_PIN_CODE=403 FAKE_PHONE_POST_BODY='{"id":"9601"}' \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt" >/dev/null 2>&1

  # An ordinary update must not ask a channel that already refused.
  run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt" >/dev/null 2>&1
  assert_absent "$pins" "an ordinary update should not re-request the pin"

  # --repin is the deliberate retry, for after the permission is granted.
  out=$(FAKE_PHONE_PIN_LOG="$pins" \
    run_summary "$home" "$fakebin" -- --repin --text-file "$home/summary.txt")
  rc=$?
  expect_code 0 "$rc" "a --repin once the permission exists"
  [ "$out" = 9601 ] || fail "--repin changed the summary's identity: $out"
  assert_grep '/pins/9601' "$pins" "--repin must pin the existing summary"
  pass "pinning is retried only when deliberately asked for"
}

test_summary_accepts_stdin_like_the_reply_client() {
  local home fakebin posts out
  home="$TMP_ROOT/summary-stdin"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  posts="$home/posts.log"
  out=$(printf '2 running, none need you\n' \
    | FAKE_PHONE_POST_LOG="$posts" FAKE_PHONE_POST_BODY='{"id":"9701"}' \
      run_summary "$home" "$fakebin" -- -)
  [ "$out" = 9701 ] || fail "the stdin form did not publish: $out"
  [ "$(jq -r .content "$posts")" = "⚓ 2 running, none need you" ] \
    || fail "the stdin form altered the summary text"
  pass "the summary reads stdin exactly as the reply client does"
}

test_summary_refuses_to_forget_a_message_it_just_posted() {
  local home fakebin rc out
  home="$TMP_ROOT/summary-no-id"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'summary text\n' > "$home/summary.txt"
  out=$(FAKE_PHONE_POST_BODY='{"no_id_here":true}' \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt" 2>&1)
  rc=$?
  expect_code 4 "$rc" "a publish whose message id came back unusable"
  assert_contains "$out" "identity" "an unrecorded summary must say so plainly"
  assert_absent "$home/state/phone-summary-id" "an unusable id must not be recorded"
  pass "a summary that cannot be identified again fails loudly instead of silently reposting"
}

test_summary_is_inert_and_leaks_nothing() {
  local home fakebin rc out
  home="$TMP_ROOT/summary-inert"
  mkdir -p "$home"
  printf 'summary\n' > "$home/summary.txt"
  out=$(FM_HOME="$home" PATH="$BASE_PATH" \
    "$ROOT/bin/fm-phone-summary.sh" --text-file "$home/summary.txt" 2>&1)
  rc=$?
  expect_code 3 "$rc" "an unconfigured home"
  assert_contains "$out" "not configured" "an unconfigured home should say so"

  home="$TMP_ROOT/summary-noleak"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'summary\n' > "$home/summary.txt"
  out=$(FAKE_PHONE_PIN_CODE=403 FAKE_PHONE_POST_CODE=500 \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt" 2>&1)
  assert_not_contains "$out" "$PHONE_TOKEN" "a summary failure leaked the bot token"
  assert_not_contains "$out" "$CHANNEL_ID" "a summary failure leaked the channel id"
  assert_not_contains "$out" "$CAPTAIN_ID" "a summary failure leaked the captain id"
  pass "the summary is inert without opt-in and never echoes a configured value"
}

test_summary_suppresses_mentions_and_keeps_text_out_of_the_shell() {
  local home fakebin posts text
  home="$TMP_ROOT/summary-safe"
  write_phone_env "$home"
  fakebin=$(make_fake_curl "$home")
  posts="$home/posts.log"
  # shellcheck disable=SC2016 # Shell metacharacters must remain literal test data.
  text='@everyone $(whoami) `date` 3 running'
  printf '%s' "$text" > "$home/summary.txt"
  FAKE_PHONE_POST_LOG="$posts" FAKE_PHONE_POST_BODY='{"id":"9501"}' \
    run_summary "$home" "$fakebin" -- --text-file "$home/summary.txt" >/dev/null \
    || fail "publish failed"
  [ "$(jq -r .content "$posts")" = "⚓ $text" ] \
    || fail "the summary text was altered beyond its marker"
  [ "$(jq -c .allowed_mentions "$posts")" = '{"parse":[]}' ] \
    || fail "the standing summary must never be able to ping"
  pass "the summary stays literal text and can never interrupt the captain"
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

test_nonprivate_state_is_repaired_before_arm_and_rejected_during_poll() {
  local home fakebin out calls
  home="$TMP_ROOT/nonprivate-state"
  write_phone_env "$home"
  mkdir -p "$home/state"
  chmod 755 "$home/state"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PHONE: Discord phone mode on" \
    "bootstrap must arm phone mode after repairing a nonprivate state directory"
  [ "$(directory_mode "$home/state")" = 700 ] \
    || fail "bootstrap armed phone mode without making state mode 700"
  assert_present "$home/state/phone-watch.check.sh" \
    "repaired phone mode must publish its poll shim"
  assert_present "$home/state/phone-watch.check-trust" \
    "repaired phone mode must publish its trust record"

  fakebin=$(make_fake_curl "$home")
  calls="$home/calls.log"
  out=$(FAKE_PHONE_CALL_LOG="$calls" FAKE_PHONE_POLL_BODY='[]' run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "a repaired empty-channel baseline must be silent: $out"
  assert_present "$home/state/phone-cursor" \
    "an armed phone mode must be structurally able to record its cursor"

  chmod 755 "$home/state"
  rm -f "$calls"
  out=$(FAKE_PHONE_CALL_LOG="$calls" run_poll "$home" "$fakebin")
  assert_contains "$out" "phone-mode-error local filesystem precondition" \
    "poll-time state permission drift must be attributed to the local filesystem"
  assert_contains "$out" "requires mode 700: $home/state" \
    "the local filesystem diagnostic must name the directory and required mode"
  assert_not_contains "$out" "$PHONE_TOKEN" "local filesystem diagnostic leaked the bot token"
  assert_not_contains "$out" "$CHANNEL_ID" "local filesystem diagnostic leaked the channel id"
  assert_not_contains "$out" "$CAPTAIN_ID" "local filesystem diagnostic leaked the captain id"
  assert_absent "$calls" "an invalid private state directory must be rejected before contacting Discord"
  pass "bootstrap repairs nonprivate state and poll-time drift is locally attributed without config leakage"
}

# Bootstrap must never arm on a state directory the poller would then reject, so
# the arm-time and poll-time gates have to be the same predicate. A state path
# that cannot become an ordinary mode-700 directory - because it is a file, or
# because its parent is a symlink - must refuse by naming the directory and the
# required mode, and must leave nothing armed behind.
test_unpreparable_private_state_refuses_to_arm() {
  local home fakebin out calls link
  home="$TMP_ROOT/unpreparable-state"
  write_phone_env "$home"
  : > "$home/state"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PHONE: Discord phone mode off - local private state directory requires mode 700: $home/state" \
    "a state path that cannot become a private directory must refuse to arm"
  assert_not_contains "$out" "PHONE: Discord phone mode on" \
    "an unpreparable private state directory must never report a successful arm"
  assert_not_contains "$out" "$PHONE_TOKEN" "the state refusal leaked the bot token"
  assert_not_contains "$out" "$CHANNEL_ID" "the state refusal leaked the channel id"
  assert_not_contains "$out" "$CAPTAIN_ID" "the state refusal leaked the captain id"
  assert_absent "$home/config/phone-mode.env" "an unpreparable state directory must not enable fast cadence"
  [ ! -d "$home/state" ] || fail "the refusal replaced the operator's own state path"

  link="$TMP_ROOT/unpreparable-state-link"
  rm -rf "$TMP_ROOT/symlinked-home"
  mkdir -p "$TMP_ROOT/symlinked-home"
  write_phone_env "$TMP_ROOT/symlinked-home"
  (umask 077; mkdir -p "$TMP_ROOT/symlinked-home/state")
  rm -f "$link"
  ln -s "$TMP_ROOT/symlinked-home" "$link"

  out=$(FM_HOME="$link" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "PHONE: Discord phone mode off - local private state directory requires mode 700: $link/state" \
    "a symlinked home must refuse at arm time rather than fail every later poll"
  assert_not_contains "$out" "PHONE: Discord phone mode on" \
    "a state directory the poller rejects must never produce a successful arm"
  assert_absent "$link/state/phone-watch.check.sh" "a refused arm must not publish a poll shim"
  assert_absent "$link/state/phone-watch.check-trust" "a refused arm must not register trust"
  assert_absent "$link/config/phone-mode.env" "a refused arm must not enable fast cadence"

  fakebin=$(make_fake_curl "$TMP_ROOT/symlinked-home")
  calls="$TMP_ROOT/symlinked-home/calls.log"
  out=$(FAKE_PHONE_CALL_LOG="$calls" run_poll "$link" "$fakebin")
  assert_contains "$out" "phone-mode-error local filesystem precondition" \
    "the poller must reject exactly the state directories bootstrap refuses to arm"
  assert_absent "$calls" "a refused private state directory must be rejected before contacting Discord"
  pass "an unpreparable private state directory refuses to arm and matches the poll-time gate"
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

# The remote authority boundary lives only in the handler skill, so assert each
# honored and helm-only class by side. Losing a class, or moving one across the
# boundary, must fail here rather than silently widening phone authority.
test_authority_boundary_keeps_its_exact_classes() {
  local skill honored refused item
  skill="$ROOT/.agents/skills/fmphone-respond/SKILL.md"
  assert_present "$skill" "the phone authority boundary lost its owning skill"
  honored=$(awk '/^Honor these classes from the phone:/{s=1;next} /^Refuse these classes from the phone/{s=0} s' "$skill")
  refused=$(awk '/^Refuse these classes from the phone/{s=1;next} /^This boundary is exact\./{s=0} s' "$skill")

  for item in \
    'Direction and priority changes.' \
    'Questions about fleet state or work.' \
    'Dispatching ordinary ships and scouts.' \
    'Routine ask-user decisions that do not expand into a helm-only class.' \
    'Explicit PR merge approval.'; do
    assert_contains "$honored" "- $item" "the phone must still honor a routine class: $item"
    assert_not_contains "$refused" "$item" "an honored phone class drifted into the refusal list: $item"
  done

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the skill text.
  for item in \
    'Discarding unlanded work or forcing teardown.' \
    'Force-pushing.' \
    'Deleting a repository or project.' \
    'Changing credentials, tokens, secrets, authentication, or security settings.' \
    'Spending money or authorizing a purchase.' \
    'Anything `AGENTS.md` section 9 classes as destructive, irreversible, or security-sensitive.'; do
    assert_contains "$refused" "- $item" "the phone must still refuse a helm-only class: $item"
    assert_not_contains "$honored" "$item" "a helm-only class drifted into the honored list: $item"
  done

  assert_grep 'Do not loosen it because the sender is authenticated' "$skill" \
    "the skill dropped its rule against widening the boundary for authenticated senders"
  assert_grep 'Do not partially execute a refused request.' "$skill" \
    "the skill dropped its no-partial-execution rule for refused requests"
  assert_grep 'This needs confirmation at the helm before I can proceed.' "$skill" \
    "the skill dropped the helm-confirmation refusal reply"
  pass "the remote authority boundary keeps its exact honored and helm-only classes"
}

test_inert_by_default
test_two_part_filter_and_bot_loop_guard_are_silent
test_accepted_message_stashes_acks_and_wakes
test_cursor_is_monotonic_and_inbox_is_idempotent
test_one_page_coalesces_to_one_wake
test_poll_is_one_bounded_request_without_a_message
test_first_sweep_baselines_instead_of_replaying_history
test_baselined_empty_channel_still_delivers_the_next_command
test_unreadable_message_content_reports_a_generic_error
test_watcher_shim_pins_identity_to_the_home_env
test_reply_reads_file_verbatim_and_suppresses_mentions
test_receipt_is_a_reaction_and_never_claims_an_action_succeeded
test_ack_can_still_be_turned_off
test_summary_is_created_once_then_edited_in_place
test_summary_survives_a_restart_through_its_durable_record
test_summary_recovers_from_history_rather_than_posting_a_second_one
test_summary_never_overwrites_a_message_it_did_not_author
test_summary_degrades_when_pinning_is_refused
test_summary_repin_retries_only_when_asked
test_summary_accepts_stdin_like_the_reply_client
test_summary_refuses_to_forget_a_message_it_just_posted
test_summary_is_inert_and_leaks_nothing
test_summary_suppresses_mentions_and_keeps_text_out_of_the_shell
test_generic_errors_never_echo_configuration
test_nonprivate_state_is_repaired_before_arm_and_rejected_during_poll
test_unpreparable_private_state_refuses_to_arm
test_bootstrap_generation_identity_and_opt_out
test_partial_bootstrap_config_stays_off_without_leaking_values
test_authority_boundary_keeps_its_exact_classes

#!/usr/bin/env bash
# Poll one bounded page of Discord channel history for authenticated phone-mode
# commands. This is the trusted target of state/phone-watch.check.sh.
#
# Inert by default: unless the Discord bot token, captain user id, and private
# channel id all resolve validly, this exits 0 without output, files, or network.
#
# The first sweep of a home without a durable state/phone-cursor only baselines
# that cursor at "now" and delivers nothing, so opting in never replays existing
# channel history as live captain commands.
#
# A configured sweep performs one bounded GET, advances state/phone-cursor
# monotonically across every returned Discord message id, and accepts a command
# only when BOTH author.id == FM_PHONE_CAPTAIN_ID and channel_id ==
# FM_PHONE_CHANNEL_ID. Bot-authored messages are rejected independently, so the
# bridge cannot consume its own acknowledgements or replies. Accepted objects
# are stored whole at state/phone-inbox/<message_id>.json using create-once
# publication. One compact "phone-message <message_id>" line wakes firstmate;
# the fmphone-respond skill drains every pending inbox file.
#
# FM_PHONE_ACK defaults on. When at least one command is accepted, one additional
# bounded POST sends "⚓ received" as a delivery acknowledgement. Its failure is
# silent and never blocks the durable inbox wake.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-phone-lib.sh
. "$SCRIPT_DIR/fm-phone-lib.sh"

fm_phone_load_config
[ "$FM_PHONE_CONFIGURED" = 1 ] || exit 0

ERROR_FILE="$STATE/phone-poll.error"

emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE" phone-poll.error 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE" phone-poll.error 600 2>/dev/null || true
  printf 'phone-mode-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_dir_device "$STATE" >/dev/null 2>&1 || return 0
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-phone-poll.XXXXXX") || exit 0
MESSAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-phone-message.XXXXXX") || {
  rm -f "$BODY_FILE"
  exit 0
}
ACK_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-phone-ack.XXXXXX") || {
  rm -f "$BODY_FILE" "$MESSAGE_FILE"
  exit 0
}
trap 'rm -f "$BODY_FILE" "$MESSAGE_FILE" "$ACK_FILE"' EXIT HUP INT TERM

CURSOR=$(fm_phone_cursor_get "$STATE" 2>/dev/null) || {
  emit_error_once "cannot read cursor"
  exit 0
}

CODE=$(fm_phone_poll_request "$BODY_FILE" "$CURSOR") || exit 0
case "$CODE" in
  200) ;;
  401|403|404) emit_error_once "Discord poll unavailable"; exit 0 ;;
  *) exit 0 ;;
esac

jq -e 'type == "array"' "$BODY_FILE" >/dev/null 2>&1 || {
  emit_error_once "invalid Discord response"
  exit 0
}

MAX_ID=$CURSOR
WAKE_ID=
STASH_FAILED=0
CONTENT_MISSING=0
# A home with no durable cursor has never been swept. Its first page is history,
# not fresh direction, so it is only used to place the cursor at "now".
BASELINE=0
[ "$CURSOR" = 0 ] && BASELINE=1

# Decimal-string ordering preserves full Discord snowflake precision. The
# response is normalized oldest-first so the cursor and inbox converge even if
# Discord returns newest-first.
while IFS= read -r MESSAGE; do
  [ -n "$MESSAGE" ] || continue
  MESSAGE_ID=$(printf '%s' "$MESSAGE" | jq -r '.id // empty' 2>/dev/null) || continue
  fm_phone_discord_id_valid "$MESSAGE_ID" || continue

  if fm_phone_id_newer "$MESSAGE_ID" "$MAX_ID"; then
    MAX_ID=$MESSAGE_ID
  fi
  [ "$BASELINE" = 0 ] || continue
  # At-least-once transport responses at or below the durable cursor are never
  # offered again, even if a stub or proxy repeats them.
  fm_phone_id_newer "$MESSAGE_ID" "$CURSOR" || continue

  MESSAGE_CHANNEL=$(printf '%s' "$MESSAGE" | jq -r '.channel_id // empty' 2>/dev/null) || continue
  MESSAGE_AUTHOR=$(printf '%s' "$MESSAGE" | jq -r '.author.id // empty' 2>/dev/null) || continue
  MESSAGE_BOT=$(printf '%s' "$MESSAGE" | jq -r 'if .author.bot == true then "1" else "0" end' 2>/dev/null) || continue
  MESSAGE_TEXT=$(printf '%s' "$MESSAGE" | jq -r '(.content // "") | gsub("[[:space:]]+"; "")' 2>/dev/null) || continue

  # Authentication is deliberately two-part and fail-closed. The bot flag is
  # an independent loop guard even though the captain-id check also excludes a
  # normally configured bot account.
  [ "$MESSAGE_AUTHOR" = "$FM_PHONE_CAPTAIN" ] || continue
  [ "$MESSAGE_CHANNEL" = "$FM_PHONE_CHANNEL" ] || continue
  [ "$MESSAGE_BOT" = 0 ] || continue
  # An authenticated captain message with no readable content is the signature
  # of a bot that lacks Discord's message-content intent. Record it so the
  # sweep reports a generic diagnostic instead of failing silently.
  if [ -z "$MESSAGE_TEXT" ]; then
    CONTENT_MISSING=1
    continue
  fi

  printf '%s\n' "$MESSAGE" > "$MESSAGE_FILE" || { STASH_FAILED=1; break; }
  fm_phone_inbox_stash "$STATE" "$MESSAGE_ID" "$MESSAGE_FILE"
  STASH_RC=$?
  case "$STASH_RC" in
    0|1) WAKE_ID=$MESSAGE_ID ;;
    *) STASH_FAILED=1; break ;;
  esac
done < <(jq -c 'sort_by([(.id // "" | tostring | length), (.id // "" | tostring)])[]' "$BODY_FILE" 2>/dev/null)

if [ "$STASH_FAILED" = 1 ]; then
  emit_error_once "cannot write inbox"
  exit 0
fi

if [ "$BASELINE" = 1 ]; then
  # The newest id on an unfiltered first page is Discord's own channel head, so
  # it baselines exactly at "everything that already exists" with no dependence
  # on the local clock. Only a genuinely empty channel has no head to use, and
  # its synthesized fallback still keeps the next command from being swallowed.
  if [ "$MAX_ID" != 0 ]; then
    BASE_ID=$MAX_ID
  else
    BASE_ID=$(fm_phone_now_snowflake) || exit 0
  fi
  if ! fm_phone_cursor_set "$STATE" "$BASE_ID"; then
    emit_error_once "cannot record cursor"
    exit 0
  fi
  clear_error
  exit 0
fi

if [ "$MAX_ID" != "$CURSOR" ]; then
  if ! fm_phone_cursor_set "$STATE" "$MAX_ID"; then
    emit_error_once "cannot record cursor"
    exit 0
  fi
fi

if [ -z "$WAKE_ID" ] && [ "$CONTENT_MISSING" = 1 ]; then
  emit_error_once "Discord message content unavailable"
  exit 0
fi

clear_error
[ -n "$WAKE_ID" ] || exit 0

if [ "$FM_PHONE_ACK_ENABLED" = 1 ] \
  && fm_phone_message_payload '⚓ received' "$WAKE_ID" > "$ACK_FILE"; then
  fm_phone_post_payload "$ACK_FILE" >/dev/null 2>&1 || true
fi

printf 'phone-message %s\n' "$WAKE_ID"

#!/usr/bin/env bash
# Post one firstmate response to the configured private Discord phone channel.
#
# Usage:
#   fm-phone-reply.sh <message_id> --text-file <path>
#   fm-phone-reply.sh <message_id> -
#
# The file/stdin-only interface keeps Discord-influenced text out of shell
# interpolation. Long replies split into at most four Discord-safe messages by
# default; only the opener references the inbound command. Success prints the
# message id and exits 0. Transport and configuration failures are generic and
# never echo the token, channel id, URL, payload, or Discord response body.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-phone-lib.sh
. "$SCRIPT_DIR/fm-phone-lib.sh"

usage() {
  printf '%s\n' \
    'usage: fm-phone-reply.sh <message_id> --text-file <path>' \
    '       fm-phone-reply.sh <message_id> -' >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

MESSAGE_ID=${1:-}
fm_phone_discord_id_valid "$MESSAGE_ID" || { usage; exit 2; }
shift

if [ "$#" -eq 2 ] && [ "$1" = --text-file ]; then
  [ -f "$2" ] && [ ! -L "$2" ] || {
    echo "fm-phone-reply: reply text file is unavailable" >&2
    exit 2
  }
  TEXT=$(cat -- "$2")
elif [ "$#" -eq 1 ] && [ "$1" = - ]; then
  TEXT=$(cat)
else
  usage
  exit 2
fi

case "$(printf '%s' "$TEXT" | tr -d '[:space:]')" in
  '') echo "fm-phone-reply: empty reply text" >&2; exit 2 ;;
esac

fm_phone_load_config
if [ "$FM_PHONE_CONFIGURED" != 1 ]; then
  echo "fm-phone-reply: Discord phone mode is not configured" >&2
  exit 3
fi
command -v curl >/dev/null 2>&1 || { echo "fm-phone-reply: curl is unavailable" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "fm-phone-reply: jq is unavailable" >&2; exit 3; }

REPLY_MAX=$(fm_phone_bounded "$(fm_phone_config_get FM_PHONE_REPLY_MAX_CHARS)" 1900 50 1900)
REPLY_PARTS=$(fm_phone_bounded "$(fm_phone_config_get FM_PHONE_REPLY_MAX_PARTS)" 4 1 10)
CHUNKS=$(printf '%s' "$TEXT" | fmx_split_thread "$REPLY_MAX" "$REPLY_PARTS") || {
  echo "fm-phone-reply: cannot shape reply" >&2
  exit 4
}
COUNT=$(printf '%s' "$CHUNKS" | jq 'length' 2>/dev/null) || COUNT=0
case "$COUNT" in
  ''|*[!0-9]*|0) echo "fm-phone-reply: cannot shape reply" >&2; exit 4 ;;
esac

PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-phone-reply.XXXXXX") || {
  echo "fm-phone-reply: cannot create private payload" >&2
  exit 4
}
trap 'rm -f "$PAYLOAD_FILE"' EXIT HUP INT TERM

INDEX=0
while [ "$INDEX" -lt "$COUNT" ]; do
  CHUNK=$(printf '%s' "$CHUNKS" | jq -r --argjson i "$INDEX" '.[$i]') || {
    echo "fm-phone-reply: cannot shape reply" >&2
    exit 4
  }
  REFERENCE=
  [ "$INDEX" -ne 0 ] || REFERENCE=$MESSAGE_ID
  fm_phone_message_payload "$CHUNK" "$REFERENCE" > "$PAYLOAD_FILE" || {
    echo "fm-phone-reply: cannot shape reply" >&2
    exit 4
  }
  if ! fm_phone_post_payload "$PAYLOAD_FILE"; then
    echo "fm-phone-reply: Discord delivery failed" >&2
    exit 4
  fi
  INDEX=$((INDEX + 1))
done

printf '%s\n' "$MESSAGE_ID"

#!/usr/bin/env bash
# Keep ONE live fleet summary current in the Discord phone channel by editing
# the same message in place, never by posting a new one.
#
# Usage:
#   fm-phone-summary.sh --text-file <path>
#   <summary on stdin> | fm-phone-summary.sh -
#   fm-phone-summary.sh --repin --text-file <path>
#   fm-phone-summary.sh --help
#
# This is a dumb writer. Firstmate composes the summary line; AGENTS.md section
# 9 stays the single owner of the wording, and this script never invents,
# classifies, or re-words it. The file/stdin-only interface keeps the text out
# of shell interpolation, exactly as fm-phone-reply.sh does.
#
# WHY EDIT AND NOT REPOST
#   A summary that is reposted every time it changes is not a summary; it is the
#   scroll clutter this replaces. Editing one message is the entire point, so
#   the message's identity has to survive a restart.
#
# HOW THE MESSAGE IS IDENTIFIED ACROSS RESTARTS
#   1. state/phone-summary-id holds the message id as a private mode-0600
#      artifact. This is the normal path and it survives restart, compaction,
#      and a new session.
#   2. If that record is missing or Discord no longer accepts an edit to it, one
#      bounded page of recent channel history is read and the newest bot-written
#      message that carries the summary marker is adopted. Narrowing to
#      bot-written candidates only saves requests; Discord permits editing a
#      message this bot itself authored and nothing else, so any other bot's
#      message that starts with the same marker is still refused by Discord
#      rather than overwritten. That refusal is the actual guarantee.
#      A history read that does not succeed is a failure, not an empty channel:
#      reposting on a rate limit would leave two live summaries, so the read has
#      to answer before a new message may be posted.
#   3. Only when neither yields an editable message is a new one posted, and its
#      id is recorded before anything else.
#   Recovery reads history through the same already-permitted route the command
#   poll uses; it needs no pin access.
#
# PINNING IS OPTIONAL AND MAY BE REFUSED
#   Pinning needs Manage Messages, which the bot is not required to hold. A
#   refused pin is reported by name, with the permission that would fix it, and
#   the summary still works as an ordinary message that is edited in place.
#   A pin is attempted only when the message is first created, or on --repin,
#   so a channel that will never grant it is not asked on every update.
#
# CONFIG
#   The three required Discord phone-mode values gate this script exactly as
#   they gate the command poll; see docs/configuration.md. Additionally:
#   FM_PHONE_SUMMARY_MAX_CHARS  summary length cap, default 1900, clamped
#                               50..1900.
#
# EXIT CODES
#   0  the summary is current
#   2  usage error (bad flag, unreadable text file, empty summary)
#   3  Discord phone mode is not configured, or curl/jq is missing
#   4  the summary could not be delivered, its identity could not be recorded,
#      or recent history could not be read to find it
#   6  the summary is current but could not be pinned
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-phone-summary.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-phone-lib.sh
. "$SCRIPT_DIR/fm-phone-lib.sh"

# The acknowledgement message older builds posted before receipts became
# reactions. It carries the same marker, so history recovery must never adopt a
# leftover receipt and edit it into the live summary.
FM_PHONE_LEGACY_ACK='⚓ received'

# How many recent messages recovery inspects. Bounded so a lost record costs one
# ordinary page read, never a channel crawl.
FM_PHONE_SUMMARY_SCAN=50

warn() {
  printf 'fm-phone-summary: %s\n' "$*" >&2
}

print_header() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SELF"
}

usage() {
  printf '%s\n' \
    'usage: fm-phone-summary.sh [--repin] --text-file <path>' \
    '       fm-phone-summary.sh [--repin] -' >&2
}

# --- arguments --------------------------------------------------------------

REPIN=0
TEXT_FILE=
FROM_STDIN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) print_header; exit 0 ;;
    --repin) REPIN=1; shift ;;
    --text-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      TEXT_FILE=$2; shift 2 ;;
    -) FROM_STDIN=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

if [ -n "$TEXT_FILE" ] && [ "$FROM_STDIN" = 0 ]; then
  [ -f "$TEXT_FILE" ] && [ ! -L "$TEXT_FILE" ] || {
    warn "summary text file is unavailable"
    exit 2
  }
  TEXT=$(cat -- "$TEXT_FILE")
elif [ "$FROM_STDIN" = 1 ] && [ -z "$TEXT_FILE" ]; then
  TEXT=$(cat)
else
  usage
  exit 2
fi

case "$(printf '%s' "$TEXT" | tr -d '[:space:]')" in
  '') warn "empty summary; nothing to publish"; exit 2 ;;
esac

# --- configuration ----------------------------------------------------------

fm_phone_load_config
if [ "$FM_PHONE_CONFIGURED" != 1 ]; then
  warn "Discord phone mode is not configured"
  exit 3
fi
command -v curl >/dev/null 2>&1 || { warn "curl is unavailable"; exit 3; }
command -v jq >/dev/null 2>&1 || { warn "jq is unavailable"; exit 3; }

# The summary id is a private artifact published directly into state/, so hold
# that boundary before contacting Discord.
if ! fmx_private_artifact_dir_prepare "$STATE" >/dev/null 2>&1; then
  warn "private state directory requires mode 700"
  exit 4
fi

MAX_CHARS=$(fm_phone_bounded "$(fm_phone_config_get FM_PHONE_SUMMARY_MAX_CHARS)" 1900 50 1900)

# Normalise to one marked line within Discord's message budget. The marker is
# both the captain-facing anchor from the agreed layout and the identity hint
# history recovery matches on, so it is added when the caller left it out.
TEXT=$(printf '%s' "$TEXT" | jq -Rsj \
  --arg marker "$FM_PHONE_SUMMARY_MARKER" \
  --argjson cap "$MAX_CHARS" '
    sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
    | (if startswith($marker) then . else $marker + " " + . end)
    | if (length <= $cap) then . else .[0:$cap - 1] + "…" end
  ') || { warn "cannot shape the summary"; exit 4; }

PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-phone-summary.XXXXXX") || {
  warn "cannot create a private payload"
  exit 4
}
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-phone-summary-body.XXXXXX") || {
  rm -f "$PAYLOAD_FILE"
  warn "cannot create a private payload"
  exit 4
}
trap 'rm -f "$PAYLOAD_FILE" "$BODY_FILE"' EXIT HUP INT TERM

fm_phone_summary_payload "$TEXT" > "$PAYLOAD_FILE" || {
  warn "cannot shape the summary"
  exit 4
}

# --- publish ----------------------------------------------------------------

# try_edit <message_id>: 0 when the live summary now carries this text, 1 when
# that message is not ours to edit or no longer exists, 2 on a real failure.
try_edit() {
  local id=$1 code
  code=$(fm_phone_edit_message "$id" "$PAYLOAD_FILE") || return 2
  case "$code" in
    2[0-9][0-9]) return 0 ;;
    403|404) return 1 ;;
    *) return 2 ;;
  esac
}

# attempt_pin <message_id>: 0 pinned, 1 refused for want of the permission,
# 2 any other pin failure. Never fatal on its own.
attempt_pin() {
  local id=$1 code
  code=$(fm_phone_pin_message "$id") || return 2
  case "$code" in
    2[0-9][0-9]) return 0 ;;
    403) return 1 ;;
    *) return 2 ;;
  esac
}

# report_pin <rc>: translate a pin outcome and set PIN_DEGRADED.
PIN_DEGRADED=0
report_pin() {
  case "$1" in
    0) return 0 ;;
    1)
      warn "the summary is up to date but could not be pinned: the bot needs the Manage Messages permission in that channel"
      PIN_DEGRADED=1
      ;;
    *)
      warn "the summary is up to date but the pin request did not succeed"
      PIN_DEGRADED=1
      ;;
  esac
}

SUMMARY_ID=$(fm_phone_summary_id_get "$STATE" 2>/dev/null) || SUMMARY_ID=

if [ -n "$SUMMARY_ID" ]; then
  try_edit "$SUMMARY_ID"
  case "$?" in
    0)
      if [ "$REPIN" = 1 ]; then
        attempt_pin "$SUMMARY_ID"
        report_pin "$?"
      fi
      printf '%s\n' "$SUMMARY_ID"
      [ "$PIN_DEGRADED" = 0 ] || exit 6
      exit 0
      ;;
    2) warn "cannot reach Discord to update the summary"; exit 4 ;;
  esac
  # A recorded id Discord will not let us edit is stale, not fatal: fall through
  # to recovery rather than posting a duplicate on the strength of one 404.
  warn "the recorded summary is gone; looking for it in recent messages"
fi

# Recovery: adopt this home's own most recent marked message rather than adding
# a second live summary to the channel.
CODE=$(fm_phone_recent_request "$BODY_FILE" "$FM_PHONE_SUMMARY_SCAN") || CODE=
# A read that did not succeed is not evidence that no summary exists. An empty
# channel still answers 200 with an empty list, so anything else here would be a
# guess, and guessing wrong posts a second live summary that can never be
# reconciled with the first. Fail instead.
if [ "$CODE" != 200 ] || ! jq -e 'type == "array"' "$BODY_FILE" >/dev/null 2>&1; then
  warn "cannot read recent messages to find the live summary; it was left as it is"
  exit 4
fi

ADOPTED=
while IFS= read -r CANDIDATE; do
  [ -n "$CANDIDATE" ] || continue
  fm_phone_discord_id_valid "$CANDIDATE" || continue
  try_edit "$CANDIDATE"
  case "$?" in
    0) ADOPTED=$CANDIDATE; break ;;
    2) warn "cannot reach Discord to update the summary"; exit 4 ;;
  esac
done < <(jq -r \
  --arg marker "$FM_PHONE_SUMMARY_MARKER" \
  --arg legacy "$FM_PHONE_LEGACY_ACK" '
    [ .[]
      | select((.content // "") | startswith($marker))
      | select((.content // "") != $legacy)
      | select(.author.bot == true)
      | .id // empty
    ]
    | sort_by([(tostring | length), tostring])
    | reverse
    | .[]
  ' "$BODY_FILE" 2>/dev/null)

if [ -n "$ADOPTED" ]; then
  if ! fm_phone_summary_id_set "$STATE" "$ADOPTED"; then
    warn "the summary was updated but its identity could not be recorded"
    exit 4
  fi
  if [ "$REPIN" = 1 ]; then
    attempt_pin "$ADOPTED"
    report_pin "$?"
  fi
  printf '%s\n' "$ADOPTED"
  [ "$PIN_DEGRADED" = 0 ] || exit 6
  exit 0
fi

# Nothing to edit: this channel has no live summary yet.
if ! fm_phone_post_payload "$PAYLOAD_FILE" "$BODY_FILE"; then
  warn "cannot reach Discord to publish the summary"
  exit 4
fi
CREATED=$(jq -r '.id // empty' "$BODY_FILE" 2>/dev/null) || CREATED=
if ! fm_phone_discord_id_valid "$CREATED"; then
  # Refusing to guess here is deliberate: an unrecorded summary would be
  # reposted on every future update, which is the one outcome worth failing for.
  warn "the summary was posted but Discord returned no usable identity for it"
  exit 4
fi
if ! fm_phone_summary_id_set "$STATE" "$CREATED"; then
  warn "the summary was posted but its identity could not be recorded"
  exit 4
fi

attempt_pin "$CREATED"
report_pin "$?"

printf '%s\n' "$CREATED"
[ "$PIN_DEGRADED" = 0 ] || exit 6
exit 0

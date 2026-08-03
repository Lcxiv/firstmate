#!/usr/bin/env bash
# fm-notify.sh - mirror ONE already-composed captain-facing outcome message to
# the captain's phone through a configured chat channel.
#
# Usage:
#   fm-notify.sh [--event <class>] [--title <text>] [--url <https://...>] [--] <message...>
#   <message on stdin> | fm-notify.sh [--event <class>] ...
#   fm-notify.sh --list-events
#   fm-notify.sh --help
#
# This script is a dumb sender. AGENTS.md section 9 stays the single owner of
# what is worth telling the captain and of the wording; this script never
# invents, classifies, re-words, or suppresses an event on its own judgement.
# The caller names the event class, that class selects presentation and the
# configured filter, and the text is sent verbatim apart from cap-driven
# splitting.
#
# OPT-IN AND INERTNESS
#   Delivery is off until the firstmate home's gitignored .env sets a non-empty
#   FM_NOTIFY_TARGET. With no target a well-formed call prints nothing, writes
#   nothing, contacts nothing, and exits 0. A MALFORMED call is still a usage
#   error even when unconfigured, so a caller bug stays visible in development.
#
# CONFIG (an explicitly set environment variable wins over $FM_HOME/.env;
# FM_NOTIFY_ENV_FILE redirects the file read for direct invocations and tests):
#   FM_NOTIFY_TARGET          "<channel>:<address>", or a bare Discord webhook
#                             URL, which resolves to the discord-webhook
#                             channel. Presence is the opt-in; absent is a
#                             silent no-op. This is the conversation lane.
#   FM_NOTIFY_LOG_TARGET      optional second address, same two forms, for the
#                             broadcast lane. Absent means the broadcast lane
#                             uses FM_NOTIFY_TARGET, which is exactly the
#                             single-address behaviour of a home that never
#                             configured one. It has to resolve to the same
#                             channel as FM_NOTIFY_TARGET - channel meaning the
#                             delivery platform of CHANNEL SEAM below, not the
#                             Discord room, which is the whole point of setting
#                             this - and a value that does not is refused. That
#                             refusal reaches only the classes that use this
#                             address; the four interrupt classes below still
#                             send on FM_NOTIFY_TARGET.
#   FM_NOTIFY_MENTION_ID      the captain's Discord user id, used to mention
#                             them on the four interrupt classes below; falls
#                             back to FM_PHONE_CAPTAIN_ID when that is already
#                             configured. Absent means no mention is added and
#                             the message is still delivered.
#   FM_NOTIFY_EVENTS          comma-separated event classes to mirror, or "all",
#                             or "none". Default: every class except dispatched
#                             (see DEFAULT EVENT SET below).
#   FM_NOTIFY_TIMEOUT_SECS    per-request transport timeout, default 10,
#                             clamped to 1..120.
#   FM_NOTIFY_RETRY_CAP_SECS  upper bound on an honoured rate-limit wait,
#                             default 5, clamped to 0..30. This clamp is what
#                             keeps the worst case bounded.
#   FM_NOTIFY_MAX_PARTS       maximum messages one oversized body is split into,
#                             default 4, clamped to 1..10. The last kept part is
#                             marked with an ellipsis.
#
# EVENT CLASSES (the caller passes one with --event; default "update"):
#   dispatched needs-decision blocked failed alarm pr-ready merged done update
# DEFAULT EVENT SET
#   Every class except "dispatched". AGENTS.md section 9 suppresses routine
#   progress in captain chat, so mirroring dispatches to the phone is an
#   explicit captain preference that FM_NOTIFY_EVENTS has to record.
#
# ROUTING
#   One table row per class carries its lane, its mention decision, and its
#   stripe colour together, so those three can never drift apart:
#
#     class            lane           mention  stripe
#     needs-decision   conversation   yes      red
#     blocked          conversation   yes      red
#     failed           conversation   yes      red
#     alarm            conversation   yes      red
#     pr-ready         broadcast      no       blue
#     merged           broadcast      no       green
#     done             broadcast      no       green
#     dispatched       broadcast      no       grey
#     update           broadcast      no       grey
#
#   Both Discord rooms are expected to be muted, where a mention is the only
#   thing that reaches the captain. Urgency therefore rides on the message rather
#   than on which room it landed in, which is why exactly the four classes above
#   ever carry a mention, and why only their opening part carries it. Every
#   message suppresses mention parsing in the payload itself, so @everyone,
#   @here, or role text inside a body can never ping anyone.
#
# DEGRADING BACK TO ONE ADDRESS
#   With no FM_NOTIFY_LOG_TARGET the broadcast lane simply uses FM_NOTIFY_TARGET.
#   If a configured broadcast address is rejected (403/404 - the channel or its
#   webhook was deleted), the message falls back to FM_NOTIFY_TARGET once and
#   says so on stderr, so removing the second channel degrades to single-address
#   delivery instead of losing the message.
#   A broadcast address that is misconfigured rather than deleted is refused with
#   exit 3 instead of being guessed around, but only for the broadcast classes:
#   the four interrupt classes never read it, so they still send.
#
# PRESENTATION
#   One embed per message: an emoji and an uppercase word in the title, plus the
#   matching colour. Colour NEVER stands alone - the emoji and the word carry
#   the same state for colourblind readers and for notification previews that
#   drop the colour bar. Caps are enforced before sending rather than letting
#   the API reject the message. Body text is split on line and word boundaries,
#   so a full https:// URL is never broken across parts; only a single token
#   longer than the whole per-part budget is ever hard-split.
#
# CHANNEL SEAM
#   Everything above is platform-agnostic. A channel is exactly three functions
#   plus one resolver arm:
#     fm_notify_limits_<channel>    "<title cap> <body cap> <message cap>"
#     fm_notify_payload_<channel>   build one wire payload on stdout
#     fm_notify_deliver_<channel>   post one payload file, returning an exit
#                                   code from the shared set below
#   Only discord-webhook is implemented. Adding a second channel is additive:
#   no change to the caller contract, the config surface, or the shaping logic.
#
# FAILURE CONTRACT
#   Losing a notification must never block or delay fleet work. Every failure
#   path is quiet, bounded, and non-blocking: a short single-line diagnostic on
#   stderr, a distinguishing exit code, no retry loop beyond the single
#   rate-limit retry, no daemon, and no write anywhere under the fleet's state.
#
# EXIT CODES
#   0  delivered, or inert (no target configured), or the class is filtered out
#   2  usage error (bad flag, unknown event class, missing or empty message,
#      bad --url)
#   3  misconfiguration (unrecognised target form, or curl/jq missing)
#   4  delivery failed (transport error, or an unexpected HTTP status)
#   5  the target rejected us (403/404) - the webhook is gone or revoked
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-notify.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# fmx_env_get is this repo's single reader for .env-style files; fm-bootstrap.sh
# and fm-public-followup-lib.sh already reuse it outside X mode's own clients.
# Sourcing only defines functions, so no X-mode behaviour is activated here.
# shellcheck source=bin/fm-x-lib.sh
. "$SELF_DIR/fm-x-lib.sh"

# Discord rejects a request with no User-Agent at the edge, before it ever
# reaches the webhook, so this header is required rather than decorative.
FM_NOTIFY_UA="firstmate-notify/1.0 (+https://github.com/Lcxiv/firstmate)"

warn() {
  printf 'fm-notify: %s\n' "$*" >&2
}

print_header() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SELF"
}

# --- event classes, routing, and presentation --------------------------------
#
# The four stripe colours, and nothing else. Each one means one thing across
# both lanes: red needs the captain, blue is ready for review, green landed,
# grey is routine. A colour is deliberately never the only carrier of the state.
FM_NOTIFY_RED=$((0xF23F43))
FM_NOTIFY_BLUE=$((0x5865F2))
FM_NOTIFY_GREEN=$((0x23A55A))
FM_NOTIFY_GREY=$((0x80848E))

# One tab-separated row per class: emoji, word, colour, lane, mention. Keeping
# all five in a single row is what stops the lane, the mention, and the colour
# from drifting apart as classes are added. See ROUTING in the header.
fm_notify_state_row() {
  case "$1" in
    dispatched)     printf '%s\t%s\t%s\t%s\t%s\n' '🚢' 'DISPATCHED'     "$FM_NOTIFY_GREY"  broadcast    0 ;;
    update)         printf '%s\t%s\t%s\t%s\t%s\n' 'ℹ️' 'UPDATE'         "$FM_NOTIFY_GREY"  broadcast    0 ;;
    pr-ready)       printf '%s\t%s\t%s\t%s\t%s\n' '📋' 'PR READY'       "$FM_NOTIFY_BLUE"  broadcast    0 ;;
    merged)         printf '%s\t%s\t%s\t%s\t%s\n' '✅' 'MERGED'         "$FM_NOTIFY_GREEN" broadcast    0 ;;
    done)           printf '%s\t%s\t%s\t%s\t%s\n' '🟢' 'DONE'           "$FM_NOTIFY_GREEN" broadcast    0 ;;
    needs-decision) printf '%s\t%s\t%s\t%s\t%s\n' '🤔' 'NEEDS DECISION' "$FM_NOTIFY_RED"   conversation 1 ;;
    blocked)        printf '%s\t%s\t%s\t%s\t%s\n' '🔴' 'BLOCKED'        "$FM_NOTIFY_RED"   conversation 1 ;;
    failed)         printf '%s\t%s\t%s\t%s\t%s\n' '❌' 'FAILED'         "$FM_NOTIFY_RED"   conversation 1 ;;
    alarm)          printf '%s\t%s\t%s\t%s\t%s\n' '🚨' 'ALARM'          "$FM_NOTIFY_RED"   conversation 1 ;;
    *) return 1 ;;
  esac
}

fm_notify_list_events() {
  printf '%s\n' dispatched needs-decision blocked failed alarm pr-ready merged 'done' update
}

# Every class except dispatched; see DEFAULT EVENT SET in the header.
FM_NOTIFY_DEFAULT_EVENTS='needs-decision,blocked,failed,alarm,pr-ready,merged,done,update'

# --- config resolution ------------------------------------------------------

# fm_notify_config_get <KEY>: an explicitly set environment variable wins,
# otherwise the home's .env. Empty output means unset.
fm_notify_config_get() {
  local key=$1 env_file
  env_file="${FM_NOTIFY_ENV_FILE:-$FM_HOME/.env}"
  if [ -n "${!key+x}" ]; then
    printf '%s' "${!key-}"
    return 0
  fi
  fmx_env_get "$key" "$env_file"
}

# fm_notify_bounded <raw> <default> <min> <max>: print a clamped integer,
# falling back to <default> for anything non-numeric.
fm_notify_bounded() {
  local raw=$1 fallback=$2 lo=$3 hi=$4
  case "$raw" in
    ''|*[!0-9]*) raw=$fallback ;;
  esac
  [ "${#raw}" -le 9 ] || raw=$fallback
  [ "$raw" -ge "$lo" ] || raw=$lo
  [ "$raw" -le "$hi" ] || raw=$hi
  printf '%s' "$raw"
}

# fm_notify_event_enabled <class> <filter>: is this class mirrored? An empty
# filter means the default set.
fm_notify_event_enabled() {
  local class=$1 filter=$2 norm
  norm=$(printf '%s' "$filter" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [ -n "$norm" ] || norm=$FM_NOTIFY_DEFAULT_EVENTS
  case "$norm" in
    all) return 0 ;;
    none) return 1 ;;
  esac
  case ",$norm," in
    *",$class,"*) return 0 ;;
  esac
  return 1
}

# fm_notify_resolve_target <raw>: print "<channel>\t<address>".
# Returns 1 when no target is configured (inert) and 3 when a value is set but
# names no channel this build implements.
fm_notify_resolve_target() {
  local raw=$1
  [ -n "$raw" ] || return 1
  case "$raw" in
    discord-webhook:*)
      printf '%s\t%s\n' discord-webhook "${raw#discord-webhook:}"
      return 0
      ;;
  esac
  # A bare webhook URL is accepted as a convenience, so the captain can paste
  # exactly what Discord's "Copy Webhook URL" button gives them.
  case "$raw" in
    https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*|https://*.discord.com/api/webhooks/*)
      printf '%s\t%s\n' discord-webhook "$raw"
      return 0
      ;;
  esac
  return 3
}

# fm_notify_fn_suffix <channel>: the function-name suffix for a channel name.
fm_notify_fn_suffix() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_'
}

# fm_notify_mention_id: print the captain's Discord user id, or return 1 when no
# usable id is configured. FM_PHONE_CAPTAIN_ID is accepted as a fallback so a
# home that already runs the inbound phone channel does not configure the same
# id twice. A malformed value is treated as absent: a mention that cannot be
# addressed must degrade to an ordinary delivered message, never to a lost one.
fm_notify_mention_id() {
  local id
  id=$(fm_notify_config_get FM_NOTIFY_MENTION_ID)
  [ -n "$id" ] || id=$(fm_notify_config_get FM_PHONE_CAPTAIN_ID)
  case "$id" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#id}" -ge 15 ] && [ "${#id}" -le 21 ] || return 1
  printf '%s' "$id"
}

# --- text shaping (platform-agnostic) ---------------------------------------

# fm_notify_truncate <cap>: trim stdin to <cap> codepoints on a word boundary,
# appending an ellipsis when anything was dropped.
fm_notify_truncate() {
  jq -Rsj --argjson cap "$1" '
    def ellipsize($c):
      if ($c <= 1) then .[0:$c]
      elif (length <= $c - 1) then . + "…"
      else (((.[0:($c - 1)] | sub("[^[:space:]]*$"; "") | sub("[[:space:]]+$"; ""))) as $cut
            | (if ($cut | length) == 0 then .[0:($c - 1)] else $cut end) + "…")
      end;
    if (length <= $cap) then . else ellipsize($cap) end
  '
}

# fm_notify_split_body <budget> <max-parts>: read the body on stdin and print a
# compact JSON array of parts, each at most <budget> codepoints.
#
# Line structure is preserved: parts are packed out of whole lines, so a list
# stays a list. Only a line longer than the budget is word-wrapped, and only a
# single token longer than the budget is hard-split - which is why a full
# https:// URL always survives intact. Past <max-parts> the rest of the body is
# dropped and the last kept part is marked with an ellipsis.
#
# This deliberately does not reuse fmx_split_thread: that splitter reflows
# consecutive lines into paragraphs, which would collapse a captain-facing list
# into one run-on line.
fm_notify_split_body() {
  jq -Rsc --argjson budget "$1" --argjson cap "$2" '
    def hardsplit($b): . as $s | [range(0; ($s | length); $b) as $i | $s[$i:$i + $b]];
    def wrap_line($b):
      if (length <= $b) then [.]
      else
        ([split(" ")[] | select(length > 0) | if (length > $b) then hardsplit($b)[] else . end]) as $words
        | (reduce $words[] as $w ({lines: [], cur: ""};
            (if .cur == "" then $w else .cur + " " + $w end) as $cand
            | if ($cand | length) <= $b then .cur = $cand
              else .lines += (if .cur == "" then [] else [.cur] end) | .cur = $w end
          )) as $st
        | ($st.lines + (if $st.cur != "" then [$st.cur] else [] end))
        | if (length == 0) then [""] else . end
      end;
    def pack($units; $b):
      (reduce $units[] as $u ({parts: [], cur: ""};
        (if .cur == "" then $u else .cur + "\n" + $u end) as $cand
        | if ($cand | length) <= $b then .cur = $cand
          else .parts += (if .cur == "" then [] else [.cur] end) | .cur = $u end
      )) as $st
      | $st.parts + (if $st.cur != "" then [$st.cur] else [] end);
    def ellipsize($b):
      if ($b <= 1) then .[0:$b]
      elif (length <= $b - 1) then . + "…"
      else (((.[0:($b - 1)] | sub("[^[:space:]]*$"; "") | sub("[[:space:]]+$"; ""))) as $cut
            | (if ($cut | length) == 0 then .[0:($b - 1)] else $cut end) + "…")
      end;
    sub("[[:space:]]+$"; "")
    | if (length == 0) then []
      else
        ([split("\n")[] | sub("[[:space:]]+$"; "") | wrap_line($budget)[]]) as $units
        | pack($units; $budget) as $raw
        | if (($raw | length) > $cap)
          then ($raw[0:$cap] | (.[$cap - 1] |= ellipsize($budget)))
          else $raw end
      end
  '
}

# --- shared transport helper ------------------------------------------------

# fm_notify_stage_curl_target <address>: write <address> into a fresh 0600 curl
# config file and print its path. The address is a write capability that lives
# only in the home's gitignored .env, so it is handed to curl through a file
# rather than through argv, where the process table would expose it to every
# local user. This mirrors fmx_auth_header_file in bin/fm-x-lib.sh.
# shellcheck disable=SC2329 # Reached only from a channel-seam deliver function.
fm_notify_stage_curl_target() {
  local address=$1 file escaped
  case "$address" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  escaped=${address//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-notify-target.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'url = "%s"\n' "$escaped" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# --- channel: discord-webhook -----------------------------------------------
#
# The three functions below are reached by name through the channel seam, which
# ShellCheck cannot follow.

# "<title cap> <body cap> <message cap>" - Discord's documented embed limits.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_limits_discord_webhook() {
  printf '%s %s %s\n' 256 4096 6000
}

# fm_notify_payload_discord_webhook <emoji> <word> <colour> <title> <body> [url]
#                                   [mention-id]
# Pure builder: no network and no IO beyond stdout.
#
# allowed_mentions is present on EVERY payload with an empty parse list, so the
# only ping this script can ever produce is the explicitly addressed captain id
# on a mention class. Nothing written inside a title or body - @everyone, @here,
# or a role - can add one.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_payload_discord_webhook() {
  local emoji=$1 word=$2 colour=$3 title=$4 body=$5 url=${6:-} mention=${7:-}
  jq -cn \
    --arg title "$emoji $word${title:+ · $title}" \
    --arg body "$body" \
    --argjson colour "$colour" \
    --arg url "$url" \
    --arg mention "$mention" \
    '{embeds: [
       ({title: $title, description: $body, color: $colour}
        + (if ($url | length) > 0 then {url: $url} else {} end))
     ]}
     + (if ($mention | length) > 0
        then {content: "<@\($mention)>", allowed_mentions: {parse: [], users: [$mention]}}
        else {allowed_mentions: {parse: []}}
        end)'
}

# fm_notify_deliver_discord_webhook <address> <payload-file>
# One POST, plus one retry on 429 honouring a clamped retry_after. Bounded by
# construction: at most two requests, each with a hard transport timeout, plus
# at most FM_NOTIFY_RETRY_CAP seconds of waiting.
#
# The body runs in a subshell so its own scratch files are cleaned by traps that
# cover the signal paths too, without disturbing the caller's traps.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_deliver_discord_webhook() (
  local address=$1 payload_file=$2
  local body_file='' target_file='' code rc delay attempt=0

  trap 'rm -f "$body_file" "$target_file"' EXIT
  trap 'rm -f "$body_file" "$target_file"; exit 143' HUP INT TERM

  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-notify-body.XXXXXX") || {
    warn "cannot create a temporary response file"
    return 4
  }
  target_file=$(fm_notify_stage_curl_target "$address") || {
    warn "cannot stage the delivery target"
    return 4
  }

  while :; do
    code=$(curl -s -m "$FM_NOTIFY_TIMEOUT" --connect-timeout "$FM_NOTIFY_TIMEOUT" \
      -o "$body_file" -w '%{http_code}' \
      -X POST \
      -H 'Content-Type: application/json' \
      -H "User-Agent: $FM_NOTIFY_UA" \
      --data-binary "@$payload_file" \
      --config "$target_file" 2>/dev/null)
    rc=$?
    if [ "$rc" != 0 ]; then
      warn "delivery failed: transport error"
      return 4
    fi

    case "$code" in
      2[0-9][0-9])
        return 0
        ;;
      403|404)
        warn "target rejected the message (HTTP $code); the webhook may be deleted or revoked"
        return 5
        ;;
      429)
        if [ "$attempt" -ge 1 ]; then
          warn "delivery failed: still rate limited after one retry"
          return 4
        fi
        delay=$(jq -r '
          (.retry_after // 1)
          | if type == "number" then tostring
            elif (type == "string" and test("^[0-9]+([.][0-9]+)?$")) then .
            else "1" end
        ' "$body_file" 2>/dev/null) || delay=1
        case "$delay" in
          ''|*[!0-9.]*) delay=1 ;;
        esac
        # This clamp is why a hostile or buggy retry_after can never hang a
        # firstmate turn.
        delay=$(awk -v w="$delay" -v cap="$FM_NOTIFY_RETRY_CAP" \
          'BEGIN { w = w + 0; if (w < 0) w = 0; if (w > cap) w = cap; printf "%.3f", w }')
        sleep "$delay"
        attempt=$((attempt + 1))
        ;;
      *)
        warn "delivery failed: HTTP $code"
        return 4
        ;;
    esac
  done
)

# --- argument parsing -------------------------------------------------------

EVENT=update
TITLE=
LINK=
ARGTEXT=
HAVE_ARGS=0
ONLY_POSITIONAL=0

add_arg() {
  if [ "$HAVE_ARGS" = 0 ]; then
    ARGTEXT=$1
    HAVE_ARGS=1
  else
    ARGTEXT="$ARGTEXT $1"
  fi
}

while [ "$#" -gt 0 ]; do
  if [ "$ONLY_POSITIONAL" = 1 ]; then
    add_arg "$1"
    shift
    continue
  fi
  case "$1" in
    -h|--help) print_header; exit 0 ;;
    --list-events) fm_notify_list_events; exit 0 ;;
    --event)
      [ "$#" -ge 2 ] || { warn "--event needs a value"; exit 2; }
      EVENT=$2; shift 2 ;;
    --event=*) EVENT=${1#--event=}; shift ;;
    --title)
      [ "$#" -ge 2 ] || { warn "--title needs a value"; exit 2; }
      TITLE=$2; shift 2 ;;
    --title=*) TITLE=${1#--title=}; shift ;;
    --url)
      [ "$#" -ge 2 ] || { warn "--url needs a value"; exit 2; }
      LINK=$2; shift 2 ;;
    --url=*) LINK=${1#--url=}; shift ;;
    --) ONLY_POSITIONAL=1; shift ;;
    -*) warn "unknown option: $1"; exit 2 ;;
    *) add_arg "$1"; shift ;;
  esac
done

STATE_ROW=$(fm_notify_state_row "$EVENT") || {
  warn "unknown event class: $EVENT (see --list-events)"
  exit 2
}

if [ -n "$LINK" ]; then
  case "$LINK" in
    http://*|https://*) ;;
    *) warn "--url must be an http:// or https:// URL"; exit 2 ;;
  esac
fi

if [ "$HAVE_ARGS" = 1 ]; then
  MESSAGE=$ARGTEXT
elif [ -t 0 ]; then
  # Reading stdin here would wait for an EOF an interactive caller never sends,
  # so a call that names a class but forgets the text is a usage error instead.
  warn "no message given; pass the text as arguments or pipe it on stdin"
  exit 2
else
  MESSAGE=$(cat)
fi
case "$(printf '%s' "$MESSAGE" | tr -d '[:space:]')" in
  '') warn "empty message; nothing to send"; exit 2 ;;
esac

# --- inertness gate ---------------------------------------------------------
#
# Past this point a home that never opted in does nothing at all.

TARGET_RAW=$(fm_notify_config_get FM_NOTIFY_TARGET)
RESOLVED=$(fm_notify_resolve_target "$TARGET_RAW")
RESOLVE_RC=$?
case "$RESOLVE_RC" in
  0) ;;
  1) exit 0 ;;
  *) warn "FM_NOTIFY_TARGET names no supported channel"; exit 3 ;;
esac
IFS=$'\t' read -r CHANNEL ADDRESS <<< "$RESOLVED"

if ! fm_notify_event_enabled "$EVENT" "$(fm_notify_config_get FM_NOTIFY_EVENTS)"; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || { warn "jq not found"; exit 3; }
command -v curl >/dev/null 2>&1 || { warn "curl not found"; exit 3; }

FM_NOTIFY_TIMEOUT=$(fm_notify_bounded "$(fm_notify_config_get FM_NOTIFY_TIMEOUT_SECS)" 10 1 120)
FM_NOTIFY_RETRY_CAP=$(fm_notify_bounded "$(fm_notify_config_get FM_NOTIFY_RETRY_CAP_SECS)" 5 0 30)
MAX_PARTS=$(fm_notify_bounded "$(fm_notify_config_get FM_NOTIFY_MAX_PARTS)" 4 1 10)

IFS=$'\t' read -r EMOJI WORD COLOUR LANE MENTION <<< "$STATE_ROW"

# Select the lane's address, and remember whether there is a distinct address to
# fall back to if the broadcast one has been deleted. The broadcast lane
# defaults to the conversation address, so a home that never configures a second
# one behaves exactly as it did before this lane existed.
#
# The optional broadcast address is resolved ONLY for a message that would
# actually use it. This scoping is deliberate and must not be "simplified" back
# into one uniform refusal: on 2026-08-02 an alarm existed and could not reach
# the captain for nineteen hours, and a safety net must not share a failure mode
# with the thing it exists to catch. The four interrupt classes never touch this
# address, so a typo in it must never silence them. It is not a fail-open: a
# broadcast message still refuses its own misconfiguration loudly below.
ACTIVE_ADDRESS=$ADDRESS
FALLBACK_ADDRESS=
if [ "$LANE" = broadcast ]; then
  LOG_RAW=$(fm_notify_config_get FM_NOTIFY_LOG_TARGET)
  if [ -n "$LOG_RAW" ]; then
    LOG_RESOLVED=$(fm_notify_resolve_target "$LOG_RAW")
    LOG_RESOLVE_RC=$?
    if [ "$LOG_RESOLVE_RC" != 0 ]; then
      warn "FM_NOTIFY_LOG_TARGET names no supported channel"
      exit 3
    fi
    IFS=$'\t' read -r LOG_CHANNEL LOG_ADDRESS <<< "$LOG_RESOLVED"
    # Both lanes share one set of caps and one payload shape, so a mismatch is
    # refused rather than silently shaping a message for the wrong one.
    if [ "$LOG_CHANNEL" != "$CHANNEL" ]; then
      warn "FM_NOTIFY_LOG_TARGET must use the same channel as FM_NOTIFY_TARGET"
      exit 3
    fi
    ACTIVE_ADDRESS=$LOG_ADDRESS
    [ "$LOG_ADDRESS" = "$ADDRESS" ] || FALLBACK_ADDRESS=$ADDRESS
  fi
fi

# Resolve the mention once. A mention class with no configured id still sends;
# it simply lands without an interrupt rather than not landing at all.
MENTION_ID=
if [ "$MENTION" = 1 ]; then
  MENTION_ID=$(fm_notify_mention_id) || MENTION_ID=
fi

SUFFIX=$(fm_notify_fn_suffix "$CHANNEL")
read -r TITLE_CAP BODY_CAP MESSAGE_CAP < <("fm_notify_limits_$SUFFIX")

# The part marker lives in the title, so the body the captain reads is never
# interrupted by bookkeeping. Reserve room for the widest marker up front, plus
# the " · " separator.
MARKER_RESERVE=$(( 6 + 2 * ${#MAX_PARTS} ))
TITLE_BUDGET=$(( TITLE_CAP - ${#EMOJI} - ${#WORD} - MARKER_RESERVE - 4 ))
[ "$TITLE_BUDGET" -ge 1 ] || TITLE_BUDGET=1
if [ -n "$TITLE" ]; then
  TITLE=$(printf '%s' "$TITLE" | fm_notify_truncate "$TITLE_BUDGET")
fi

# Honour the message-wide cap too, not just the description cap: on Discord the
# title, the marker, and the mention content all count against the same
# per-message budget.
MENTION_COST=0
[ -z "$MENTION_ID" ] || MENTION_COST=$(( ${#MENTION_ID} + 4 ))
TITLE_COST=$(( ${#EMOJI} + ${#WORD} + ${#TITLE} + MARKER_RESERVE + MENTION_COST + 4 ))
BODY_BUDGET=$(( MESSAGE_CAP - TITLE_COST ))
[ "$BODY_BUDGET" -le "$BODY_CAP" ] || BODY_BUDGET=$BODY_CAP
[ "$BODY_BUDGET" -ge 16 ] || BODY_BUDGET=16

PARTS=$(printf '%s' "$MESSAGE" | fm_notify_split_body "$BODY_BUDGET" "$MAX_PARTS") || {
  warn "cannot shape the message body"
  exit 4
}
COUNT=$(printf '%s' "$PARTS" | jq 'length') || COUNT=0
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac
[ "$COUNT" -gt 0 ] || { warn "empty message; nothing to send"; exit 2; }

PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-notify-payload.XXXXXX") || {
  warn "cannot create a temporary payload file"
  exit 4
}
trap 'rm -f "$PAYLOAD_FILE"' EXIT
trap 'rm -f "$PAYLOAD_FILE"; exit 143' HUP INT TERM

# deliver_part: send the staged payload to the lane's address, falling back to
# the conversation address exactly once if the broadcast one has been deleted.
# The fallback latches, so a split message does not re-try the dead address for
# every remaining part.
deliver_part() {
  local rc
  "fm_notify_deliver_$SUFFIX" "$ACTIVE_ADDRESS" "$PAYLOAD_FILE"
  rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 5 ] && [ -n "$FALLBACK_ADDRESS" ]; then
    warn "the broadcast address is gone; delivering to the main address instead"
    ACTIVE_ADDRESS=$FALLBACK_ADDRESS
    FALLBACK_ADDRESS=
    "fm_notify_deliver_$SUFFIX" "$ACTIVE_ADDRESS" "$PAYLOAD_FILE"
    return $?
  fi
  return "$rc"
}

i=0
while [ "$i" -lt "$COUNT" ]; do
  BODY=$(printf '%s' "$PARTS" | jq -r --argjson i "$i" '.[$i]')
  PART_TITLE=$TITLE
  if [ "$COUNT" -gt 1 ]; then
    PART_TITLE="${TITLE:+$TITLE }($((i + 1))/$COUNT)"
  fi
  # Only the opening part carries the link and the mention, so a split message
  # neither repeats the same title link on every card nor interrupts the captain
  # once per part.
  PART_LINK=
  PART_MENTION=
  if [ "$i" = 0 ]; then
    PART_LINK=$LINK
    PART_MENTION=$MENTION_ID
  fi
  if ! "fm_notify_payload_$SUFFIX" "$EMOJI" "$WORD" "$COLOUR" "$PART_TITLE" "$BODY" \
    "$PART_LINK" "$PART_MENTION" > "$PAYLOAD_FILE"; then
    warn "cannot build the message payload"
    exit 4
  fi
  deliver_part || exit $?
  i=$((i + 1))
done

exit 0

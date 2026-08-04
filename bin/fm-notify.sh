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
#                             silent no-op. This is the conversation lane. See
#                             CHANNELS below for the forms each channel accepts.
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
#   FM_NOTIFY_HERMES_BIN      path to the hermes executable for the hermes
#                             channel, default "hermes" resolved on PATH. A
#                             hook or service PATH differs from an interactive
#                             shell's, so this override is how a non-interactive
#                             caller names the binary.
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
#   Every channel shows an emoji and an uppercase word for the state. Colour,
#   where a channel has one, NEVER stands alone - the emoji and the word carry
#   the same state for colourblind readers and for notification previews that
#   drop the colour bar. Caps are enforced before sending rather than letting
#   the API reject the message. Body text is split on line and word boundaries,
#   so a full https:// URL is never broken across parts; only a single token
#   longer than the whole per-part budget is ever hard-split.
#
#   The caller's text is sent verbatim apart from that cap-driven splitting.
#   The state marker, the caller's own --title, the part marker, the --url, and
#   the reply-route note below are sanctioned presentation metadata that a
#   channel places around the body; nothing is ever added inside it.
#
# CHANNELS
#   discord-webhook  one embed per message.
#                    Target: "discord-webhook:<webhook url>", or a bare Discord
#                    webhook URL. Needs curl.
#   hermes           plain text through the `hermes send` CLI, which reuses
#                    Hermes' own configured platform credentials. Outbound
#                    ONLY: firstmate never reads that platform, so actionable
#                    classes carry a reply-route note naming where an answer
#                    has to go.
#                    Target: "hermes:<hermes target>", passed to `hermes send
#                    --to` unchanged. Verified against Telegram only; describe
#                    it as supporting targets whose plain-text behaviour has
#                    actually been tested, not every platform Hermes speaks.
#                    PREFER AN EXPLICIT TARGET, "hermes:telegram:<chat id>". A
#                    bare "hermes:telegram" follows whatever Hermes currently
#                    calls its home channel, so an operator's unrelated Hermes
#                    change can silently move firstmate's alerts to a different
#                    conversation - delivered, but to the wrong reader. The bare
#                    form still works and warns once per delivered message.
#                    Wire format, exactly:
#                      <emoji> <WORD>[ · <title>][ (i/n)]
#                      <blank>
#                      <body>
#                      [<blank> <url>]              first part only
#                      [<blank> <reply-route note>] actionable classes, every
#                                                   part, so a captain who sees
#                                                   only one part still has the
#                                                   route
#                    No `--subject` is sent: all presentation lives in the body,
#                    so this script controls the whole plain-text composition it
#                    hands over. The reader does NOT necessarily see those
#                    bytes verbatim: the sender applies its own platform
#                    formatting (markdown rewritten to MarkdownV2, or HTML when
#                    the body matches its HTML autodetect) and re-chunks the
#                    FORMATTED text on UTF-16 units. The header, url, and note
#                    bytes are still reserved out of the body budget before the
#                    shared splitter runs, so this script never composes an
#                    over-cap part; the sender's own split boundary is the
#                    formatted UTF-16 length rather than this codepoint budget.
#
# CHANNEL SEAM
#   Everything above the channel functions is platform-agnostic. A channel is
#   exactly five functions plus one resolver arm:
#     fm_notify_limits_<channel>    "<title cap> <body cap> <message cap>"
#     fm_notify_validate_<channel>  <address>; called once, after the event
#                                   filter, to check this channel's own
#                                   dependencies and target form. May warn;
#                                   return 3 to refuse as misconfiguration
#     fm_notify_reserve_<channel>   <title> <url> <class>; codepoints this
#                                   channel's decoration adds around each part,
#                                   reserved out of the body budget. 0 when the
#                                   channel carries decoration outside the body
#     fm_notify_payload_<channel>   <emoji> <word> <colour> <title> <body>
#                                   <url> <mention-id> <class>; build one wire
#                                   payload on stdout
#     fm_notify_deliver_<channel>   post one payload file, returning an exit
#                                   code from the shared set below
#   Adding a further channel is additive: no change to the caller contract, the
#   config surface, or the shaping logic.
#
# FAILURE CONTRACT
#   Losing a notification must never block or delay fleet work. Every failure
#   path is quiet, bounded, and non-blocking: a short single-line diagnostic on
#   stderr, a distinguishing exit code, no retry loop beyond the single
#   rate-limit retry, no daemon, and no write anywhere under the fleet's state.
#   A channel that shells out to an external sender bounds that process itself,
#   so a sender that hangs on config, credentials, transport retry, or a broken
#   provider costs one notification rather than stalling the caller.
#
#   No credential, target address, chat id, or raw output from an external
#   sender ever reaches this script's own stdout or stderr. A channel captures
#   that output and reports a generic firstmate diagnostic instead.
#
# EXIT CODES
#   0  delivered, or inert (no target configured), or the class is filtered out
#   2  usage error (bad flag, unknown event class, missing or empty message,
#      bad --url)
#   3  misconfiguration (unrecognised target form, jq missing, or a channel's
#      own dependency or target form is unusable)
#   4  delivery failed (transport error, or an unexpected HTTP status)
#   5  the target rejected us (403/404) - the webhook is gone or revoked
#
#   The hermes channel maps `hermes send`'s own 0/1/2 deliberately rather than
#   passing it through, and never reads HTTP-like meaning into it:
#     hermes 0            -> 0  delivered
#     hermes 1            -> 4  delivery or backend error
#     hermes 2            -> 3  the sender rejected our invocation, which means
#                               the configured target form is wrong
#     hit the time bound  -> 4  bounded delivery failure
#     killed by a signal  -> 4  delivery failure; the sender reports this as
#                               128 plus the signal, so a signal death can never
#                               be mistaken for a clean exit 0
#     any other code      -> 4  delivery failure
#     binary missing      -> 3  misconfiguration, reported before any delivery
#     no way to bound the -> 3  misconfiguration; this host has no timeout,
#     sender                    gtimeout, or perl, so the sender was never
#                               launched and nothing hung
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

# The classes that ask the captain for something. On an outbound-only channel
# these have to name where an answer goes, so an alert never arrives with no
# route to act on it. This is presentation only: no channel here ever reads.
FM_NOTIFY_ACTIONABLE_EVENTS='needs-decision,blocked,failed'
FM_NOTIFY_REPLY_NOTE='Outbound only - this channel is not read. Reply where you normally reach firstmate.'

# fm_notify_event_actionable <class>
# shellcheck disable=SC2329 # Reached only from channel-seam functions.
fm_notify_event_actionable() {
  case ",$FM_NOTIFY_ACTIONABLE_EVENTS," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

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
    hermes:*)
      printf '%s\t%s\n' hermes "${raw#hermes:}"
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

# --- shared transport helpers -----------------------------------------------

# fm_notify_run_timed <seconds> <command...>: run a command under a hard time
# bound, returning 124 when the bound was hit and 125 when this host offers no
# bounding mechanism at all, in which case nothing was ever launched. This
# mirrors the selection in bin/fm-auth-preflight.sh and bin/fm-fleet-snapshot.sh:
# macOS ships no GNU `timeout`, so the perl arm is the one that actually runs on
# the captain's host, and a host with none of the three refuses rather than
# running unbounded.
#
# The perl arm reports a signal-killed child the way GNU `timeout` does, as
# 128 plus the signal number. A raw `$? >> 8` would be 0 for a child that died
# from SIGKILL or SIGSEGV, and a caller mapping that status straight to delivery
# success would then claim a notification it never sent.
# shellcheck disable=SC2329 # Reached only from a channel-seam deliver function.
fm_notify_run_timed() {
  local seconds=$1
  shift
  if [ "${FM_NOTIFY_FORCE_TIMEOUT_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif [ "${FM_NOTIFY_FORCE_TIMEOUT_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # single quotes are deliberate: perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' \
      "$seconds" "$@"
  else
    return 125
  fi
}

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

# fm_notify_validate_discord_webhook <address>
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_validate_discord_webhook() {
  command -v curl >/dev/null 2>&1 || { warn "curl not found"; return 3; }
  return 0
}

# fm_notify_reserve_discord_webhook <title> <url> <class>
# The state marker, the part marker, the title, and the link all live outside
# the embed description, and the shared budget already accounts for the title,
# so this channel reserves nothing further from the body.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_reserve_discord_webhook() {
  printf '0\n'
}

# fm_notify_payload_discord_webhook <emoji> <word> <colour> <title> <body> [url]
#                                   [mention-id] [class]
# Pure builder: no network and no IO beyond stdout. The class is part of the
# seam for channels that decorate the body with it; an embed does not.
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

# --- channel: hermes --------------------------------------------------------
#
# `hermes send` is a plain sender: it reuses Hermes' own configured platform
# credentials and needs no agent, model, or running gateway for bot-token
# platforms. firstmate treats it strictly as an external dependency with a
# contract - a bounded process, a fixed argument shape, a mapped exit code, and
# no output of its own reaching firstmate's diagnostics.

# The resolved sender path, set by fm_notify_validate_hermes before delivery.
FM_NOTIFY_HERMES_BIN_RESOLVED=

# Telegram's message limit is 4096, and this is the target the plain-text
# contract has been verified against. The title cap bounds the header line, and
# the message cap is the whole-message budget the shared shaper splits against.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_limits_hermes() {
  printf '%s %s %s\n' 128 4096 4096
}

# fm_notify_validate_hermes <address>
# Resolves the sender once and checks the target form. A missing or
# non-executable sender is a reported misconfiguration, never a crash or a hang.
# The address is whichever of FM_NOTIFY_TARGET and FM_NOTIFY_LOG_TARGET this
# message's lane selected, so these diagnostics name the target rather than a
# key that may not be the one at fault.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_validate_hermes() {
  local address=$1 configured resolved
  if [ -z "$address" ]; then
    warn "the configured target names the hermes channel with no target"
    return 3
  fi
  case "$address" in
    *[[:space:]]*)
      warn "the hermes target contains whitespace; expected hermes:<platform>[:<id>]"
      return 3
      ;;
    -*)
      warn "the hermes target may not start with a dash"
      return 3
      ;;
  esac
  configured=$(fm_notify_config_get FM_NOTIFY_HERMES_BIN)
  [ -n "$configured" ] || configured=hermes
  resolved=$(command -v "$configured" 2>/dev/null) || resolved=
  if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
    warn "the message sender is not available; install it or set FM_NOTIFY_HERMES_BIN"
    return 3
  fi
  FM_NOTIFY_HERMES_BIN_RESOLVED=$resolved
  case "$address" in
    *:*) ;;
    *)
      # A bare platform follows the sender's own mutable home channel, so the
      # captain's alerts can move without firstmate noticing. Delivered to the
      # wrong reader is worse than not delivered, so this is never silent.
      warn "the hermes target names a bare platform, so alerts follow the sender's home channel; pin it with hermes:<platform>:<id>"
      ;;
  esac
  return 0
}

# fm_notify_reserve_hermes <title> <url> <class>
# The header line, the link, and the reply-route note all live inside the body
# this channel sends, so their bytes are reserved out of the body budget before
# the shared splitter runs. The header itself is already reserved by the shared
# title budget; what is counted here is the separators and the trailing blocks.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_reserve_hermes() {
  local url=$2 class=$3 reserve=2
  [ -z "$url" ] || reserve=$(( reserve + 2 + ${#url} ))
  if fm_notify_event_actionable "$class"; then
    reserve=$(( reserve + 2 + ${#FM_NOTIFY_REPLY_NOTE} ))
  fi
  printf '%s\n' "$reserve"
}

# fm_notify_payload_hermes <emoji> <word> <colour> <title> <body> [url]
#                          [mention-id] [class]
# Pure builder: the exact plain text handed to the sender. No subject line is
# used, so this script controls the whole composition it hands over; the sender
# then applies its own platform formatting and its own re-chunking of that
# formatted text, so these are the bytes given to it rather than the bytes the
# reader is guaranteed to see. The mention id is Discord's own addressing and
# has no meaning here, so this channel ignores it: an actionable class carries
# the reply-route note instead.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_payload_hermes() {
  local emoji=$1 word=$2 title=$4 body=$5 url=${6:-} class=${8:-}
  printf '%s %s%s\n\n%s\n' "$emoji" "$word" "${title:+ · $title}" "$body"
  [ -z "$url" ] || printf '\n%s\n' "$url"
  if fm_notify_event_actionable "$class"; then
    printf '\n%s\n' "$FM_NOTIFY_REPLY_NOTE"
  fi
}

# fm_notify_deliver_hermes <address> <payload-file>
# One bounded sender run. The body goes through --file and never through argv,
# where the process table would expose captain-facing text to every local user.
# The target does reach argv: `hermes send` offers no non-argv target mechanism,
# so that exposure is a documented residual risk of this channel.
#
# --quiet plus a captured stream is what keeps the chat id out of firstmate's
# output: the sender's normal success line prints it. Nothing the sender writes
# is ever relayed; the diagnostics below are firstmate's own words.
# shellcheck disable=SC2329 # Invoked through the channel seam by name.
fm_notify_deliver_hermes() (
  local address=$1 payload_file=$2 sink='' rc

  trap 'rm -f "$sink"' EXIT
  trap 'rm -f "$sink"; exit 143' HUP INT TERM

  sink=$(mktemp "${TMPDIR:-/tmp}/fm-notify-sender.XXXXXX") || {
    warn "cannot create a temporary response file"
    return 4
  }

  fm_notify_run_timed "$FM_NOTIFY_TIMEOUT" \
    "$FM_NOTIFY_HERMES_BIN_RESOLVED" send \
    --to "$address" \
    --file "$payload_file" \
    --quiet \
    >"$sink" 2>&1 </dev/null
  rc=$?

  case "$rc" in
    0) return 0 ;;
    124)
      warn "delivery failed: the message sender did not finish within ${FM_NOTIFY_TIMEOUT}s"
      return 4
      ;;
    125)
      warn "this host has no timeout, gtimeout, or perl to bound the message sender, so nothing was sent"
      return 3
      ;;
    1)
      warn "delivery failed: the message sender reported a delivery or backend error"
      return 4
      ;;
    2)
      warn "the message sender refused the request; the configured target is one it does not accept"
      return 3
      ;;
    *)
      warn "delivery failed: the message sender exited $rc"
      return 4
      ;;
  esac
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

# The channel's own dependency and target check runs once, here: after the event
# filter, so a filtered-out class stays a silent no-op, and before any shaping,
# so an unusable channel never reaches delivery. It checks the address this
# message will actually use, which on a broadcast class is the lane's own
# address rather than the conversation one.
"fm_notify_validate_$SUFFIX" "$ACTIVE_ADDRESS" || exit $?

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
# Whatever the channel wraps around the body counts against the same per-message
# budget, so it is reserved before the splitter runs rather than discovered by
# the platform rejecting an over-long message.
CHANNEL_RESERVE=$("fm_notify_reserve_$SUFFIX" "$TITLE" "$LINK" "$EVENT")
case "$CHANNEL_RESERVE" in
  ''|*[!0-9]*) CHANNEL_RESERVE=0 ;;
esac
BODY_BUDGET=$(( MESSAGE_CAP - TITLE_COST - CHANNEL_RESERVE ))
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
    "$PART_LINK" "$PART_MENTION" "$EVENT" > "$PAYLOAD_FILE"; then
    warn "cannot build the message payload"
    exit 4
  fi
  deliver_part || exit $?
  i=$((i + 1))
done

exit 0

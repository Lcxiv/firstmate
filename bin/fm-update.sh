#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill, and the automatic path a merged
# firstmate PR triggers. Fast-forwards the running firstmate repo's default
# branch from origin, then fast-forwards every registered secondmate home. Local
# homes are treehouse worktrees or standalone clones; remote routes update their
# configured code root on that host and then fast-forward the persistent home to
# that root. FAST-FORWARD ONLY, exactly like fm-fleet-sync.sh: never force,
# never create a merge commit, never stash; advance a target only when it is a
# clean fast-forward, otherwise skip and report. A tracked-files fast-forward
# never touches the gitignored operational dirs (data/, state/, config/,
# projects/, .no-mistakes/), so a secondmate's in-flight work is never
# disrupted. Worktrees of this repo share one object store, so a single fetch
# refreshes them all; standalone-clone homes are fetched on their own.
# Secondmate homes are leased at a detached HEAD on the default branch, so a
# fast-forward there advances HEAD only and never touches any other worktree's
# checkout or the shared `main` branch. A home that is ITSELF a secondmate home
# (it carries the .fm-secondmate-home marker) is leased the same way, so its own
# repo target is fast-forwarded with the same detached-HEAD allowance rather
# than skipped for not being on a named default branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# Usage:
#   fm-update.sh                      manual /updatefirstmate run
#   fm-update.sh --after-merge <url>  merged-PR notification entry point
#   fm-update.sh --retry-after-merge  retry a deferred notification update
#   fm-update.sh [--help]
#
# MANUAL MODE (no arguments) does NOT re-read AGENTS.md or nudge secondmates
# itself - those are LLM / terminal actions the skill performs. The script's job
# is the safe git mechanics plus a parseable summary telling the caller what to
# do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# NOTIFICATION MODE (--after-merge <pr-url>) is the same guarded sweep reached
# without a person, so it owns the two steps the skill's reader would otherwise
# perform, and adds the one precondition a person supplies by choosing their
# moment:
#
#   1. IDENTITY. The merged PR must name THIS firstmate repo's own origin,
#      compared as a normalized host/project identity (bin/fm-pr-lib.sh's
#      fm_pr_remote_identity) so equivalent HTTPS and SSH spellings match. A
#      merge in any other project prints "after-merge: skipped" and touches
#      nothing: a project merge must never fast-forward a firstmate home.
#   2. QUIET. A person picks a moment when nothing is mid-flight; a notification
#      arrives whenever the forge says so. This mode therefore refuses to update
#      while a live worker is still building in a worktree of THIS repo (see
#      firstmate_work_in_flight for why that case, and only that case, blocks
#      it), prints "after-merge: deferred", and leaves the pending notification
#      in state/.auto-update-pending so --retry-after-merge can finish it once
#      that worker is gone. The record itself counts as supervision need
#      (bin/fm-supervision-lib.sh), so the watcher whose check sweep runs that
#      retry stays armed even after the home's last work has ended.
#      Deferring costs no network: both preconditions are
#      read from local state before any fetch. The same record is written
#      BEFORE the fetch on every attempt, so a run killed at its caller's time
#      bound (a fetch hanging on an unreachable origin) leaves the notification
#      behind for the retry instead of losing it.
#   3. It sends the reread nudge to each advanced live secondmate itself, since
#      no reader is there to send it, and prints reread-firstmate so its caller
#      can queue the running firstmate's own re-read.
#
# The sweep only ever moves DOWN the tree: this home and the secondmates it
# owns. A merge observed inside a secondmate home never fast-forwards that
# home's parent, because a secondmate must not mutate its parent's home; the
# parent learns of the merge through its own watcher or the child's charter
# reply channel. That asymmetry is deliberate, not a gap to close.
#
# A deferral is a normal reportable outcome, never a failure to work around, and
# nothing here relaxes any fast-forward-only guard for the automatic caller.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
PENDING="$STATE/.auto-update-pending"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() {
  echo "usage: fm-update.sh [--after-merge <pr-url> | --retry-after-merge | --help]" >&2
}

MODE=manual
MERGED_URL=

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --after-merge)
    [ $# -eq 2 ] || { usage; exit 1; }
    MODE="after-merge"
    MERGED_URL=$2
    ;;
  --retry-after-merge)
    [ $# -eq 1 ] || { usage; exit 1; }
    MODE="after-merge"
    ;;
  '') [ $# -eq 0 ] || { usage; exit 1; } ;;
  *) usage; exit 1 ;;
esac

# --- notification preconditions --------------------------------------------

# A pending record is the canonical merged PR URL on its first line and
# `attempts=<n>` on its second: how many times this home has started the sweep
# for that notification without completing it. It is written once the
# notification is confirmed to be this repo's own, before anything that could
# hang, and removed as soon as the notification is resolved either way, so it
# can never re-trigger an update the home has already taken. The attempt count
# is what lets the watcher tell one unlucky fetch from an update that keeps
# failing.
pending_read() {
  local line
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  IFS= read -r line < "$PENDING" || return 1
  printf '%s\n' "$line"
}

pending_attempts() {  # <url> -> attempts recorded for exactly that url, else 0
  local url line n=0
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || { echo 0; return 0; }
  { IFS= read -r url && IFS= read -r line; } < "$PENDING" || { echo 0; return 0; }
  [ "$url" = "$1" ] || { echo 0; return 0; }
  case "$line" in attempts=*) n=${line#attempts=} ;; esac
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}

pending_write() {  # <url> <attempts>
  local tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  [ ! -L "$PENDING" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.auto-update-pending.XXXXXX") || return 1
  printf '%s\nattempts=%s\n' "$1" "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$PENDING" || { rm -f -- "$tmp"; return 1; }
}

pending_clear() {
  [ ! -L "$PENDING" ] || return 0
  rm -f -- "$PENDING" 2>/dev/null || true
}

# This home's own repo identity, normalized the same way a PR URL is.
repo_identity() {
  local origin
  origin=$(git -C "$FM_ROOT" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$origin" ] || return 1
  fm_pr_remote_identity "$origin"
}

# Is this home itself leased as a secondmate home? Its repo target is then at a
# detached HEAD by design and gets the same allowance every secondmate home has.
home_is_leased_secondmate() {
  [ -f "$FM_ROOT/$SUB_HOME_MARKER" ] && [ ! -L "$FM_ROOT/$SUB_HOME_MARKER" ]
}

# The object store this firstmate repo's refs live in. Every worktree of this
# repo shares it, so it is what decides whether another checkout is a sibling of
# this one or an unrelated project.
repo_object_store() {  # <dir>
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

# Live ordinary tasks working in a SIBLING WORKTREE OF THIS SAME REPO, other
# than the task whose PR <merged-url> is, printed as a comma list; returns 1
# when there are none.
#
# Not every live worker blocks this update, because a tracked-files
# fast-forward provably does not reach most of them: it leaves the gitignored
# operational dirs (data/, state/, config/, projects/, .no-mistakes/) alone, and
# a worker in another repository's worktree shares nothing with this checkout at
# all. A secondmate direct report is likewise not work in flight - it is a
# TARGET of this sweep, and is fast-forwarded under the same guards.
#
# A live worker in a worktree of THIS repo is the case that does not hold. It
# shares this checkout's object store and refs, so advancing the default branch
# moves the base underneath a task that is still building on it and can contend
# with that worker's own concurrent git operations (the contention
# bin/fm-fleet-sync.sh's packed-refs recovery exists for). A person invoking
# /updatefirstmate picks a moment past that; a merged-PR notification arrives
# whenever the forge says so, so this path waits instead.
#
# The task whose own PR just merged is not work in flight either, even though
# its meta and window usually still exist when the notification arrives: its
# work has landed, this home is fast-forwarding to the very commit it produced,
# and it is about to be torn down. bin/fm-pr-check.sh records the canonical PR
# URL as pr= in its meta, so that task is recognized by URL and excluded;
# otherwise the ordinary single-task merge would defer every time and the
# update would only ever land through the retry.
firstmate_work_in_flight() {  # <merged-url>
  local merged=$1 meta id window target backend worktree store self_store live=""
  [ -d "$STATE" ] || return 1
  self_store=$(repo_object_store "$FM_ROOT") || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null && continue
    [ "$(fm_meta_get "$meta" pr)" != "$merged" ] || continue
    id=$(basename "$meta" .meta)
    worktree=$(fm_meta_get "$meta" worktree)
    [ -n "$worktree" ] && [ -d "$worktree" ] || continue
    store=$(repo_object_store "$worktree") || continue
    [ "$store" = "$self_store" ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    target=$(fm_backend_target_of_meta "$meta")
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id" 2>/dev/null; then
      live="$live${live:+, }$id"
    fi
  done
  [ -n "$live" ] || return 1
  printf '%s\n' "$live"
}

if [ "$MODE" = after-merge ]; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"

  # Only a notification that CAME FROM the pending record may retire it. A fresh
  # --after-merge call that turns out to be some other project's merge must
  # leave an update this home already deferred exactly where it is, or an
  # unrelated project merging would quietly cancel a firstmate update that is
  # still owed.
  FROM_PENDING=0
  if [ -z "$MERGED_URL" ]; then
    MERGED_URL=$(pending_read) || {
      echo "after-merge: no pending update"
      exit 0
    }
    FROM_PENDING=1
  fi

  pending_retire_if_owned() {
    [ "$FROM_PENDING" -eq 1 ] || return 0
    pending_clear
  }

  if ! fm_pr_url_parse "$MERGED_URL"; then
    # A corrupt pending record would otherwise be retried forever.
    pending_retire_if_owned
    echo "after-merge: skipped: not a recognizable pull request URL" >&2
    exit 2
  fi
  MERGED_URL=$FM_PR_URL
  MERGED_ID=$(printf '%s/%s\n' "$FM_PR_HOST" "$FM_PR_PATH" | LC_ALL=C tr '[:upper:]' '[:lower:]')

  if ! SELF_ID=$(repo_identity); then
    pending_retire_if_owned
    echo "after-merge: skipped: this firstmate repo has no readable origin"
    exit 0
  fi
  if [ "$MERGED_ID" != "$SELF_ID" ]; then
    pending_retire_if_owned
    echo "after-merge: skipped: $MERGED_URL is not the firstmate repository ($SELF_ID)"
    exit 0
  fi

  ATTEMPTS=$(pending_attempts "$MERGED_URL")
  if BUSY=$(firstmate_work_in_flight "$MERGED_URL"); then
    if pending_write "$MERGED_URL" "$ATTEMPTS"; then
      echo "after-merge: deferred: firstmate work still in flight here ($BUSY)"
    else
      echo "after-merge: deferred: firstmate work still in flight here ($BUSY); pending record could not be written" >&2
    fi
    exit 0
  fi
  pending_write "$MERGED_URL" $((ATTEMPTS + 1)) \
    || echo "after-merge: pending record could not be written; a run cut short here is not retried" >&2
fi

# --- main firstmate repo ---------------------------------------------------

# A home that is itself leased as a secondmate home is treated exactly as
# process_secondmate treats every other secondmate home: detached HEAD on the
# default branch is its normal state, and its gitignored identity marker is not
# a dirty working tree. Every other guard - clean tree, ancestor, ff-only - is
# unchanged, so this decides only whether the target is eligible, never how it
# is advanced.
MAIN_AS_LEASED_HOME=no
if home_is_leased_secondmate; then
  MAIN_AS_LEASED_HOME=yes
fi

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin "$MAIN_AS_LEASED_HOME" "$MAIN_AS_LEASED_HOME"
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST (${remote_result#synced: })"
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
            fi
            ;;
          current:*) echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })" ;;
          *) echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_secondmate "$id" "$home" "" origin no
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"

# --- notification-mode delivery --------------------------------------------
# No reader is present to perform the skill's nudge step, so this mode sends it
# through the same durable steering record bootstrap's convergence sweep uses:
# the message is a durable inbox record, so a secondmate whose agent is mid-turn
# receives it rather than losing it, and a failed send leaves the bounded retry
# marker bootstrap already reconciles at the next session start.
if [ "$MODE" = after-merge ]; then
  pending_clear
  for selector in ${FF_NUDGE_WINDOWS:-}; do
    id=${selector#fm-}
    # The retry marker is only useful when it can be validated at retry time
    # against the live home and the commit it was written for, so an
    # unresolvable home leaves no marker rather than an unusable one that the
    # bootstrap retry would only reject.
    home=$(fm_meta_get "$STATE/$id.meta" home 2>/dev/null || true)
    [ -n "$home" ] || home=$(secondmate_registry_field "$SECONDMATES_MD" "$id" home || true)
    commit=
    [ -z "$home" ] || commit=$(git -C "$home" rev-parse HEAD 2>/dev/null || true)
    retry_marker=0
    if [ -n "$home" ] && [ -n "$commit" ]; then
      fm_secondmate_nudge_write "$STATE" "$id" "$home" "$commit" "" \
        "$FM_SECOND_MATE_NUDGE_MESSAGE" 0 && retry_marker=1
    fi
    if FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-send.sh" "$selector" "$FM_SECOND_MATE_NUDGE_MESSAGE" >/dev/null 2>&1; then
      marker=$(fm_secondmate_nudge_marker_path "$STATE" "$id") && rm -f -- "$marker"
      echo "after-merge: nudged $selector"
    elif [ "$retry_marker" -eq 1 ]; then
      echo "after-merge: nudge to $selector could not be delivered; it is retried at the next session start" >&2
    else
      echo "after-merge: nudge to $selector could not be delivered and is not retried: its home is not a local checkout this home can validate a retry against" >&2
    fi
  done
  echo "after-merge: completed"
fi

#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (seed local-only only as a local-origin mirror, run
# no-mistakes init), bin/fm-spawn.sh's advisory registry-deviation notice, and,
# through --origin, bin/fm-brief.sh, bin/fm-promote.sh, bin/fm-merge-local.sh,
# and bin/fm-teardown.sh.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [local-only +local-origin] - <desc> ...   -> local-only off, origin local-origin
# Flags start with "+" and may follow the mode in any order.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# --origin prints one word instead: the shape of this home's clone.
#   local-origin  a local-only entry carrying +local-origin. This home's clone is
#                 a mirror whose origin is the project's authoritative working
#                 repository; bin/fm-home-seed.sh writes the flag only for such a clone.
#                 It is not the project's authority: its workers push fm/<id> to
#                 that origin, and only the main home lands the branch there.
#   default       every other entry, including an unregistered project, whose
#                 registered mode keeps its ordinary delivery unchanged.
# The flag means nothing on a mode other than local-only, so there it warns and
# reads as default rather than altering a remote-backed project's delivery.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw|--origin] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
ORIGIN=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --origin) ORIGIN=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--origin] <project-name>}

fallback() {
  if [ "$ORIGIN" -eq 1 ]; then echo default; else echo "no-mistakes off"; fi
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  fallback
  exit 0
fi

# awk emits "<mode> <yolo> <origin>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; origin="default";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] !~ /^\+/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        if (a[j]=="+local-origin") origin="local-origin";
      }
    }
    print mode, yolo, origin; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  fallback
  exit 0
fi

read -r mode yolo origin <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; origin=default ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ "$ORIGIN" -eq 1 ] && [ "$origin" = local-origin ] && [ "$mode" != local-only ]; then
  echo "warn: +local-origin applies only to local-only projects; ignoring it for $NAME ($mode)" >&2
  origin=default
fi
if [ "$ORIGIN" -eq 1 ]; then
  echo "$origin"
  exit 0
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"

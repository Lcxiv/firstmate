#!/usr/bin/env bash
# fm-phone-fleet-summary.sh - render the canonical fleet snapshot as one compact
# Discord phone glance.
#
# With no arguments, this command reads only `fm-fleet-snapshot.sh --json` and
# prints five ordered sections: Decide, Queued, Building, Review, and Landed.
# The output deliberately excludes task ids, runtime details, state vocabulary,
# and private paths. Pull requests are emitted only as complete HTTPS URLs.
#
# The default 1750-character budget leaves room below the phone reply client's
# 1900-character default so the glance normally stays in one Discord message.
# A captain who lowers FM_PHONE_REPLY_MAX_CHARS below that budget lowers this
# one with it, because a split reply joins the glance's lines into one run-on
# paragraph and loses the five-column structure entirely.
# When necessary, entries are omitted in this order: Landed, Queued, Building,
# Review, then Decide. The reply reports omitted counts by column and invites a
# narrower follow-up, so truncation never masquerades as a complete fleet.
# A budget too small for even the empty five-column frame degrades to one
# honest counted line rather than to no answer at all; a single line survives
# the reply client's splitter with nothing to lose.
#
# Usage:
#   fm-phone-fleet-summary.sh
#   fm-phone-fleet-summary.sh --snapshot <fixture.json> [--max-chars <n>]
#
# `--snapshot` is a maintainer verification input for deterministic fixture
# coverage. The phone handler uses the no-argument canonical-source path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-phone-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-phone-lib.sh"

SNAPSHOT_FILE=
DEFAULT_MAX_CHARS=1750
MAX_CHARS=
TEMP_SNAPSHOT=

usage() {
  sed -n '2,24{s/^# \{0,1\}//;p;}' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SNAPSHOT_FILE=$2
      shift 2
      ;;
    --max-chars)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MAX_CHARS=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ -n "$MAX_CHARS" ]; then
  case "$MAX_CHARS" in
    ''|*[!0-9]*)
      echo "fm-phone-fleet-summary: invalid length budget" >&2
      exit 2
      ;;
  esac
  if [ "${#MAX_CHARS}" -gt 9 ] || [ "$MAX_CHARS" -lt 50 ] || [ "$MAX_CHARS" -gt 1900 ]; then
    echo "fm-phone-fleet-summary: length budget must be between 50 and 1900" >&2
    exit 2
  fi
else
  MAX_CHARS=$DEFAULT_MAX_CHARS
  REPLY_MAX=$(fm_phone_bounded "$(fm_phone_config_get FM_PHONE_REPLY_MAX_CHARS)" 1900 50 1900)
  [ "$MAX_CHARS" -le "$REPLY_MAX" ] || MAX_CHARS=$REPLY_MAX
fi

command -v python3 >/dev/null 2>&1 || {
  echo "fm-phone-fleet-summary: renderer unavailable" >&2
  exit 1
}

if [ -z "$SNAPSHOT_FILE" ]; then
  TEMP_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-phone-fleet-summary.XXXXXX") || {
    echo "fm-phone-fleet-summary: snapshot unavailable" >&2
    exit 1
  }
  trap 'rm -f "$TEMP_SNAPSHOT"' EXIT HUP INT TERM
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$TEMP_SNAPSHOT" 2>/dev/null || {
    echo "fm-phone-fleet-summary: snapshot unavailable" >&2
    exit 1
  }
  SNAPSHOT_FILE=$TEMP_SNAPSHOT
elif [ ! -f "$SNAPSHOT_FILE" ] || [ -L "$SNAPSHOT_FILE" ]; then
  echo "fm-phone-fleet-summary: snapshot unavailable" >&2
  exit 1
fi

python3 - "$SNAPSHOT_FILE" "$MAX_CHARS" <<'PY'
import json
import re
import sys
from collections import OrderedDict


snapshot_path, max_chars_raw = sys.argv[1], sys.argv[2]
max_chars = int(max_chars_raw)

try:
    with open(snapshot_path, encoding="utf-8") as handle:
        snapshot = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError):
    print("fm-phone-fleet-summary: snapshot unavailable", file=sys.stderr)
    raise SystemExit(1)

if snapshot.get("schema") != "fm-fleet-snapshot.v1":
    print("fm-phone-fleet-summary: unsupported snapshot", file=sys.stderr)
    raise SystemExit(1)


def compact_text(value):
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    text = re.sub(
        r"(?i)\b(?:token|secret|password|credential|webhook(?:\s+url)?|channel\s+id|captain\s+id)\b\s*[:=]\s*\S+",
        "[private detail omitted]",
        text,
    )
    text = re.sub(r"(?i)https?://(?:[^\s/]+\.)?discord(?:app)?\.com/api/webhooks/\S+", "[private detail omitted]", text)
    text = re.sub(r"(?<![A-Za-z0-9:/])(?:/[A-Za-z0-9._-]+){2,}/?", "[private detail omitted]", text)
    text = re.sub(r"\b[A-Za-z]:\\(?:[^\s\\]+\\)+[^\s]*", "[private detail omitted]", text)
    text = re.sub(r"\b\d{15,20}\b", "[private detail omitted]", text)
    text = text.replace("`", "'")
    if len(text) > 100:
        text = text[:99].rstrip() + "…"
    return text


GITHUB_PR = re.compile(
    r"^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])"
    r"/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$"
)
GITLAB_MR = re.compile(r"^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$")


def gitlab_host_valid(host):
    if not 1 <= len(host) <= 253 or host == "github.com":
        return False
    if host.startswith(".") or host.endswith(".") or ".." in host:
        return False
    labels = host.split(".")
    return all(1 <= len(label) <= 63 and not label.startswith("-") and not label.endswith("-") for label in labels)


def gitlab_path_valid(path):
    if not 3 <= len(path) <= 1024:
        return False
    if path.startswith("/") or path.endswith("/") or "//" in path:
        return False
    segments = path.split("/")
    if not 2 <= len(segments) <= 20:
        return False
    for segment in segments:
        if not 1 <= len(segment) <= 255:
            return False
        if segment in (".", "..") or segment.startswith("-"):
            return False
        if segment.endswith(".git") or segment.endswith(".atom"):
            return False
    return True


# The trust rule is the repo's canonical one from bin/fm-pr-lib.sh: a GitHub
# pull URL or a GitLab merge request URL on its own host, and nothing else.
# Backlog rows and status logs are scraped, so a captured URL can carry the
# sentence's trailing punctuation; that is stripped before matching rather than
# dropping the link.
def safe_pr_url(value):
    value = str(value or "").strip()
    value = value.rstrip(".,;:!?'\")]}>")
    if not value or len(value) > 500 or any(ch.isspace() for ch in value):
        return ""
    match = GITHUB_PR.match(value)
    if match:
        if "--" in match.group(1) or match.group(2) in (".", ".."):
            return ""
        return value
    match = GITLAB_MR.match(value)
    if match and gitlab_host_valid(match.group(1)) and gitlab_path_valid(match.group(2)):
        return value
    return ""


def pr_url(record, task):
    task_url = ((task or {}).get("pr") or {}).get("url")
    return safe_pr_url(task_url or (record or {}).get("pr_url"))


def display_title(record, task):
    title = compact_text((record or {}).get("title"))
    if title:
        return title
    project = compact_text((task or {}).get("project"))
    if project:
        return f"{project} work"
    return "Work not yet listed"


def item(record, task):
    return {"title": display_title(record, task), "pr": pr_url(record, task)}


backlog = snapshot.get("backlog") or {}
backlog_present = backlog.get("present") is True
records = backlog.get("records") or []
tasks = {task.get("id"): task for task in snapshot.get("tasks") or [] if task.get("id")}
columns = OrderedDict((name, []) for name in ("Decide", "Queued", "Building", "Review", "Landed"))
seen_task_ids = set()

for record in records:
    task = tasks.get(record.get("id")) if record.get("structured") else None
    if task:
        seen_task_ids.add(record.get("id"))
    state = record.get("state")
    if not record.get("structured"):
        target = "Landed" if state == "done" else ("Queued" if state == "queued" else "Building")
    elif state == "done":
        target = "Landed"
    elif record.get("hold_kind") == "captain" or ((task or {}).get("hints") or {}).get("open_decisions"):
        target = "Decide"
    elif state == "queued":
        target = "Queued"
    elif pr_url(record, task):
        target = "Review"
    else:
        target = "Building"
    columns[target].append(item(record, task))

for task_id in sorted(tasks):
    task = tasks[task_id]
    if task_id in seen_task_ids or task.get("kind") == "secondmate":
        continue
    if (task.get("hints") or {}).get("open_decisions"):
        target = "Decide"
    elif pr_url(None, task):
        target = "Review"
    else:
        target = "Building"
    columns[target].append(item(None, task))

unreadable_note = "Captain, I cannot read the fleet list right now, so I cannot tell you what is under way."

total_items = sum(len(entries) for entries in columns.values())
if total_items == 0:
    print("Captain, nothing under way right now." if backlog_present else unreadable_note)
    raise SystemExit(0)

totals = {name: len(entries) for name, entries in columns.items()}
shown = OrderedDict((name, list(entries)) for name, entries in columns.items())
omitted = {name: 0 for name in columns}


def render():
    if backlog_present:
        lines = ["Captain, here's the fleet at a glance:"]
    else:
        lines = ["Captain, I cannot read the fleet list right now, so this glance is incomplete:"]
    for number, (name, entries) in enumerate(shown.items(), start=1):
        total = totals[name]
        if entries:
            lines.append(f"**{number}. {name} ({total})**")
            for entry in entries:
                lines.append(f"• {entry['title']}")
                if entry["pr"]:
                    lines.append(f"  {entry['pr']}")
        elif total:
            lines.append(f"**{number}. {name} ({total})** - Not shown on this screen")
        else:
            lines.append(f"**{number}. {name} (0)** - Nothing")
    if any(omitted.values()):
        details = ", ".join(f"{name} {omitted[name]}" for name in columns if omitted[name])
        lines.append(f"Left out to fit one phone screen: {details}. Ask for one column to see the rest.")
    return "\n".join(lines)


def counted_line(with_columns):
    if with_columns:
        counts = ", ".join(f"{name} {totals[name]}" for name in columns if totals[name])
        body = f"{total_items} under way: {counts}."
    else:
        body = f"{total_items} under way."
    if backlog_present:
        return f"Captain, {body} Ask for one column to see the rest."
    return f"Captain, I cannot read the whole fleet list; {body} Ask for one column to see the rest."


drop_order = ("Landed", "Queued", "Building", "Review", "Decide")
while len(render()) > max_chars:
    removed = False
    for name in drop_order:
        if shown[name]:
            shown[name].pop()
            omitted[name] += 1
            removed = True
            break
    if not removed:
        break

output = render()
if len(output) > max_chars:
    output = counted_line(True)
if len(output) > max_chars:
    output = counted_line(False)
print(output)
PY

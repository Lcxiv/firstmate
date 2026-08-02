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
# When necessary, entries are omitted in this order: Landed, Queued, Building,
# Review, then Decide. The reply reports omitted counts by column and invites a
# narrower follow-up, so truncation never masquerades as a complete fleet.
#
# Usage:
#   fm-phone-fleet-summary.sh
#   fm-phone-fleet-summary.sh --snapshot <fixture.json> [--max-chars <n>]
#
# `--snapshot` is a maintainer verification input for deterministic fixture
# coverage. The phone handler uses the no-argument canonical-source path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_FILE=
MAX_CHARS=1750
TEMP_SNAPSHOT=

usage() {
  sed -n '2,20{s/^# \{0,1\}//;p;}' "$0" >&2
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

case "$MAX_CHARS" in
  ''|*[!0-9]*)
    echo "fm-phone-fleet-summary: invalid length budget" >&2
    exit 2
    ;;
esac
if [ "$MAX_CHARS" -lt 500 ] || [ "$MAX_CHARS" -gt 1900 ]; then
  echo "fm-phone-fleet-summary: length budget must be between 500 and 1900" >&2
  exit 2
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
from urllib.parse import urlsplit


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
    text = re.sub(r"(?:^|(?<=\s))(?:/[A-Za-z0-9._-]+){2,}(?=[\s,;:.)\]}]|$)", "[private detail omitted]", text)
    text = re.sub(r"\b[A-Za-z]:\\(?:[^\s\\]+\\)+[^\s]*", "[private detail omitted]", text)
    text = re.sub(r"\b\d{15,20}\b", "[private detail omitted]", text)
    text = text.replace("`", "'")
    if len(text) > 100:
        text = text[:99].rstrip() + "…"
    return text


def safe_pr_url(value):
    value = str(value or "").strip()
    if not value or len(value) > 500 or any(ch.isspace() for ch in value):
        return ""
    parsed = urlsplit(value)
    is_pull_request = re.search(r"/(?:pull|merge_requests)/\d+/?$", parsed.path)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or not is_pull_request
    ):
        return ""
    return value


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


records = (snapshot.get("backlog") or {}).get("records") or []
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

total_items = sum(len(entries) for entries in columns.values())
if total_items == 0:
    print("Captain, nothing under way right now.")
    raise SystemExit(0)

totals = {name: len(entries) for name, entries in columns.items()}
shown = OrderedDict((name, list(entries)) for name, entries in columns.items())
omitted = {name: 0 for name in columns}


def render():
    lines = ["Captain, here's the fleet at a glance:"]
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
    print("fm-phone-fleet-summary: length budget unavailable", file=sys.stderr)
    raise SystemExit(1)
print(output)
PY

#!/usr/bin/env bash
# fm-board.sh - captain-facing kanban board renderer over fm-fleet-snapshot.sh.
#
# Renders the live fleet as one self-contained HTML board for visual review in
# Lavish Editor (lavish-axi). Like fm-fleet-view.sh and fm-bearings-snapshot.sh
# it intentionally does not parse fleet state itself: backlog rows (all states
# including captain holds), live task rows (recorded harness/model/effort and
# current stage), and recorded PR links all come from the canonical
# `fm-fleet-snapshot.sh --json` contract. The only extra input is the
# hand-maintained effort maps under data/maps/*.md, which no snapshot surface
# owns; each map contributes a top-band card (destination, decided and open
# decision counts, fog, out of scope).
#
# Columns are the ordered pipeline steps Decide / Queued / Building / Review /
# Landed:
#   Decide   - captain-held backlog rows plus live tasks with open keyed
#              decisions; each card carries an approval panel (radio options
#              plus a free-text override) that queues exactly one Lavish prompt
#              per submit.
#   Queued   - queued backlog rows without a captain hold.
#   Building - in-flight work with no recorded PR yet.
#   Review   - work whose PR is recorded in task meta or backlog (the same
#              recording fm-pr-check.sh makes when it arms the merge poll), so
#              a Review card always links the PR.
#   Landed   - Done backlog rows.
#
# The board never mutates fleet state: approval submits and card drags queue
# Lavish prompts that come back to firstmate as exact orders, and the captain
# releases them with Send to Agent. Approval panels are rendered as siblings
# AFTER each card's todo <ul>, never inside it - nesting <details> inside the
# list is the known clipping bug shape. The `.meta-row .badge` style rule is
# the second clipping defense: DaisyUI's .badge is fixed-height and does not
# wrap, so long map metadata (fog, out of scope) is clipped without it. The
# ellipsis truncation those fields already get is not a substitute - even
# truncated they exceed one badge line. tests/fm-board.test.sh asserts the
# rule in the emitted HTML.
#
# Output: $FM_HOME/.lavish/fleet-board.html by default; --out overrides.
# The file is a generated view - regenerate rather than edit it.
#
# usage: fm-board.sh [--out <path>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
OUT="$FM_HOME/.lavish/fleet-board.html"

usage() {
  cat <<'EOF'
usage: fm-board.sh [--out <path>]

Generate the captain-facing kanban board (Decide / Queued / Building /
Review / Landed) from the live fleet snapshot plus data/maps/*.md.
Writes $FM_HOME/.lavish/fleet-board.html unless --out overrides it.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      OUT=$2; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "fm-board: python3 not found" >&2; exit 1; }

SNAP_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-board.XXXXXX") || exit 1
trap 'rm -f "$SNAP_FILE"' EXIT

"$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$SNAP_FILE" \
  || { echo "fm-board: fleet snapshot failed" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")" || exit 1

python3 - "$SNAP_FILE" "$DATA/maps" "$OUT" <<'PY'
import html
import json
import os
import re
import sys

snap_path, maps_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(snap_path, encoding="utf-8") as f:
    snap = json.load(f)

records = snap.get("backlog", {}).get("records", [])
tasks = {t.get("id"): t for t in snap.get("tasks", [])}


def esc(value):
    return html.escape(str(value or ""), quote=True)


def slugify(value):
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", str(value or "")).strip("-")
    return slug[:80] or "decision"


def clip(text, limit):
    text = str(text or "").strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def decision_key(record, task):
    for line in (record or {}).get("body_lines", []) or []:
        match = re.match(r"\s*Decision key:\s*(\S+)", line)
        if match:
            return slugify(match.group(1))
    for dec in ((task or {}).get("hints", {}) or {}).get("open_decisions", []) or []:
        if dec.get("key"):
            return slugify(dec["key"])
    return slugify((record or {}).get("id") or (task or {}).get("id"))


def pr_url(record, task):
    url = ((task or {}).get("pr", {}) or {}).get("url")
    return url or (record or {}).get("pr_url")


# --- classify every backlog row and live task into one pipeline column ------
decide, queued, building, review, landed = [], [], [], [], []
seen_task_ids = set()

for record in records:
    task = tasks.get(record.get("id")) if record.get("structured") else None
    if task:
        seen_task_ids.add(record["id"])
    state = record.get("state")
    if not record.get("structured"):
        target = landed if state == "done" else (queued if state == "queued" else building)
        target.append((record, None))
        continue
    hints = (task or {}).get("hints", {}) or {}
    if state == "done":
        landed.append((record, task))
    elif record.get("hold_kind") == "captain" or hints.get("open_decisions"):
        decide.append((record, task))
    elif state == "queued":
        queued.append((record, task))
    elif pr_url(record, task):
        review.append((record, task))
    else:
        building.append((record, task))

for task_id in sorted(tasks):
    task = tasks[task_id]
    if task_id in seen_task_ids or task.get("kind") == "secondmate":
        continue
    if (task.get("hints", {}) or {}).get("open_decisions"):
        decide.append((None, task))
    elif pr_url(None, task):
        review.append((None, task))
    else:
        building.append((None, task))


# --- effort maps under data/maps/ -------------------------------------------
def parse_map(path):
    info = {
        "title": os.path.basename(path)[:-3],
        "destination": "",
        "decided": 0,
        "open": 0,
        "fog": [],
        "out_of_scope": [],
    }
    section = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip()
            if line.startswith("# "):
                match = re.match(r"#\s*(?:Effort map:\s*)?(.+)", line)
                if match:
                    info["title"] = match.group(1).strip()
            elif line.startswith("## "):
                heading = line[3:].strip().lower()
                if heading.startswith("destination"):
                    section = "destination"
                elif heading.startswith("decisions"):
                    section = "decided"
                elif heading.startswith("open"):
                    section = "open"
                elif heading.startswith("not yet"):
                    section = "fog"
                elif heading.startswith("out of scope"):
                    section = "out_of_scope"
                else:
                    section = None
            elif section == "destination" and line.strip():
                joiner = " " if info["destination"] else ""
                info["destination"] += joiner + line.strip()
            elif line.lstrip().startswith("- "):
                item = line.lstrip()[2:].strip()
                if section == "decided":
                    info["decided"] += 1
                elif section == "open":
                    info["open"] += 1
                elif section == "fog":
                    info["fog"].append(item)
                elif section == "out_of_scope":
                    info["out_of_scope"].append(item)
    return info


maps = []
if os.path.isdir(maps_dir):
    for name in sorted(os.listdir(maps_dir)):
        if name.endswith(".md"):
            try:
                maps.append(parse_map(os.path.join(maps_dir, name)))
            except OSError:
                continue


# --- card rendering ----------------------------------------------------------
def stage_of(record, task):
    if task:
        current = task.get("current_state", {}) or {}
        state = current.get("state") or "unknown"
        detail = current.get("detail") or ""
        return f"{state} - {detail}" if detail else state
    if record and record.get("hold_kind") == "captain":
        return "awaiting decision"
    if record and record.get("blocked_by"):
        return f"blocked by {record['blocked_by']}"
    if record and record.get("state") == "done":
        verb = (record.get("completion", {}) or {}).get("verb") or "done"
        date = (record.get("completion", {}) or {}).get("date") or ""
        return f"{verb} {date}".strip()
    return "no live worker yet"


def crew_badge(task):
    if not task:
        return ""
    parts = [task.get("harness") or "?"]
    if task.get("model") and task["model"] != "default":
        parts.append(task["model"])
    if task.get("effort"):
        parts.append(f"{task['effort']} effort")
    return " · ".join(parts)


def todo_lines(record):
    lines = []
    for line in (record or {}).get("body_lines", []) or []:
        line = line.strip()
        if line:
            lines.append(clip(line, 160))
        if len(lines) == 4:
            break
    return lines


def approval_panel(record, task):
    key = decision_key(record, task)
    reason = (record or {}).get("hold_reason") or ""
    if not reason:
        for dec in ((task or {}).get("hints", {}) or {}).get("open_decisions", []) or []:
            if dec.get("summary"):
                reason = dec["summary"]
                break
    parts = [f'<details class="approval" data-lavish-question="{esc(key)}">']
    parts.append("<summary>⚑ YOUR APPROVAL - click for options</summary>")
    if reason:
        parts.append(f'<p class="text-xs opacity-80">{esc(clip(reason, 320))}</p>')
    parts.append(f'<form data-question="{esc(key)}" onsubmit="return fbDecide(event)">')
    options = [
        ("approve - proceed as recommended", True),
        ("hold for now", False),
        ("more detail first - report back before acting", False),
    ]
    for value, recommended in options:
        label = f"<b>{esc(value.capitalize())}</b>" if recommended else esc(value.capitalize())
        parts.append(
            f'<label><input type="radio" name="{esc(key)}" value="{esc(value)}"> {label}</label>'
        )
    parts.append(
        '<textarea name="freetext" rows="1" class="textarea textarea-bordered textarea-xs"'
        ' placeholder="…or write your own answer"></textarea>'
    )
    parts.append('<button type="submit" class="btn btn-warning btn-xs mt-1">Queue this answer</button>')
    parts.append(
        '<span class="queued-note">✓ queued - press Send to Agent when done choosing</span>'
    )
    parts.append("</form></details>")
    return "".join(parts)


TICKET_CLASS = {
    "decide": "t-captain",
    "queued": "t-queued",
    "building": "t-flight",
    "review": "t-upstream",
    "landed": "t-done",
}


def card(record, task, column):
    title = (record or {}).get("title") or (record or {}).get("raw") or (task or {}).get("id") or "untitled"
    url = pr_url(record, task)
    heading = f'<a class="link" href="{esc(url)}">{esc(clip(title, 140))}</a>' if url else esc(clip(title, 140))
    badges = []
    repo = (record or {}).get("repo")
    if repo:
        badges.append(f'<span class="badge badge-xs badge-ghost">{esc(repo)}</span>')
    kind = (record or {}).get("kind") or (task or {}).get("kind")
    if kind:
        badges.append(f'<span class="badge badge-xs badge-ghost">{esc(kind)}</span>')
    crew = crew_badge(task)
    if crew:
        badges.append(f'<span class="badge badge-xs badge-info badge-outline">crew: {esc(crew)}</span>')
    badges.append(f'<span class="badge badge-xs badge-ghost">stage: {esc(clip(stage_of(record, task), 90))}</span>')
    blocked_by = (record or {}).get("blocked_by")
    if blocked_by:
        badges.append(f'<span class="badge badge-xs badge-warning badge-outline">blocked-by: {esc(blocked_by)}</span>')

    parts = [
        '<div draggable="true" ondragstart="fbDrag(event, this)"'
        ' ondragend="this.classList.remove(\'dragging\')"'
        f' class="card card-compact bg-base-100 ticket {TICKET_CLASS[column]} shadow"'
        f' data-board-id="{esc((record or {}).get("id") or (task or {}).get("id") or "")}">',
        '<div class="card-body">',
        f'<h3 class="font-semibold text-sm">{heading}</h3>',
        f'<div class="meta-row">{"".join(badges)}</div>',
    ]
    lines = todo_lines(record)
    if not lines and task:
        note = ((task.get("hints", {}) or {}).get("last_event_text")) or ""
        if note:
            lines = [clip(note, 160)]
    if lines:
        items = "".join(f"<li>{esc(line)}</li>" for line in lines)
        parts.append(f'<ul class="todos opacity-80">{items}</ul>')
    # The approval panel is a SIBLING of the todo list on purpose: a <details>
    # inside the <ul> is the prototype's clipping bug.
    if column == "decide":
        parts.append(approval_panel(record, task))
    parts.append("</div></div>")
    return "".join(parts)


def column_html(key, number, emoji, title, accent, entries):
    cards = "".join(card(record, task, key) for record, task in entries)
    if not cards:
        cards = '<div class="text-xs opacity-50 italic p-2">nothing here</div>'
    return (
        '<section class="col" ondragover="event.preventDefault(); this.classList.add(\'dropover\')"'
        ' ondragleave="this.classList.remove(\'dropover\')" ondrop="fbDrop(event, this)">'
        f'<h2 class="font-semibold mb-2 {accent}">{number} · {emoji} {title}</h2>'
        f'<div class="flex flex-col gap-3">{cards}</div>'
        "</section>"
    )


def map_card(info):
    badges = [
        f'<span class="badge badge-xs badge-success">{info["decided"]} decided</span>',
        f'<span class="badge badge-xs badge-warning">{info["open"]} open</span>',
    ]
    fog = clip("; ".join(info["fog"]), 120) if info["fog"] else "none - remaining work is sharp"
    badges.append(f'<span class="badge badge-xs badge-ghost">fog: {esc(fog)}</span>')
    if info["out_of_scope"]:
        badges.append(
            f'<span class="badge badge-xs badge-ghost">out of scope: {esc(clip("; ".join(info["out_of_scope"]), 120))}</span>'
        )
    return (
        '<div class="card card-compact bg-base-100 shadow border-l-4" style="border-left-color: oklch(78% 0.14 200);">'
        '<div class="card-body">'
        f'<h3 class="font-semibold text-sm">\U0001f5fa️ Effort: {esc(info["title"])}</h3>'
        f'<p class="text-xs opacity-80"><b>Destination:</b> {esc(clip(info["destination"], 320))}</p>'
        f'<div class="meta-row">{"".join(badges)}</div>'
        "</div></div>"
    )


generated = snap.get("generated") or ""
date = generated[:10]
counts = [
    ("badge-warning", f"Your call: {len(decide)}"),
    ("badge-accent", f"Queued: {len(queued)}"),
    ("badge-info", f"Building: {len(building)}"),
    ("badge-secondary", f"Review: {len(review)}"),
    ("badge-success", f"Landed: {len(landed)}"),
]
count_html = "".join(
    f'<span class="badge {cls} badge-outline">{esc(text)}</span>' for cls, text in counts
)
maps_html = ""
if maps:
    maps_html = (
        '<div class="mb-4 grid grid-cols-1 md:grid-cols-2 gap-3">'
        + "".join(map_card(m) for m in maps)
        + "</div>"
    )

columns = "".join(
    [
        column_html("decide", 1, "⚓", "Decide", "text-warning", decide),
        column_html("queued", 2, "\U0001f9ed", "Queued", "text-accent", queued),
        column_html("building", 3, "⛵", "Building", "text-info", building),
        column_html("review", 4, "\U0001f30a", "Review", "text-secondary", review),
        column_html("landed", 5, "\U0001f3c1", "Landed", "text-success", landed),
    ]
)

page = f"""<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fleet Board — {esc(date)}</title>
<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
<link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css">
<style>
  .col {{ min-width: 0; }}
  .card-compact .card-body {{ padding: 0.85rem; }}
  .ticket {{ border-left: 4px solid transparent; overflow: visible; }}
  .card, .card-body, .todos, .todos li, details, summary {{ overflow: visible !important; max-height: none !important; height: auto !important; }}
  .t-captain {{ border-left-color: oklch(75% 0.18 60); }}
  .t-flight  {{ border-left-color: oklch(70% 0.15 250); }}
  .t-queued  {{ border-left-color: oklch(70% 0.12 180); }}
  .t-upstream{{ border-left-color: oklch(72% 0.14 300); }}
  .t-done    {{ border-left-color: oklch(72% 0.17 145); }}
  .todos {{ font-size: 0.72rem; line-height: 1.35; }}
  .todos li {{ list-style: none; }}
  .meta-row {{ display:flex; flex-wrap:wrap; gap:0.3rem; margin:0.25rem 0; }}
  .meta-row .badge {{ height:auto; min-height:1.1rem; white-space:normal; text-align:left; line-height:1.3; padding-top:0.1rem; padding-bottom:0.1rem; }}
  .approval {{ background: oklch(30% 0.06 60 / 0.4); border: 1px solid oklch(75% 0.18 60 / 0.7); border-radius: 0.4rem; padding: 0.25rem 0.45rem; margin: 0.25rem 0; }}
  .approval summary {{ font-weight: 700; color: oklch(85% 0.16 70); cursor: pointer; font-size: 0.7rem; }}
  .approval textarea {{ width:100%; font-size:0.7rem; margin-top:0.2rem; }}
  .approval label {{ display:block; font-size:0.7rem; padding:0.1rem 0; cursor:pointer; }}
  .approval .queued-note {{ display:none; font-size:0.7rem; color: oklch(80% 0.15 145); font-weight:600; }}
  .dragging {{ opacity: 0.4; }}
  .col.dropover {{ outline: 2px dashed oklch(70% 0.15 250); outline-offset: 4px; border-radius: 0.5rem; }}
</style>
</head>
<body class="bg-base-200 min-h-screen p-4 md:p-6">
<div class="max-w-[1700px] mx-auto">
  <header class="mb-5 flex flex-wrap items-end justify-between gap-2">
    <div>
      <h1 class="text-2xl font-bold">Fleet Board</h1>
      <p class="text-sm opacity-70">snapshot {esc(generated)} · regenerate with bin/fm-board.sh; say “refresh the board” anytime</p>
    </div>
    <div class="flex gap-2 text-xs">{count_html}</div>
  </header>
  {maps_html}
  <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-5 gap-4">
{columns}
  </div>
  <footer class="mt-6 text-xs opacity-60">Static snapshot — answer Decide cards or drag tickets, then press Send to Agent; firstmate dispatches from this board.</footer>
</div>
<script>
let fbDragged=null;
function fbDrag(ev, el){{ fbDragged=el; el.classList.add('dragging'); ev.dataTransfer.effectAllowed='move'; }}
function fbDrop(ev, colEl){{
  ev.preventDefault(); colEl.classList.remove('dropover');
  if(!fbDragged) return;
  const ticket=(fbDragged.querySelector('h3')||{{}}).innerText||'ticket';
  const stage=(colEl.querySelector('h2')||{{}}).innerText||'column';
  colEl.querySelector('.flex.flex-col').appendChild(fbDragged);
  if(window.lavish && window.lavish.queuePrompt){{
    window.lavish.queuePrompt('Move ticket "'+ticket.trim()+'" to stage "'+stage.trim()+'" - advance it accordingly', {{ tag:'move', text:ticket.trim()+' -> '+stage.trim(), element: fbDragged, queueKey:'move-'+ticket.trim() }});
  }}
  fbDragged=null;
}}
function fbDecide(ev){{
  ev.preventDefault();
  const form=ev.currentTarget;
  const key=form.dataset.question;
  const fd=new FormData(form);
  const c=((fd.get('freetext')||'').trim()) || fd.get(key);
  if(c && window.lavish && window.lavish.queuePrompt){{
    window.lavish.queuePrompt('Decision '+key+': '+c, {{ tag:'choice', text:key+': '+c, element: form, queueKey:key, data:{{question:key, answer:c}} }});
    form.querySelector('.queued-note').style.display='block';
  }}
  return false;
}}
</script>
</body>
</html>
"""

with open(out_path, "w", encoding="utf-8") as f:
    f.write(page)
PY
rc=$?
[ "$rc" -eq 0 ] || { echo "fm-board: render failed" >&2; exit "$rc"; }
printf 'board: %s\n' "$OUT"

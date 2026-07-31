---
name: effort-maps
description: >-
  Agent-only convention for effort maps: one orientation artifact per large multi-session effort under data/maps/.
  Load before creating, updating, or retiring an effort map, and at intake of an effort too large or foggy for one session.
  Owns the map format, the fog-versus-work-item test, decision indexing, fog graduation into the backlog, refer-by-name, and retirement.
user-invocable: false
metadata:
  internal: true
---

# effort-maps

Keep one map per large fuzzy effort, so any future session - or the captain, cold - orients in one read.
A map is an orientation index, never a tracker: the backlog remains the only work queue, and `decision-hold-lifecycle` remains the only owner of captain-decision mechanics.
This convention is markdown plus this skill text only; there is no script, hook, or automation behind it.

This skill is adapted from the MIT-licensed `wayfinder` skill in [mattpocock/skills](https://github.com/mattpocock/skills), Copyright (c) 2026 Matt Pocock; the text here is Firstmate's own.

## Where maps live

Each map is one file at `data/maps/<effort-slug>.md` in the operating home.
`data/` is captain-private and gitignored, so maps never ship with this repo; this skill documents the convention and never contains an actual map.
A map directly under `data/maps/` is active; retirement moves it to `data/maps/done/` (see Retirement).

## Map format

```markdown
## Destination

<one or two lines naming what done looks like for this effort>

## Notes

<standing constraints and captain preferences for this effort>

## Decisions so far

- <decision name, wrapped as a link to its authoritative record> - <one-line gist of the answer>

## Not yet specified

<in-scope questions not yet phraseable precisely - the fog of war>

## Out of scope

- <ruled-out work> - <one-line reason it is out>
```

### Destination

One or two lines naming what reaching the end of the effort looks like - a spec, a locked decision, a shipped change.
Every session reading the map orients to the Destination before choosing work, because it fixes the effort's scope.

### Notes

Standing constraints and captain preferences that apply to the whole effort, recorded once so no session re-derives them.

### Decisions so far

An index, never a store.
One line per resolved decision: the decision's name, a one-line gist, and a link to the authoritative decision record file or backlog item that holds the detail.
A decision lives in exactly one place - its record - so the map never restates detail beyond the gist.

### Not yet specified

The fog of war: in-scope questions that cannot yet be phrased precisely.
The test for fog versus work item is "can you state the question precisely now", never "can you answer it now".
A precisely statable question belongs in the backlog even while blocked; a question you cannot yet phrase that sharply stays here as fog.
Do not pre-slice fog into fake work items: one patch of fog may graduate into several items, or none, once resolved decisions sharpen it.

### Out of scope

Work consciously ruled out of this effort, one line each with the reason it is out.
Out-of-scope work never graduates: it returns only if the Destination itself is redrawn, and then as a fresh effort with a fresh map, never a resumption of this one.

## Lifecycle

- Create a map at intake of an effort too large or foggy for one session, naming the Destination first.
- Append one index line to Decisions so far whenever a captain decision for the effort is durably resolved; `decision-hold-lifecycle` owns the decision mechanics and record, and the map only points at them.
- Graduate fog into concrete backlog items only when a resolution makes a question precisely statable, removing the graduated patch from Not yet specified so it lives only as its backlog item.
- Read each active map during orientation - session-start recovery and bearings - while its effort has live or queued work.
- Refer by name in captain-facing text: decisions and work items go by their names, and ids ride inside links, never in place of the name.

## Retirement

Retire a map when its Destination is reached or the captain explicitly ends the effort.
Append a one-line outcome under Destination, then move the file to `data/maps/done/<effort-slug>.md` so orientation reads skip it.
Never retire a map while the effort still has unresolved captain decisions; those close through `decision-hold-lifecycle` first.

## Boundaries

- The backlog is the only work queue: the map lists no open work items and never becomes a second tracker.
- `decision-hold-lifecycle` is the only owner of captain-decision mechanics: the map indexes its resolved records and never becomes a second decision store.
- No bin script, hook, or automation: the convention stays markdown plus this skill text.

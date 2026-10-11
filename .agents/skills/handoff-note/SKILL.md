---
name: handoff-note
description: >-
  Agent-only procedure for the session handoff note, the one record that carries the conversation a fresh session cannot rebuild from durable records.
  Load when the captain says save, handoff, wrap up, stop for tonight or start fresh, at the end of every /stow, and when a conversation has grown long enough that a fresh session would serve the captain better than another compaction.
  Owns the note's location, the overwrite-plus-dated-copy contract, its section list, and what must never go in it.
user-invocable: false
metadata:
  internal: true
---

# handoff-note

A fresh session already rebuilds fleet state from durable records through the session-start digest.
What it cannot rebuild is the conversation: what the captain asked, what was promised, what is half done, and what they are waiting to hear.
This note carries exactly that, and nothing the digest or a report already holds.

## Where it goes

Write the note to `$FM_HOME/data/handoff/latest.md`, creating `data/handoff/` if it does not exist yet.
`FM_HOME` selects the home whose session this is; when it is unset the effective home is the tracked code root, exactly as every other script in `bin/` resolves it.
`latest.md` is overwritten every time, because it describes now rather than history.

Immediately after writing it, keep a dated copy so an earlier note stays recoverable:

```sh
cp "$FM_HOME/data/handoff/latest.md" "$FM_HOME/data/handoff/$(date +%Y-%m-%d-%H%M).md"
```

The dated copies are recoverability only; nothing reads them automatically.
`data/handoff/` is private and gitignored with the rest of `data/`, and [`docs/configuration.md`](../../../docs/configuration.md) owns its place in the operational-home layout.

## What it says

Keep it under about 120 lines, plain text, with no em or en dashes.
These sections, in this order, each omitted when it would be empty:

1. `# Handoff, <date> <time>`, then one line: what this session was mostly about.
2. `## Waiting on the captain`: each open decision or word they owe, one line each, with the exact phrase that unblocks it when there is one (for example: say "save the drafts").
3. `## Open asks`: requests not yet finished, quoting the captain's own words, and where each stands.
4. `## Promised next`: what firstmate said it would do or bring back, and when.
5. `## Work under way`: one line per live worker or pending wake source, saying what it is doing and the next expected event.
   Point to its report; never paste it.
6. `## Gotchas this session`: traps worth knowing tomorrow that are not yet in `data/learnings.md`; route durable ones there too.
7. `## Pointers`: the reports, files, and backlog ids the next session should open first.

Rules:

- Quote the captain verbatim where their wording matters; never paraphrase a decision into a stronger one.
- No secrets, tokens, passwords, or personal identifiers beyond the names already in the backlog.
- Do not restate the backlog, the digest, learnings, or reports: point to them.
- Overwrite `latest.md` every time.

## How the next session gets it

`bin/fm-session-start.sh` prints a fresh note as its own labelled section, in the digest's safety preamble right after the wake queue, on every path that emits the digest: a true startup and a context re-emit after a `/clear` or a compaction alike.
A note past the freshness bound, or no note at all, prints one short line instead of a body.
That script's header owns the bound, its override, and the section's exact placement argument; nothing here needs a separate session-open hook.

So after writing the note, tell the captain in one line that it is saved and that a fresh session will load it.

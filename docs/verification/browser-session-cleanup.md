# Browser session cleanup verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the guarantee that a browser launched for one task is stopped with that task on the tool's healthy stop path, and that no other browser is touched.
[`bin/fm-browser-session-lib.sh`](../../bin/fm-browser-session-lib.sh) owns the mechanism; this file records what was measured.
Exact task chronology, branch names, and delivery transcripts remain in private reports or PR evidence.

## Why cwd alone cannot attribute a browser

Measured on 2026-09-16 with chrome-devtools-axi 0.1.34, Google Chrome 152.0.7977.83, macOS 25.5.0.

Two directories stood in for two task worktrees.
A browser was opened from worktree A, then a second command for the same session name was run from worktree B.

```sh
( cd "$WT_A" && CHROME_DEVTOOLS_AXI_SESSION=s CHROME_DEVTOOLS_AXI_PORT=19732 \
    chrome-devtools-axi open about:blank )
( cd "$WT_B" && CHROME_DEVTOOLS_AXI_SESSION=s CHROME_DEVTOOLS_AXI_PORT=19732 \
    chrome-devtools-axi pages )
cat ~/.chrome-devtools-axi/sessions/s/bridge.pid
```

Observed output:

```text
pages[2]{id,url,selected}:
  1,about:blank,false
  2,about:blank,false
{"pid":60457,"port":19732}
```

The second worktree drove the browser the first worktree had launched; the bridge pid was unchanged.

Replaying `bin/fm-teardown.sh`'s cwd scan (`lsof -a -d cwd -Fpn`, filtered to each root) against both roots:

```text
=== sweep of worktree A (launcher) ===
14350 14352 14382 14602 14821 18188 18612 18616 18649 18866 18876 19275 60457 60460 60489 60490 60491 60493 60497 60498 60499 60501 60502 60505
=== sweep of worktree B (the task that USED the browser) ===
<NONE>
```

Every process in the tree inherits the launching cwd, so the task that merely used the browser has no cwd evidence for any of it.
Its cleanup is a correct, silent no-op while the browser survives.

Process-group structure from the same run, which is why closing the pane does not reach the tree either:

```text
14350 ppid=1 pgid=14350 node                     <- bridge, detached, own group
  14352 ppid=14350 pgid=14350 npm exec chrome-devtools-mcp
    14382 ppid=14352 pgid=14350 chrome-devtools-mcp
      14821 ppid=14382 pgid=14821 Google Chrome  <- Chrome re-groups again
        18612 ppid=14821 pgid=14821 Google Chrome Helper
        ...
        26059 ppid=14821 pgid=26059 GoogleUpdater
```

The bridge is reparented to init in its own process group, and Chrome leads a third group, so neither the pane's group signal nor a signal to the bridge's group reaches the whole tree.

## What per-session retirement does reach

Same date, same versions.
Two lab browsers were running concurrently on their own sessions, ports and freshly created profiles: `fmlab-owned` (13 processes) and `fmlab-iso` (11 processes).

```sh
CHROME_DEVTOOLS_AXI_SESSION=fmlab-owned CHROME_DEVTOOLS_AXI_PORT=19731 \
  chrome-devtools-axi stop
```

Observed output, then a census of each tree:

```text
status: stopped

=== OWNED tree survivors ===
(blank above = all retired)

=== CONTROL tree survivors (must be all 11) ===
11 / 11 alive
```

One session's stop retired that session's bridge, npx, MCP server, Chrome, every Chrome helper and the updater Chrome spawned, and left the other session's browser whole.
Every pre-existing browser process on the machine survived; the only pids that disappeared from the pre-run census were Chrome's own `--type=renderer` processes recycling, none of them a browser root.

### Limits of this measurement

This measured the **healthy stop path only**: a live bridge whose shutdown handler ran to completion, where the whole tree did exit.
Two paths were not measured and are not claimed here.

- A bridge SIGKILLed out from under its shutdown handler — which the memory pressure in the original incident can cause — leaves a stale pid record; only that the recorded pid is gone is knowable, not whether the Chrome tree exited.
- A shutdown that wedges on a dead CDP transport makes the tool escalate to the bridge's own process group, which (per the group structure above) does not contain Chrome.

In both, a Chrome tree can outlive the bridge.
Cleanup therefore only ever proves the bridge, and [`bin/fm-browser-session-lib.sh`](../../bin/fm-browser-session-lib.sh) words every message to the bridge rather than to the browser.
Recording the Chrome tree's own ownership at launch would be needed to close this, and is deliberately out of scope: the design reuses the tool's per-session pid file as the sole registry rather than creating a parallel one.

## Accepted tradeoff: peak memory

Isolating a browser per task is what makes ownership provable, and it is what removes accumulation **across** tasks — each tree is now retired with the task that bound it, instead of outliving every task that ever touched it.
The cost is at the other end: each browser-using task now holds its own bridge, MCP server and Chrome tree rather than sharing one, so several browser-using tasks running at once carry a higher **peak** footprint than the single shared tree they used to reuse.

Going back to a shared session is not available: one task's cleanup would then reach another task's browser, which the ownership contract forbids outright.
A cap on how many browser-bound tasks may run at once is deliberately out of scope for this change and would be separate work.

## Refreshing this record

```sh
FM_BROWSER_SESSION_LIVE_E2E=1 bash tests/fm-browser-session-live-e2e.test.sh
```

That opt-in guard rebuilds the two-session lab from scratch against the installed chrome-devtools-axi and a real Chrome, asserts the retired tree is gone and the other session's tree survives byte-for-byte, asserts a repeated retirement is a no-op, and fails naming the tool version.
Run it after every chrome-devtools-axi upgrade.
It skips explicitly when chrome-devtools-axi, lsof, or python3 is absent.

Latest run: 2026-09-16, chrome-devtools-axi 0.1.34.

```text
ok - chrome-devtools-axi 0.1.34: retiring one session retires its whole browser tree and leaves another session's browser untouched
```

The portable regression that pins firstmate's own half - that ownership is proved from the task record before anything is signalled - is `tests/fm-browser-session.test.sh` and needs no browser.

## Runtime and harness coverage

The binding rides `spawn_send_text_line`, the same channel that already ships `GOTMPDIR`, so every supported runtime backend and harness receives it on the same code path; see [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh).
A runtime where the export does not reach the agent degrades to the pre-binding behavior: the session is recorded but never used, cleanup proves no owned bridge, and nothing is signalled.

# Hermes Agent

Verified on 2026-07-30 with Hermes Agent 0.19.0.

Hermes Agent launches from the absolute `hermes` executable resolved from `PATH`.
When `HERMES_HOME` is set, Firstmate forwards that exact home into the worker pane so hook installation, credentials, and runtime state stay on the same store.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Executable `hermes` from `PATH`; spawning refuses if it is unavailable. |
| Persistent launch | Bare classic interactive CLI with `--cli --yolo --accept-hooks`, optional `-m <model>`, followed by readiness-gated brief-pointer delivery. |
| One-shot launch | `hermes --cli -m <model> -z "<prompt>"` runs the prompt with tool use in the launch cwd and exits. |
| Scriptable query | `hermes chat --cli -Q -q "<query>"` runs one query, exits, and prints `session_id:` on completion. |
| Models | `-m <model>`; read `~/.hermes/cache/model_catalog.json`, the installed catalog of provider and model entries, as the authoritative discovery surface. |
| Busy state | Standalone Hermes has no semantic busy-state source under `../../../bin/fm-busy-lib.sh`'s contract, so it classifies unknown. The exact ASCII token `Ctrl+C cancel` inside the running-turn row `⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel` is a delivery-only signature in the shared tmux matcher, never a state source; the row is absent when idle. |
| Exit command | `/exit`, which cleanly prints the session id and exact `hermes --resume <session-id>` command. |
| Interrupt | Single `Ctrl+C`; Hermes prints `⚡ Interrupting agent... (press Ctrl+C again to force exit)`, interrupts an active shell tool with exit 130, and returns to the composer. |
| Steering | Ordinary text followed by Enter works both idle and mid-turn; mid-turn input prints `↪ Redirected current turn: '<instruction>'` and redirects the run after any already-running tool returns. |
| Skill invocation | No separate verified invocation beyond normal composer input; use natural language. |
| Resume | `hermes --resume <session-id>` restores that session, while `hermes --continue` restores the most recent session for the cwd. |
| Autonomy | `--yolo` sets Hermes's bypass mode for every approval prompt; Firstmate also passes `--accept-hooks` so the managed shell hook never opens its first-use consent prompt. |
| Default consent | Safe shell and file tools ran without a dialog on this machine, but default mode retains dangerous-command approval and is not the unattended worker launch. |
| Trust dialog | None on a clean first launch in a fresh pooled worktree. |
| Slash submission | No popup or Enter-settle hazard was observed. |
| Environment marker | `HERMES_INTERACTIVE=1`, set in interactive CLI sessions and inherited by tool subprocesses. |
| Process ancestry | The wrapper runs Python with an argument path ending in `/hermes`; detection recognizes that interpreter argument shape. |
| Composer | Three-row separator form with no placeholder: an upper `────` row, a bare `❯ ` row, and a lower `────` row. |
| Effort | No reasoning-effort flag exists, so requested effort is recorded in task metadata but omitted from launch; `../common/model-and-effort.md` owns the record-and-omit contract. |
| Fresh cwd | A fresh session uses the launch cwd; `--no-restore-cwd` concerns resume and continue, not fresh launches. |

## Readiness-gated start

`../../../bin/fm-spawn.sh` launches Hermes bare because a one-shot prompt exits instead of leaving a steerable worker.
It waits for `Welcome to Hermes Agent!` or the empty `❯` composer, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires the echoed pointer plus either the busy row or returned empty composer, or a nonempty `ctx` percentage, before accepting delivery.
Mid-turn steering does not necessarily cancel an already-running tool immediately, so use the interrupt key when cancellation rather than redirection is required.

The live verification used `hermes --cli -m poolside/laguna-s-2.1:free --yolo` in an isolated pooled worktree with the free Nous model.
The idle composer capture was exactly `───────────────────────────────────────────────────────────────────────────────`, then `❯ `, then the same separator.
The initial prompt returned `HERMES_INITIAL_OK` and the process remained alive at that composer.
Idle steering returned `HERMES_STEER_OK`.
Mid-turn text plus Enter printed the redirect acknowledgement and returned `HERMES_MIDTURN_STEER_OK`.
After `/exit`, `hermes --cli -m poolside/laguna-s-2.1:free --yolo --resume 20260730_161036_e42bfa` returned `HERMES_RESUME_OK`, and a subsequent `--continue` restored the same history.
The version command printed `Hermes Agent v0.19.0 (2026.7.20) · upstream 524ab539`.
With the managed hook installed only in a throwaway Hermes home, `HERMES_HOME=<throwaway> hermes --cli -m poolside/laguna-s-2.1:free --yolo --accept-hooks -z 'Reply with exact token HERMES_HOOK_OK. Do not use tools.'` printed `HERMES_HOOK_OK`, exited zero, and created the registered turn-ended marker.

## Crew turn-end hook and primary limit

Hermes is outside the primary turn-end guard scope.
`../../../docs/turnend-guard.md` owns its separate global hook surface and captain-approved crew wake integration.

Hermes exposes a global `post_llm_call` shell hook in `${HERMES_HOME:-$HOME/.hermes}/config.yaml`.
It fires once after a successful tool-calling turn and does not fire for an interrupted or empty response.
`../../../bin/fm-hermes-turnend-hook.sh` validates YAML through Hermes's own config loader, preserves foreign config bytes, and installs one marker-delimited Firstmate entry plus one silent always-zero hook script and private token registry.
Each Hermes crew worktree receives a gitignored `.fm-hermes-turnend` pointer, and the hook touches that task's `state/<id>.turn-ended` only when the payload event is `post_llm_call` and its `cwd`, pointer, and registry entry all agree.
The hook supplements stale-pane detection for successful turns, while interrupted turns continue to rely on pane-state supervision.

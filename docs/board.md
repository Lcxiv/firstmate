# Fleet board

The fleet board is a captain-facing kanban view of everything under way, generated on demand from live fleet state.
It is a review and decision surface, never a second tracker: the backlog remains the single queue, and firstmate remains the dispatcher.

## Generate

Run `bin/fm-board.sh`.
It renders the canonical fleet snapshot (`bin/fm-fleet-snapshot.sh --json`) plus the hand-maintained effort maps under `data/maps/*.md` into one self-contained HTML file, `$FM_HOME/.lavish/fleet-board.html` by default (`--out` overrides).
The script's header and `--help` own the exact flags and column-routing rules.

## Read

The top band shows one card per effort map: the destination, decided and open decision counts, fog (what is not yet specified), and what is out of scope.
Below it, every backlog row and live task lands in exactly one of five ordered pipeline columns:

1. **Decide** - captain-held items and live tasks parked on an open decision.
2. **Queued** - queued work waiting on dispatch or a blocker.
3. **Building** - in-flight work with no pull request recorded yet, with the assigned worker runtime, model, and effort on the card.
4. **Review** - work whose pull request is recorded and being watched for merge; the card title links the PR.
5. **Landed** - recently completed work.

## Review and decide

Open the board for visual review with `lavish-axi "$FM_HOME/.lavish/fleet-board.html"`.
Every interaction queues a prompt instead of mutating anything:

- Each Decide card carries an approval panel: pick a radio option or write a free-text answer, and one prompt per submitted decision is queued.
- Dragging a card to another column queues a move order for that ticket.

Pressing Send to Agent delivers the queued prompts to firstmate as exact orders; firstmate then applies its normal authority rules before acting on them.
Nothing on the board bypasses merge authority, captain holds, or any other approval boundary.

The board is a static snapshot: regenerate it with `bin/fm-board.sh` (say "refresh the board") rather than editing the generated file.

## Phone glance

A short board or fleet-status request in the authenticated Discord phone channel returns the same five ordered columns as a compact read-only message from `bin/fm-phone-fleet-summary.sh`.
The phone glance reads the canonical fleet snapshot directly and does not include effort maps, decision controls, dragging, or any other review interaction from the Mac board.
It targets one phone screen; when the fleet is too large, it drops Landed entries first, reports omitted counts by column, and invites a narrower column follow-up.
The script header owns the complete omission order and exact length budget.
The glance is generated only on request and is never scheduled, pushed on change, pinned, or edited in place.

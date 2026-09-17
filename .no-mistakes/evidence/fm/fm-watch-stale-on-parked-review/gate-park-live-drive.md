# Live drive of bin/fm-watch.sh at 580f765 - parked no-mistakes gate, FM_POLL=1 FM_STALE_ESCALATE_SECS=2 FM_PAUSE_RESURFACE_SECS=999, pane hash churned 4 times over ~12s

### scenario: opendecision
status log:
    needs-decision: [key=gate-4] two calls above me at the review gate

fake crew state: state: parked · source: run-step · parked at review: 3 finding(s) (ask-user: authority decision)
tmux current command: claude (claude=alive, zsh=dead)
watcher still running after drive: yes
watcher stdout:
    (empty - no wake surfaced)
wake queue (state/.wake-queue):
    (absent - nothing enqueued)
triage log (state/.watch-triage.log):
    [2026-09-17T14:51:35-0700] absorbed stale (parked at a validation gate, awaiting firstmate, age 2s): test:fm-opendecision
pause flag content (.paused-test_fm-opendecision): 'gate-park'
wedge timer (.stale-since-test_fm-opendecision): absent

### scenario: resolved
status log:
    needs-decision: [key=gate-4] two calls above me at the review gate
    resolved [key=gate-4]: answered: one fix round authorized

fake crew state: state: parked · source: run-step · parked at review: 3 finding(s) (ask-user: authority decision)
tmux current command: claude (claude=alive, zsh=dead)
watcher still running after drive: no
watcher stdout:
    stale: test:fm-resolved
wake queue (state/.wake-queue):
    1789681910	1	stale	test:fm-resolved	stale: test:fm-resolved
triage log (state/.watch-triage.log):
    (absent)
pause flag content (.paused-test_fm-resolved): ''
wedge timer (.stale-since-test_fm-resolved): absent

### scenario: deadendpoint
status log:
    needs-decision: [key=gate-4] two calls above me at the review gate

fake crew state: state: parked · source: run-step · parked at review: 3 finding(s) (ask-user: authority decision)
tmux current command: zsh (claude=alive, zsh=dead)
watcher still running after drive: no
watcher stdout:
    stale: test:fm-deadendpoint
wake queue (state/.wake-queue):
    1789681922	1	stale	test:fm-deadendpoint	stale: test:fm-deadendpoint
triage log (state/.watch-triage.log):
    (absent)
pause flag content (.paused-test_fm-deadendpoint): ''
wedge timer (.stale-since-test_fm-deadendpoint): absent


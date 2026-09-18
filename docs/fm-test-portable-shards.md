# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

Measured again on 2026-09-17 in run [35276790325](https://github.com/Lcxiv/firstmate/actions/runs/35276790325): lane 1 ran 186867 ms and lane 2 ran 134760 ms, both far inside the 10-minute job cap.

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

`portable-serial-<k>of<n>` splits the remainder across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

### What the four-shard split actually cost

Four shards with stale hints was not a slow lane; it was an unbalanced one that spent weeks silently eating its own margin.
Measured on 2026-09-17 from the `fm-test-timing-portable-serial-*` artifacts of runs [35252117354](https://github.com/Lcxiv/firstmate/actions/runs/35252117354) and [35276790325](https://github.com/Lcxiv/firstmate/actions/runs/35276790325):

| Shard | Script time, run 35252117354 | Script time, run 35276790325 |
|---|---:|---:|
| `portable-serial-1of4` | 702 s | 732 s |
| `portable-serial-2of4` | 810 s | 882 s |
| `portable-serial-3of4` | 1171 s | 1171 s |
| `portable-serial-4of4` | 905 s | 994 s |

Shard 3 ran 19m31s inside a 20-minute job cap on both runs, while shard 1 cleared it by more than eight minutes.
In [PR 23](https://github.com/Lcxiv/firstmate/pull/23) the same shard reported `FM_TEST_SUMMARY total=37 failed=0 duration_ms=1192794`, every test passing, and the job was still cancelled ten seconds later at 20m02s during artifact upload.
The hints were the cause, not the total: 26 of the 148 serial scripts had no measured hint at all and fell back to the default weight, so the bin packer balanced a fiction while real shards diverged by eight minutes.

### The current split

Refreshed on 2026-09-17 from the same two runs, taking each script's larger of the two measurements so the hints stay conservative.
All 148 serial scripts are now measured, and the whole remainder is 3842719 ms (~64.0 min) of serial work.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of6` | 24 | 640451 ms (~640.5 s) |
| `portable-serial-2of6` | 24 | 640451 ms (~640.5 s) |
| `portable-serial-3of6` | 25 | 640457 ms (~640.5 s) |
| `portable-serial-4of6` | 25 | 640459 ms (~640.5 s) |
| `portable-serial-5of6` | 26 | 640457 ms (~640.5 s) |
| `portable-serial-6of6` | 24 | 640444 ms (~640.4 s) |
| imbalance | | 15 ms |

The single longest script, `tests/fm-watch-triage.test.sh` at 246204 ms, is the floor for any shard count.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default, which sits at the measured per-script mean.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

### The stated margin

Six shards at ~10.7 min are not the guarantee; the guarantee is that the remaining margin is a number someone chose and can watch shrink.

| Bound | Value | What it is |
|---|---:|---|
| measured slowest shard | ~10.7 min | current healthy wall |
| `PORTABLE_SERIAL_SHARD_BUDGET_MS` | 14 min | the chosen budget, enforced by `--enforce-lane-budget` on a shard that completes before the step bound |
| ci.yml run step `timeout-minutes` | 15 min | the hang tripwire for a shard that is still running at 15 minutes |
| ci.yml job `timeout-minutes` | 20 min | last-resort backstop behind both, not expected to be reached |

Each bound owns one case.
The budget is evaluated after the suite finishes, so a shard whose tests complete between 14 and 15 minutes fails naming that cause and pointing here; the budget cannot catch a hang or a shard that is still running at 15 minutes.
A shard that hangs or is still running at 15 minutes is stopped by the run step's 15 minute bound, which fails that step with a timeout cause while the timing artifact upload still runs.
The 20 minute job cap sits behind both and only fires if something outside the run step stalls.
That ordering is the point of the budget: a cancelled job carries no verdict and reads to every operator as a test failure, which sends people debugging a suite that passed.
Each shard also runs with `--budget-markdown "$GITHUB_STEP_SUMMARY"`, so its measured wall, budget, and remaining headroom appear on the run page of every build rather than being reconstructed from a stalled PR.
Roughly 3.3 minutes of the budget is unused today, which is the room the lane has to grow before the split needs revisiting.

### Refreshing the hints

Refresh whenever the serial lane gains scripts, and always when the budget row starts reporting a thin margin.
Download the per-shard timing artifacts from a green CI run, replace the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, update the tables above, and re-check the partition:

```sh
gh run download <run-id> -R Lcxiv/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

If rebalancing alone cannot restore the margin, raise `PORTABLE_SERIAL_SHARDS` rather than the budget or the cap.
Raising either of those hides the trend and buys one release before the next squeeze, which is exactly how the four-shard split arrived here.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-6 | runner budget 14 min; run step `timeout-minutes: 15`; job `timeout-minutes: 20` backstop | Each balanced shard is about 10.7 minutes of measured script time. The runner's enforced budget fails a shard that completes between 14 and 15 minutes naming its cause, the step bound is the tripwire for a hang or a shard still running at 15 minutes (timing artifacts still upload), and the job cap is a last-resort backstop behind both. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 8 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.

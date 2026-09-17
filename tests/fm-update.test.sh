#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - The --after-merge notification entry point reaches that same sweep with no
#     person present: it acts only on a merge of THIS repo, defers rather than
#     moving a home with firstmate work in flight, and leaves a durable re-read
#     nudge behind for each secondmate that advanced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}


# --- notification entry point (--after-merge) ------------------------------
#
# These exercise the automatic path a merged firstmate PR takes: the same
# guarded sweep above, reached with no person present. The world gains a
# GitHub-shaped origin URL so the identity comparison under test is the real
# one; git still fetches from the local bare repo through insteadOf, so nothing
# here touches the network.

FM_PR_URL_SELF="https://github.com/acme/firstmate/pull/7"
FM_PR_URL_OTHER="https://github.com/acme/some-project/pull/7"

# Give the world's firstmate clone a GitHub origin URL that resolves back to the
# local bare origin, so fm-update.sh compares a real remote identity.
name_origin_as_github() {
  local w=$1
  git -C "$w/main" remote set-url origin https://github.com/acme/firstmate.git
  git -C "$w/main" config "url.$w/origin.git.insteadOf" https://github.com/acme/firstmate.git
  git -C "$w/main" fetch -q origin
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
}

# A tmux stand-in whose panes exist only while FM_FAKE_LIVE_PANES names them, so
# a test can make one task's endpoint present and then take it away.
fake_tmux_liveness() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    target=
    prev=
    for a in "$@"; do
      [ "$prev" = "-t" ] && target=$a
      prev=$a
    done
    case " ${FM_FAKE_LIVE_PANES:-} " in
      *" $target "*) printf '%%0\n'; exit 0 ;;
    esac
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# Record an ordinary (non-secondmate) task working in <worktree>.
add_task() {
  local w=$1 id=$2 worktree=$3
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'backend=tmux\n'
    printf 'worktree=%s\n' "$worktree"
  } > "$w/home/state/$id.meta"
}

run_after_merge() {
  local w=$1 url=$2 fakebin
  fakebin=$(fm_fakebin "$w")
  fake_tmux_liveness "$fakebin"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --after-merge "$url" 2>&1
}

run_retry_after_merge() {
  local w=$1 fakebin
  fakebin=$(fm_fakebin "$w")
  fake_tmux_liveness "$fakebin"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --retry-after-merge 2>&1
}

# --- T12: happy path - a merged firstmate PR updates the whole tree --------
test_after_merge_updates_tree() {
  local w out
  w=$(new_world t12)
  name_origin_as_github "$w"
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_after_merge "$w" "$FM_PR_URL_SELF")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded with no manual invocation"
  assert_contains "$out" "secondmate sm1: updated " "registered secondmate fast-forwarded too"
  assert_contains "$out" "reread-firstmate: yes" "instruction change is reported to the caller"
  assert_contains "$out" "after-merge: completed" "the notification update ran"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main after the notification update"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main after the notification update"
  [ ! -f "$w/home/state/.auto-update-pending" ] \
    || fail "a completed notification update left a pending record behind"
  pass "T12 merged firstmate PR fast-forwards this home and its secondmate unattended"
}

# --- T13: the re-read nudge is durably queued for the advanced secondmate --
# The nudge must survive a busy agent, so the observable is the durable steering
# record fm-send writes into the secondmate's inbox, not a keystroke: that
# record is what an agent mid-turn still reads afterwards. A delivered nudge
# also clears its bounded retry marker, so a failed send stays distinguishable
# from a delivered one.
test_after_merge_nudges_secondmate() {
  local w out
  w=$(new_world t13)
  name_origin_as_github "$w"
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_after_merge "$w" "$FM_PR_URL_SELF")

  assert_contains "$out" "nudge-secondmates: fm-sm1" "the advanced secondmate is on the nudge list"
  grep -rq 're-read your AGENTS.md' "$w/home/state/sm1.inbox" 2>/dev/null \
    || fail "the re-read nudge left no durable steering record for the advanced secondmate"
  [ ! -f "$w/home/state/.secondmate-nudge-pending/sm1.pending" ] \
    || fail "a delivered nudge left its retry marker behind"
  pass "T13 the re-read nudge follows the update as a durable steering record"
}

# --- T14: a merge in another project never touches a firstmate home -------
test_after_merge_ignores_other_projects() {
  local w out before
  w=$(new_world t14)
  name_origin_as_github "$w"
  add_sm "$w" sm1
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_after_merge "$w" "$FM_PR_URL_OTHER")

  assert_contains "$out" "is not the firstmate repository" "a foreign merge is reported as a no-op"
  assert_not_contains "$out" "after-merge: completed" "a foreign merge did not run the update"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "a merge in another project fast-forwarded the firstmate home"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "a merge in another project fast-forwarded a secondmate home"
  [ ! -f "$w/home/state/.auto-update-pending" ] \
    || fail "a foreign merge left a pending record a later retry could act on"
  pass "T14 a merge outside the firstmate repository triggers no fast-forward"
}

# --- T15: a dirty home is skipped and reported, never forced --------------
test_after_merge_skips_dirty_home() {
  local w out before
  w=$(new_world t15)
  name_origin_as_github "$w"
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/main/AGENTS.md"
  printf 'secondmate local edit\n' >> "$w/sm1/README.md"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_after_merge "$w" "$FM_PR_URL_SELF")

  assert_contains "$out" "firstmate: skipped: dirty working tree" "the dirty home is skipped by name"
  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "the dirty secondmate is skipped by name"
  assert_contains "$out" "reread-firstmate: no" "a skipped home reports no instruction change"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "dirty firstmate HEAD moved"
  grep -q 'uncommitted local edit' "$w/main/AGENTS.md" || fail "dirty firstmate edit was discarded"
  grep -q 'secondmate local edit' "$w/sm1/README.md" || fail "dirty secondmate edit was discarded"
  pass "T15 a dirty home is skipped and reported, its local edits preserved"
}

# --- T16: a diverged home is skipped and its unlanded commit preserved ----
test_after_merge_skips_diverged_home() {
  local w out before sm_before
  w=$(new_world t16)
  name_origin_as_github "$w"
  add_sm "$w" sm1
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm sm-local-work
  sm_before=$(git -C "$w/sm1" rev-parse HEAD)
  printf 'main fork work\n' > "$w/main/README.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm main-local-work
  before=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_after_merge "$w" "$FM_PR_URL_SELF")

  assert_contains "$out" "firstmate: skipped: diverged from origin/main" "the diverged home is skipped by name"
  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "the diverged secondmate is skipped by name"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "diverged firstmate HEAD moved (unlanded work at risk)"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$sm_before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T16 a diverged home is skipped and reported, its unlanded commit preserved"
}

# --- T17: work in flight defers the update, then the retry completes it ----
test_after_merge_defers_for_work_in_flight() {
  local w out before
  w=$(new_world t17)
  name_origin_as_github "$w"
  add_sm "$w" sm1
  # A crewmate mid-task in a worktree of THIS repo, with a live endpoint.
  git -C "$w/main" worktree add -q -b fm/task "$w/task" main
  add_task "$w" task1 "$w/task"
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(FM_FAKE_LIVE_PANES="main:fm-task1" run_after_merge "$w" "$FM_PR_URL_SELF")

  assert_contains "$out" "after-merge: deferred" "the update deferred while work was in flight"
  assert_contains "$out" "task1" "the deferral names the work it waited for"
  assert_not_contains "$out" "after-merge: completed" "a deferred update did not fast-forward anything"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "the home was fast-forwarded while work was in flight"
  [ -f "$w/home/state/.auto-update-pending" ] \
    || fail "the deferred notification was not recorded for retry"

  # The worker finishes: its endpoint is gone, so the retry completes the update.
  out=$(run_retry_after_merge "$w")

  assert_contains "$out" "firstmate: updated " "the retry fast-forwarded once the home was quiet"
  assert_contains "$out" "after-merge: completed" "the retry completed the deferred update"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "the retry did not land the update"
  [ ! -f "$w/home/state/.auto-update-pending" ] \
    || fail "a completed retry left its pending record behind"
  pass "T17 work in flight defers the update; the retry lands it once the home is quiet"
}

# --- T18: the deferral is scoped, not vacuous -----------------------------
# A live worker in an UNRELATED repository shares nothing with this checkout, so
# it must not hold the update back. Without this, T17 would pass equally well
# for a deferral that simply blocks on any live task at all.
test_after_merge_ignores_unrelated_live_work() {
  local w out
  w=$(new_world t18)
  name_origin_as_github "$w"
  git init -q "$w/elsewhere"
  ( cd "$w/elsewhere" && printf 'x\n' > f && git add -A && git commit -qm c1 ) >/dev/null
  add_task "$w" task1 "$w/elsewhere"
  bump_origin "$w" instr

  out=$(FM_FAKE_LIVE_PANES="main:fm-task1" run_after_merge "$w" "$FM_PR_URL_SELF")

  assert_not_contains "$out" "after-merge: deferred" "an unrelated live worker wrongly deferred the update"
  assert_contains "$out" "after-merge: completed" "the update proceeded past an unrelated live worker"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "the update did not land despite only unrelated work being live"
  pass "T18 a live worker in another repository does not defer the update"
}

# --- T19: a home leased at a detached HEAD updates itself -----------------
# A secondmate home is leased detached on the default branch by design, so its
# own repo target must fast-forward rather than be skipped for not sitting on a
# named branch - otherwise the merge never reaches the home that observed it.
test_after_merge_updates_leased_secondmate_home() {
  local w out
  w=$(new_world t19)
  name_origin_as_github "$w"
  git -C "$w/main" checkout -q --detach HEAD
  printf 'fm-second\n' > "$w/main/.fm-secondmate-home"
  bump_origin "$w" instr

  out=$(run_after_merge "$w" "$FM_PR_URL_SELF")

  assert_contains "$out" "firstmate: updated " "the leased home fast-forwarded its own detached HEAD"
  assert_contains "$out" "after-merge: completed" "the leased home completed the update"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "the leased secondmate home did not reach origin/main"
  git -C "$w/main" symbolic-ref -q HEAD >/dev/null \
    && fail "the leased secondmate home is no longer detached"
  pass "T19 a home leased at a detached HEAD fast-forwards itself"
}

# --- T20: the watcher is what triggers all of this ------------------------
# Everything above drives bin/fm-update.sh directly. This one proves the wire:
# a real bin/fm-watch.sh, given a deferred notification this home recorded
# earlier, completes the update on its own check cadence, queues the durable
# re-read wake, and delivers it so the running firstmate actually acts on the
# new instructions. Without this the entry point could be perfect and never
# reached.
#
# The world's firstmate repo carries a real committed bin/, because the watcher
# runs the updater out of the repo it is updating.
new_world_with_real_bin() {
  local name=$1 w
  w=$(new_world "$name")
  rm -rf "$w/seed/bin"
  cp -R "$ROOT/bin" "$w/seed/bin"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm real-bin
  git -C "$w/seed" push -q origin main
  git -C "$w/main" fetch -q origin
  git -C "$w/main" merge --ff-only -q origin/main
  printf '%s\n' "$w"
}

test_watcher_completes_deferred_update() {
  local w fakebin out pid i=0 queue
  w=$(new_world_with_real_bin t20)
  name_origin_as_github "$w"
  fakebin=$(fm_fakebin "$w")
  fake_tmux_liveness "$fakebin"
  # The notification this home deferred while it was busy.
  printf '%s\n' "$FM_PR_URL_SELF" > "$w/home/state/.auto-update-pending"
  bump_origin "$w" instr

  out="$w/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$w/home/state" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" FM_POLL=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    FM_SIGNAL_GRACE=1 "$w/main/bin/fm-watch.sh" > "$out" 2>"$w/watch.err" &
  pid=$!

  # The watcher exits on the wake it delivers, so wait for it to finish.
  while [ "$i" -lt 600 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher never delivered the self-update wake (output: $(cat "$out"))"
  fi
  wait "$pid" 2>/dev/null || true

  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "the watcher did not complete the deferred fast-forward"
  [ ! -f "$w/home/state/.auto-update-pending" ] \
    || fail "the watcher left the pending record behind after completing the update"
  queue="$w/home/state/.wake-queue"
  grep -q 're-read AGENTS.md' "$queue" 2>/dev/null \
    || fail "no durable re-read wake was queued (queue: $(cat "$queue" 2>/dev/null))"
  grep -q 're-read AGENTS.md' "$out" \
    || fail "the watcher queued the re-read wake but never delivered it"
  pass "T20 the watcher completes a deferred self-update and wakes firstmate to re-read"
}

# --- T21: a home that could not be updated reaches firstmate --------------
# Skipping is a normal outcome, but only firstmate can clear its cause (its own
# local edits, its own un-landed commits). A skip that only ever reached the
# watcher's own log would satisfy "never forced" while quietly stranding a home,
# so the watcher must queue it by name and reason.
test_watcher_reports_skipped_home() {
  local w fakebin out pid i=0 queue
  w=$(new_world_with_real_bin t21)
  name_origin_as_github "$w"
  fakebin=$(fm_fakebin "$w")
  fake_tmux_liveness "$fakebin"
  printf '%s\n' "$FM_PR_URL_SELF" > "$w/home/state/.auto-update-pending"
  bump_origin "$w" instr
  # The home carries its own un-landed edit, so it cannot be fast-forwarded.
  printf 'uncommitted local edit\n' >> "$w/main/README.md"

  out="$w/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$w/home/state" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" FM_POLL=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    FM_SIGNAL_GRACE=1 "$w/main/bin/fm-watch.sh" > "$out" 2>"$w/watch.err" &
  pid=$!
  while [ "$i" -lt 600 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher never reported the skipped home (output: $(cat "$out"))"
  fi
  wait "$pid" 2>/dev/null || true

  queue="$w/home/state/.wake-queue"
  grep -q 'left targets as-is' "$queue" 2>/dev/null \
    || fail "the skipped home was not queued for firstmate (queue: $(cat "$queue" 2>/dev/null))"
  grep -q 'dirty working tree' "$queue" 2>/dev/null \
    || fail "the queued report does not carry the skip reason"
  grep -q 'firstmate' "$queue" 2>/dev/null \
    || fail "the queued report does not name the skipped target"
  grep -q 'uncommitted local edit' "$w/main/README.md" \
    || fail "the skipped home's local edit was discarded"
  pass "T21 a home that could not be updated is reported to firstmate by name and reason"
}

# --- T22: a foreign merge does not cancel an update this home still owes ---
# The no-op for another project's merge must be a true no-op. If it also retired
# the pending record, any unrelated project merging first would silently cancel
# a firstmate update this home had deferred and still owes.
test_foreign_merge_preserves_pending_update() {
  local w out
  w=$(new_world t22)
  name_origin_as_github "$w"
  bump_origin "$w" instr
  printf '%s\n' "$FM_PR_URL_SELF" > "$w/home/state/.auto-update-pending"

  out=$(run_after_merge "$w" "$FM_PR_URL_OTHER")

  assert_contains "$out" "is not the firstmate repository" "the foreign merge is still a no-op"
  [ -f "$w/home/state/.auto-update-pending" ] \
    || fail "a foreign merge cancelled the firstmate update this home still owed"

  # The owed update is still reachable and still lands.
  out=$(run_retry_after_merge "$w")
  assert_contains "$out" "after-merge: completed" "the preserved update still completes"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "the preserved update did not land"
  pass "T22 a merge in another project leaves a deferred firstmate update owed"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_after_merge_updates_tree
test_after_merge_nudges_secondmate
test_after_merge_ignores_other_projects
test_after_merge_skips_dirty_home
test_after_merge_skips_diverged_home
test_after_merge_defers_for_work_in_flight
test_after_merge_ignores_unrelated_live_work
test_after_merge_updates_leased_secondmate_home
test_watcher_completes_deferred_update
test_foreign_merge_preserves_pending_update
test_watcher_reports_skipped_home

echo "# all fm-update tests passed"

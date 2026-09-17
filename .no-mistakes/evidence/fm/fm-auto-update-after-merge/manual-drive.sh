#!/usr/bin/env bash
# Manual end-to-end drive of bin/fm-update.sh --after-merge / --retry-after-merge
# and the bin/fm-watch.sh retry sweep against sandboxed git worlds.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
UPDATE="$ROOT/bin/fm-update.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-update-manual)
SELF_URL="https://github.com/acme/firstmate/pull/7"
OTHER_URL="https://github.com/acme/some-project/pull/7"

hr() { printf '\n===== %s =====\n' "$*"; }
heads() { # world label...
  local w=$1; shift
  for d in "$@"; do
    printf '  %-6s HEAD=%s  origin/main=%s\n' "$d" "$(git -C "$w/$d" rev-parse --short HEAD)" "$(git -C "$w/main" rev-parse --short origin/main)"
  done
}
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data"; touch "$w/home/state/.last-watcher-beat"
  git init -q --bare "$w/origin.git"; git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"; printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"; printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A; git -C "$w/seed" commit -qm c1; git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-url origin https://github.com/acme/firstmate.git
  git -C "$w/main" config "url.$w/origin.git.insteadOf" https://github.com/acme/firstmate.git
  git -C "$w/main" fetch -q origin; git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  local fb; fb=$(fm_fakebin "$w")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in display-message) t=; p=; for a in "$@"; do [ "$p" = -t ] && t=$a; p=$a; done
  case " ${FM_FAKE_LIVE_PANES:-} " in *" $t "*) echo '%0'; exit 0;; esac; exit 1;; esac; exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$w"
}
add_sm() { local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  printf 'window=main:fm-%s\nkind=secondmate\nhome=%s/%s\n' "$id" "$w" "$id" > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}
add_task() { printf 'window=main:fm-%s\nbackend=tmux\nworktree=%s\n' "$2" "$3" > "$1/home/state/$2.meta"; }
bump() { local w=$1
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'v2\n' > "$w/seed/AGENTS.md"; printf 'r2\n' >> "$w/seed/README.md"
  git -C "$w/seed" add -A; git -C "$w/seed" commit -qm bump; git -C "$w/seed" push -q origin main; }
run() { local w=$1; shift
  PATH="$w/fakebin:$PATH" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" "$@" 2>&1; echo "  [exit=$?]"; }
pending() { printf '  pending record: '; if [ -f "$1/home/state/.auto-update-pending" ]; then tr '\n' '|' < "$1/home/state/.auto-update-pending"; echo; else echo '(absent)'; fi; }
no_force() { local w=$1; shift
  for d in "$@"; do
    printf '  %-6s stash entries=%s  reflog reset/rebase entries=%s\n' "$d" "$(git -C "$w/$d" stash list | wc -l | tr -d ' ')" "$(git -C "$w/$d" reflog | grep -ciE 'reset|rebase' )"
  done; }

hr "S1 happy path: merged firstmate PR fast-forwards this home + secondmate, nudges, no pending record left"
w=$(new_world s1); add_sm "$w" sm1; bump "$w"
echo "before:"; heads "$w" main sm1
run "$w" --after-merge "$SELF_URL"
echo "after:"; heads "$w" main sm1; pending "$w"
echo "  AGENTS.md in main: $(cat "$w/main/AGENTS.md")  in sm1: $(cat "$w/sm1/AGENTS.md")"
echo "  sm1 inbox record:"; sed 's/^/    /' "$w"/home/state/sm1.inbox/* 2>/dev/null | head -5
echo "  main branch parents of HEAD: $(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ') (2 = single-parent, not a merge commit)"

hr "S2 foreign project merge: no-op, and a deferred firstmate update already owed is preserved"
w=$(new_world s2); add_sm "$w" sm1; bump "$w"
printf '%s\nattempts=0\n' "$SELF_URL" > "$w/home/state/.auto-update-pending"
echo "before:"; heads "$w" main sm1; pending "$w"
run "$w" --after-merge "$OTHER_URL"
echo "after:"; heads "$w" main sm1; pending "$w"

hr "S3 dirty secondmate home: skipped and reported, local edit preserved, never stashed/reset"
w=$(new_world s3); add_sm "$w" sm1; bump "$w"
printf 'LOCAL EDIT\n' >> "$w/sm1/README.md"
run "$w" --after-merge "$SELF_URL"
heads "$w" main sm1
echo "  sm1 README tail: $(tail -1 "$w/sm1/README.md")"; no_force "$w" main sm1

hr "S4 diverged secondmate home: skipped and reported, unlanded commit preserved"
w=$(new_world s4); add_sm "$w" sm1; bump "$w"
printf 'unlanded\n' > "$w/sm1/UNLANDED.md"; git -C "$w/sm1" add -A; git -C "$w/sm1" commit -qm unlanded
local_commit=$(git -C "$w/sm1" rev-parse --short HEAD)
run "$w" --after-merge "$SELF_URL"
heads "$w" main sm1
echo "  sm1 HEAD still the unlanded commit $local_commit: $([ "$(git -C "$w/sm1" rev-parse --short HEAD)" = "$local_commit" ] && echo yes || echo NO)"; no_force "$w" main sm1

hr "S5 unrelated live task in a worktree of THIS repo defers; retry lands it once quiet"
w=$(new_world s5); bump "$w"
git -C "$w/main" worktree add -q --detach "$w/wt-other" main; add_task "$w" other "$w/wt-other"
echo "-- notification while task 'other' is live:"
FM_FAKE_LIVE_PANES="main:fm-other" run "$w" --after-merge "$SELF_URL"
heads "$w" main; pending "$w"
echo "-- retry while still live (attempts must not grow):"
FM_FAKE_LIVE_PANES="main:fm-other" run "$w" --retry-after-merge
pending "$w"
echo "-- retry after the task is gone:"
run "$w" --retry-after-merge
heads "$w" main; pending "$w"

hr "S6 (adversarial) the merged PR's OWN task being live must NOT defer"
w=$(new_world s6); bump "$w"
git -C "$w/main" worktree add -q --detach "$w/wt-self" main; add_task "$w" self "$w/wt-self"
printf 'pr=%s\n' "$SELF_URL" >> "$w/home/state/self.meta"
FM_FAKE_LIVE_PANES="main:fm-self" run "$w" --after-merge "$SELF_URL"
heads "$w" main; pending "$w"

hr "S7 (adversarial) live worker in an UNRELATED repository does not defer"
w=$(new_world s7); bump "$w"
git init -q "$w/unrelated"; git -C "$w/unrelated" commit -q --allow-empty -m x
add_task "$w" foreign "$w/unrelated"
FM_FAKE_LIVE_PANES="main:fm-foreign" run "$w" --after-merge "$SELF_URL"
heads "$w" main; pending "$w"

hr "S8 (adversarial) fetch hangs: run killed at the time bound leaves the pending record with attempts=1"
w=$(new_world s8); bump "$w"
cat > "$w/fakebin/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = fetch ] && sleep 60; done
exec /usr/bin/git "\$@"
SH
chmod +x "$w/fakebin/git"
. "$ROOT/bin/fm-timeout-lib.sh"
PATH="$w/fakebin:$PATH" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" fm_run_timed 3 "$UPDATE" --after-merge "$SELF_URL" 2>&1; echo "  [exit=$? ; 124 = time bound]"
pending "$w"; heads "$w" main
echo "-- retry with a working git lands it:"
rm "$w/fakebin/git"; run "$w" --retry-after-merge | tail -3; pending "$w"; heads "$w" main

hr "S9 home leased as a secondmate (detached HEAD + marker) updates itself"
w=$(new_world s9); git -C "$w/main" checkout -q --detach; printf 'x\n' > "$w/main/.fm-secondmate-home"; bump "$w"
echo "before: $(git -C "$w/main" symbolic-ref -q HEAD || echo 'detached HEAD')"; heads "$w" main
run "$w" --after-merge "$SELF_URL"; heads "$w" main

hr "S10 real watcher: retries a pending record on its check sweep, wakes firstmate to re-read"
w=$(new_world s10); rm -rf "$w/seed/bin"; cp -R "$ROOT/bin" "$w/seed/bin"
git -C "$w/seed" add -A; git -C "$w/seed" commit -qm real-bin; git -C "$w/seed" push -q origin main
git -C "$w/main" fetch -q origin; git -C "$w/main" merge --ff-only -q origin/main
printf '%s\nattempts=0\n' "$SELF_URL" > "$w/home/state/.auto-update-pending"; bump "$w"
echo "before:"; heads "$w" main; pending "$w"
PATH="$w/fakebin:$PATH" FM_STATE_OVERRIDE="$w/home/state" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
  FM_POLL=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 "$w/main/bin/fm-watch.sh" > "$w/watch.out" 2>"$w/watch.err" &
pid=$!; i=0; while [ $i -lt 600 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "watcher stdout:"; sed 's/^/  | /' "$w/watch.out"
echo "wake queue:"; sed 's/^/  | /' "$w/home/state/.wake-queue" 2>/dev/null
echo "after:"; heads "$w" main; pending "$w"

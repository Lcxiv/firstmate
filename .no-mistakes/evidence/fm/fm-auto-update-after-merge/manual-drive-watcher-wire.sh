#!/usr/bin/env bash
# S11: the real watcher observes a merged FIRSTMATE PR poll (fake gh answers MERGED)
# and fast-forwards this home + secondmate before delivering its merge wake.
# S12: the real watcher observes a merged poll for a NON-firstmate project: no fast-forward.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-update-wire)
hr() { printf '\n===== %s =====\n' "$*"; }
heads() { local w=$1; shift; for d in "$@"; do printf '  %-6s HEAD=%s\n' "$d" "$(git -C "$w/$d" rev-parse --short HEAD)"; done; echo "  origin main=$(git -C "$w/origin.git" rev-parse --short main)"; }
world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data"; touch "$w/home/state/.last-watcher-beat"
  git init -q --bare "$w/origin.git"; git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"; mkdir -p "$w/seed/.agents/skills"; printf 's1\n' > "$w/seed/.agents/skills/note.md"
  cp -R "$ROOT/bin" "$w/seed/bin"
  git -C "$w/seed" add -A; git -C "$w/seed" commit -qm c1; git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-url origin https://github.com/acme/firstmate.git
  git -C "$w/main" config "url.$w/origin.git.insteadOf" https://github.com/acme/firstmate.git
  git -C "$w/main" fetch -q origin; git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  # secondmate home
  git -C "$w/main" worktree add -q --detach "$w/sm1" main
  printf 'window=main:fm-sm1\nkind=secondmate\nhome=%s/sm1\n' "$w" > "$w/home/state/sm1.meta"
  printf 'sm1\n' > "$w/sm1/.fm-secondmate-home"
  # the task whose PR is about to merge, in a worktree of THIS repo, live
  git -C "$w/main" worktree add -q --detach "$w/wt-t1" main
  printf 'window=main:fm-t1\nbackend=tmux\nworktree=%s/wt-t1\n' "$w" > "$w/home/state/t1.meta"
  chmod 600 "$w/home/state/t1.meta"
  local fb; fb=$(fm_fakebin "$w")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in display-message) echo '%0'; exit 0;; esac; exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in *"--json state"*) echo MERGED;; *"--json headRefOid"*) exit 1;; esac; exit 0
SH
  chmod +x "$fb/tmux" "$fb/gh"
  # advance origin with an instruction change (the "merged PR")
  printf 'v2\n' > "$w/seed/AGENTS.md"; git -C "$w/seed" commit -qam merged-pr; git -C "$w/seed" push -q origin main
  printf '%s\n' "$w"
}
drive() { local w=$1 url=$2
  echo "-- arm the merge poll for task t1 ($url):"
  PATH="$w/fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" "$w/main/bin/fm-pr-check.sh" t1 "$url" 2>&1 | sed 's/^/  /'
  echo "  t1.meta pr= line: $(grep '^pr=' "$w/home/state/t1.meta")"
  echo "before:"; heads "$w" main sm1
  PATH="$w/fakebin:$PATH" FM_STATE_OVERRIDE="$w/home/state" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_POLL=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 "$w/main/bin/fm-watch.sh" > "$w/watch.out" 2>"$w/watch.err" &
  pid=$!; i=0; while [ $i -lt 600 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  echo "watcher stdout:"; sed 's/^/  | /' "$w/watch.out"
  echo "wake queue:"; sed 's/^/  | /' "$w/home/state/.wake-queue" 2>/dev/null
  echo "triage log (state/.watch-triage.log):"; sed "s/^/  | /" "$w/home/state/.watch-triage.log" 2>/dev/null; echo "  (end of triage log)"
  echo "after:"; heads "$w" main sm1
  printf '  pending record: '; [ -f "$w/home/state/.auto-update-pending" ] && cat "$w/home/state/.auto-update-pending" || echo '(absent)'
  echo "  AGENTS.md main=$(cat "$w/main/AGENTS.md") sm1=$(cat "$w/sm1/AGENTS.md")"
  echo "  sm1 inbox: $(grep -rho 'please re-read your AGENTS.md[^.]*' "$w"/home/state/sm1.inbox 2>/dev/null | head -1)"
}
hr "S11 real watcher: merged FIRSTMATE PR poll fires the fleet fast-forward (merged task t1 is live and must not defer)"
drive "$(world s11)" "https://github.com/acme/firstmate/pull/7"
hr "S12 real watcher: merged poll for a NON-firstmate project leaves every home as-is"
drive "$(world s12)" "https://github.com/acme/some-project/pull/9"

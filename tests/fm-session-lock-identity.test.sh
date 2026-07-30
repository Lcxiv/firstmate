#!/usr/bin/env bash
# Behavior tests for the shared session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# The ancestry walk and the holder-liveness check must agree about which
# processes are a verified harness SESSION. Claude Code runs a shared background
# daemon plus a pool of daemon-owned workers, all named "claude", so these tests
# drive both predicates through a fake ps whose process table reproduces the
# real shapes observed live on Claude Code 2.1.220. No real process, harness, or
# fleet state is involved: a fake ps and a fake kill are the whole fixture.
# shellcheck disable=SC2016 # single quotes are deliberate: the sourced lib, not this shell, expands nothing here

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-identity)
BASE_PATH="$PATH"

# One pid-keyed process table covering every shape below, plus a catch-all for
# the real pid of the shell running the walk. FM_TEST_ENTRY names the pid the
# walk enters the table at, so a single fixture serves every ancestry.
#
#   200 claude bg-spare        daemon-owned pooled worker (process title form)
#   300 claude bg-pty-host     daemon-owned pty host (process title form)
#   400 claude daemon run --origin transient
#   401 claude daemon run --origin service
#   402 claude daemon run      (no origin at all)
#   500 claude --dangerously-skip-permissions   inner session process
#   600 claude                 outer session process, the lock owner
#   700 -zsh                   the non-harness gap above the session
#   800 <...>/claude/versions/2.1.220 --session-id ...   versioned session exe
#   900 <...>/MacOS/claude --bg-pty-host <...>/pty/<session>.sock   pty host
#  1000 claude -p "... daemon run ..."   a session whose PROMPT says daemon
#  1100 <...>/claude/helper    unrelated program under a directory named claude
make_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  200:comm=) printf '%s\n' 'claude bg-spare' ;;
  200:args=) printf '%s\n' 'claude bg-spare --bg-spare /tmp/cc-daemon-501/468fd9d1/spare/f2e86b8a.claim.sock' ;;
  200:ppid=) printf '%s\n' 300 ;;
  300:comm=) printf '%s\n' 'claude bg-pty-host' ;;
  300:args=) printf '%s\n' 'claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/468fd9d1/spare/f2e86b8a.pty.sock 200 50 -- /opt/claude/versions/2.1.220 --bg-spare /tmp/cc-daemon-501/468fd9d1/spare/f2e86b8a.claim.sock' ;;
  300:ppid=) printf '%s\n' "${FM_TEST_PTYHOST_PPID:-400}" ;;
  400:comm=) printf '%s\n' '/opt/local/bin/claude' ;;
  400:args=) printf '%s\n' '/opt/local/bin/claude daemon run --origin transient --spawned-by {"label":"claude","cwd":"/tmp/x","pid":12919}' ;;
  400:ppid=) printf '%s\n' 1 ;;
  401:comm=) printf '%s\n' '/opt/local/bin/claude' ;;
  401:args=) printf '%s\n' '/opt/local/bin/claude daemon run --json-path /tmp/d.json --log-file /tmp/d.log --origin service' ;;
  401:ppid=) printf '%s\n' 1 ;;
  402:comm=) printf '%s\n' '/opt/local/bin/claude' ;;
  402:args=) printf '%s\n' '/opt/local/bin/claude daemon run' ;;
  402:ppid=) printf '%s\n' 1 ;;
  500:comm=) printf '%s\n' '/opt/local/bin/claude' ;;
  500:args=) printf '%s\n' 'claude --dangerously-skip-permissions --effort high' ;;
  500:ppid=) printf '%s\n' 600 ;;
  600:comm=) printf '%s\n' '/opt/local/bin/claude' ;;
  600:args=) printf '%s\n' 'claude' ;;
  600:ppid=) printf '%s\n' 700 ;;
  700:comm=) printf '%s\n' '-zsh' ;;
  700:args=) printf '%s\n' '-zsh' ;;
  700:ppid=) printf '%s\n' 1 ;;
  800:comm=) printf '%s\n' '/opt/share/claude/versions/2.1.220' ;;
  800:args=) printf '%s\n' '/opt/share/claude/versions/2.1.220 --session-id 42ed4142-d9a4-42d4-9f67-c88aaed3dd49 --fork-session --resume /tmp/p/42ed4142.jsonl' ;;
  800:ppid=) printf '%s\n' 900 ;;
  900:comm=) printf '%s\n' '/opt/share/claude/ClaudeCode.app/Contents/MacOS/claude' ;;
  900:args=) printf '%s\n' '/opt/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/cc-daemon-501/468fd9d1/pty/42ed4142.sock 186 61 -- /opt/share/claude/versions/2.1.220' ;;
  900:ppid=) printf '%s\n' 400 ;;
  1000:comm=) printf '%s\n' '/opt/local/bin/claude' ;;
  1000:args=) printf '%s\n' 'claude -p Restart the daemon run loop and report' ;;
  1000:ppid=) printf '%s\n' 1 ;;
  1100:comm=) printf '%s\n' '/opt/share/claude/helper' ;;
  1100:args=) printf '%s\n' 'helper --serve' ;;
  1100:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' "${FM_TEST_ENTRY:-600}" ;;
esac
SH
  chmod +x "$fakebin/ps"
}

# Resolve the ancestry pid for an entry point. Echoes the pid, or nothing on the
# fail-closed path; the caller inspects both the output and the exit status.
# $3 re-parents the pty host, which is what distinguishes a daemon-owned pool
# (its parent is the daemon) from a pool nested inside a session.
ancestry_for() {
  local fakebin=$1 entry=$2 ptyhost_ppid=${3:-400}
  PATH="$fakebin:$BASE_PATH" FM_TEST_ENTRY="$entry" FM_TEST_PTYHOST_PPID="$ptyhost_ppid" \
    bash -c '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT"
}

# True when the lib treats $2 as a live harness session holder. kill is stubbed
# so a fictional pid is always "running".
alive_for() {
  local fakebin=$1 pid=$2
  PATH="$fakebin:$BASE_PATH" \
    bash -c '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive "$1"' \
    "$ROOT" "$pid"
}

# ---------------------------------------------------------------------------
# A) the shared background daemon is never a session identity
# ---------------------------------------------------------------------------

test_pooled_worker_ancestry_never_resolves_the_daemon() {
  local fakebin got status
  fakebin=$(fm_fakebin "$TMP_ROOT/pooled-worker")
  make_ps "$fakebin"
  # The exact failing shape: a Claude Code hook or tool call hosted by a
  # daemon-owned pooled spare. Every process above it - bg-spare, bg-pty-host,
  # the daemon - is claude-named, and the daemon is parented to init, so the
  # session that claimed the spare is nowhere in this ancestry. Resolving the
  # daemon here handed one shared, session-outliving pid to every session of the
  # user as its "own" identity.
  got=$(ancestry_for "$fakebin" 200); status=$?
  [ -z "$got" ] || fail "pooled-worker ancestry resolved '$got'; the shared daemon is not a session identity"
  expect_code 1 "$status" "pooled-worker ancestry must fail closed rather than resolve shared infrastructure"
  pass "session-lock identity: a daemon-owned pooled worker resolves no session and fails closed"
}

test_daemon_identity_is_not_shared_across_sessions() {
  local fakebin a b
  fakebin=$(fm_fakebin "$TMP_ROOT/shared-identity")
  make_ps "$fakebin"
  # Two different sessions' pooled workers previously resolved the same daemon
  # pid, so each session verified ownership of a lock the other had written and
  # both could arm the same home. Neither may resolve an identity now.
  a=$(ancestry_for "$fakebin" 200 400 || true)
  b=$(ancestry_for "$fakebin" 200 401 || true)
  if [ -n "$a" ] || [ -n "$b" ]; then
    fail "pooled workers resolved shareable identities a='$a' b='$b'"
  fi
  pass "session-lock identity: pooled workers of different sessions share no resolvable identity"
}

test_every_daemon_origin_is_rejected() {
  local fakebin pid
  fakebin=$(fm_fakebin "$TMP_ROOT/daemon-origins")
  make_ps "$fakebin"
  # --origin transient is only one way the daemon starts. The rejection keys on
  # the "daemon" subcommand so a service-installed daemon, an origin this
  # version does not know, and a hand-run "claude daemon run" are all rejected.
  for pid in 400 401 402; do
    if alive_for "$fakebin" "$pid"; then
      fail "daemon pid $pid was accepted as a live session holder"
    fi
    if [ -n "$(ancestry_for "$fakebin" "$pid" || true)" ]; then
      fail "daemon pid $pid was accepted as an ancestry identity"
    fi
  done
  pass "session-lock identity: the daemon is rejected by subcommand, not by one --origin value"
}

test_pooled_workers_are_not_live_holders() {
  local fakebin pid
  fakebin=$(fm_fakebin "$TMP_ROOT/pooled-liveness")
  make_ps "$fakebin"
  # A lock recorded against shared infrastructure belongs to no session, and the
  # daemon outlives every session, so treating one as a live holder wedges the
  # home's lock forever. Rejecting them lets the ordinary stale-owner path
  # reclaim such a lock.
  for pid in 200 300 400 900; do
    if alive_for "$fakebin" "$pid"; then
      fail "shared infrastructure pid $pid was accepted as a live session holder"
    fi
  done
  pass "session-lock identity: daemon and pooled-worker locks are reclaimable, not live holders"
}

# ---------------------------------------------------------------------------
# B) genuine session shapes still resolve
# ---------------------------------------------------------------------------

test_nested_pool_chain_resolves_outermost_session() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/nested-pool")
  make_ps "$fakebin"
  # The shape fixed in #1206, with the pooled workers labeled as they really
  # are: hook shell -> bg-spare -> bg-pty-host -> claude -> claude(lock).
  # Skipping infrastructure must not stop the walk before the session is
  # reached, and the outermost pid of the contiguous session run still wins.
  got=$(ancestry_for "$fakebin" 200 500)
  [ "$got" = 600 ] || fail "nested pool chain resolved '$got', expected the outer session pid 600"
  pass "session-lock identity: a pool chain below a session still resolves the outermost session pid"
}

test_versioned_executable_session_resolves_itself() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/versioned-session")
  make_ps "$fakebin"
  # A resumed or app-hosted session runs the versioned executable, whose command
  # name is the version rather than "claude", and its parent is a pty host owned
  # by the daemon. It must resolve to its own per-session pid, never to the pty
  # host or the daemon above it.
  got=$(ancestry_for "$fakebin" 800)
  [ "$got" = 800 ] || fail "versioned-executable session resolved '$got', expected the session pid 800"
  alive_for "$fakebin" 800 || fail "versioned-executable session pid was not accepted as a live holder"
  pass "session-lock identity: a versioned-executable session resolves its own pid, not its daemon-owned pty host"
}

test_session_prompt_mentioning_daemon_is_still_a_session() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/prompt-daemon")
  make_ps "$fakebin"
  # The rejection reads the subcommand position only. A session whose prompt
  # happens to contain "daemon" is a session.
  got=$(ancestry_for "$fakebin" 1000)
  [ "$got" = 1000 ] || fail "session with a daemon-mentioning prompt resolved '$got', expected 1000"
  alive_for "$fakebin" 1000 || fail "session with a daemon-mentioning prompt was not a live holder"
  pass "session-lock identity: a prompt that mentions daemon does not make a session infrastructure"
}

test_unrelated_program_under_a_claude_directory_is_not_a_harness() {
  local fakebin got status
  fakebin=$(fm_fakebin "$TMP_ROOT/claude-dir")
  make_ps "$fakebin"
  # Recognizing the versioned executable needs BOTH signals, a claude path
  # component and a version-shaped command name, so an unrelated program that
  # merely lives under a directory named claude is not the harness.
  got=$(ancestry_for "$fakebin" 1100); status=$?
  [ -z "$got" ] || fail "unrelated program under a claude directory resolved '$got'"
  expect_code 1 "$status" "an unrelated program under a claude directory must not resolve an identity"
  if alive_for "$fakebin" 1100; then
    fail "unrelated program under a claude directory was accepted as a live holder"
  fi
  pass "session-lock identity: a claude path component alone does not make a process the harness"
}

test_plain_session_and_non_claude_harness_unchanged() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/plain-session")
  make_ps "$fakebin"
  # A tool call whose direct parent is the session: the ordinary shape, and the
  # one a competing live session is recognized by.
  got=$(ancestry_for "$fakebin" 600)
  [ "$got" = 600 ] || fail "plain session ancestry resolved '$got', expected 600"
  alive_for "$fakebin" 600 || fail "a plain live session was not accepted as a live holder"
  pass "session-lock identity: an ordinary session ancestry and live holder are unchanged"
}

test_pooled_worker_ancestry_never_resolves_the_daemon
test_daemon_identity_is_not_shared_across_sessions
test_every_daemon_origin_is_rejected
test_pooled_workers_are_not_live_holders
test_nested_pool_chain_resolves_outermost_session
test_versioned_executable_session_resolves_itself
test_session_prompt_mentioning_daemon_is_still_a_session
test_unrelated_program_under_a_claude_directory_is_not_a_harness
test_plain_session_and_non_claude_harness_unchanged

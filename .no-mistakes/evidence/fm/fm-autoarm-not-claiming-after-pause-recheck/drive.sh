#!/usr/bin/env bash
# Manual live drive of the supervision-handoff change against a throwaway home.
R=$1; T=$(mktemp -d); H=$T/home
mkdir -p $H/state $H/config $H/bin; git init -q $H; git -C $H -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init; : > $H/AGENTS.md
printf 'window=firstmate:fm-task\nkind=ship\n' > $H/state/task.meta
PAY='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"true"}}'
pre(){ printf '%s\n' "$PAY" | FM_ROOT_OVERRIDE=$H FM_HOME=$H $R/bin/fm-supervision-pretool-check.sh "${@:---claude}"; echo "[exit=$?]"; }
ledger(){ printf 'epoch=13 owner_pid=%s outcome=rewake updated_at=%s\nfixture\n' $$ $(date +%s) > $H/state/.claude-autoarm-epoch; }
park(){ touch -t 202001010000 $H/state/.claude-autoarm-epoch; : > $H/state/.last-watcher-beat; touch -t 202001010000 $H/state/.last-watcher-beat; rm -f $H/state/.session-activity; }
guard(){ rm -f $H/state/.guard-watcher-stale-banner*; env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE "$1" FM_ROOT_OVERRIDE=$H FM_HOME=$H FM_SUPERVISION_MODEL=$2 $R/bin/fm-guard.sh 2>&1; echo "[exit=$?]"; }

echo "### 1. healthy: fresh handoff, session active -> silent"; ledger; : > $H/state/.session-activity; pre
echo "### 2. parked session (usage-limit shape): first tool call"; ledger; park; pre | tee $T/n.json
echo "### 2b. notice is valid JSON, no permissionDecision"; grep -v '^\[exit' $T/n.json | jq '{event:.hookSpecificOutput.hookEventName, ctx_eq_sys:(.hookSpecificOutput.additionalContext==.systemMessage), has_permission:(.hookSpecificOutput|has("permissionDecision")), keys:keys}'
echo "### 3. next tool call in same episode -> silent"; pre
echo "### 4. parks again -> told again"; park; pre | cut -c1-160
echo "### 5. adversarial: --bogus / --cursor / corrupt ledger / unreadable state"; park
pre --bogus; pre --cursor
printf 'epoch=\x00\xff owner_pid=x outcome= updated_at=never\n' > $H/state/.claude-autoarm-epoch; touch -t 202001010000 $H/state/.claude-autoarm-epoch; rm -f $H/state/.session-activity; pre | cut -c1-120
chmod 000 $H/state; pre; chmod 755 $H/state
echo "### 6. away mode -> silent"; ledger; park; : > $H/state/.afk; pre; rm $H/state/.afk
echo "### 7. Cursor payload -> silent"; park; printf '%s\n' '{"cursor_version":"1.0","conversation_id":"c","hook_event_name":"preToolUse","tool_name":"Shell"}' | FM_ROOT_OVERRIDE=$H FM_HOME=$H $R/bin/fm-supervision-pretool-check.sh --claude; echo "[exit=$?]"
echo "### 8. no ledger (never-Claude home) -> silent"; rm -f $H/state/.claude-autoarm-epoch $H/state/.session-activity; pre
echo "### 9. did the hook ever arm a watcher? (processes / lock files)"; ls -A $H/state; pgrep -fl "fm-watch.*$H" || echo "no watcher process for this home"
echo "### 10. fm-guard banner, parked claude home"; ledger; park; guard CLAUDECODE=1 autoarm
echo "### 11. fm-guard banner, ordinary between-cycles gap"; ledger; : > $H/state/.session-activity; guard CLAUDECODE=1 autoarm
echo "### 12. fm-guard banner, formerly-Claude home now on Cursor"; park; guard CURSOR_AGENT=1 autoarm
echo "### 13. fm-guard banner, persistent-model home with stale ledger"; park; guard CLAUDECODE=1 persistent
echo "### 14. turn-end guard, parked"; park; printf '%s\n' '{"session_id":"s","stop_hook_active":false}' | FM_ROOT_OVERRIDE=$H FM_HOME=$H FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 FM_CLAUDE_AUTOARM_EPOCH_FRESH=1 $R/bin/fm-turnend-guard.sh --claude 2>&1; echo "[exit=$?]"
rm -rf $T

#!/usr/bin/env bash
# Manual drive of the real hook scripts against a throwaway primary home.
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-handoff-drive.XXXXXX)
H="$T/home"; mkdir -p "$H/state" "$H/config" "$H/bin"
git init -q "$H"; git -C "$H" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
: > "$H/AGENTS.md"
printf 'window=firstmate:fm-task\nkind=ship\n' > "$H/state/task.meta"
PRE="$ROOT/bin/fm-supervision-pretool-check.sh"
PAY='{"session_id":"drive","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"}}'
age() { local e=$(( $(date +%s) - $2 )); touch -t "$(date -r "$e" +%Y%m%d%H%M.%S)" "$1"; }
pre() { printf '%s\n' "$PAY" | FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$PRE" "$@"; echo "[exit=$?]"; }
say() { printf '\n=== %s\n' "$*"; }

say "S1 parked session: ledger frozen on outcome=rewake 3h25m ago, beacon stale, no activity -> first tool call"
printf 'epoch=13 owner_pid=%s outcome=rewake updated_at=%s\nid\n' "$$" "$(date +%s)" > "$H/state/.claude-autoarm-epoch"
: > "$H/state/.last-watcher-beat"
age "$H/state/.claude-autoarm-epoch" 12300; age "$H/state/.last-watcher-beat" 12300
OUT=$(pre --claude); echo "$OUT"
echo "$OUT" | head -1 | jq '{keys: keys, event: .hookSpecificOutput.hookEventName, has_permission_decision: (.hookSpecificOutput|has("permissionDecision")), same_text_both_channels: (.hookSpecificOutput.additionalContext == .systemMessage)}'

say "S2 next call in same episode -> silent"
pre --claude

say "S3 adversarial: long tool call. activity aged 900s (call start), then PostToolUseFailure --post, then next PreToolUse"
age "$H/state/.session-activity" 900
printf '%s\n' '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"Command timed out after 10m 0s"}' | FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$PRE" --claude --post; echo "[post exit=$?]"
pre --claude

say "S3b control: same 900s gap WITHOUT the post touch -> notice speaks again (genuine re-park)"
age "$H/state/.session-activity" 900
pre --claude | cut -c1-160

say "S4 active long turn: ledger + beacon old, activity 60s old -> silent"
age "$H/state/.session-activity" 60
pre --claude

say "S5 fresh handoff (ledger 30s old), parked activity -> silent (ordinary gap)"
age "$H/state/.claude-autoarm-epoch" 30; rm -f "$H/state/.session-activity"
pre --claude

say "S6 never denies: unknown arg, --cursor, corrupt ledger, unreadable state"
age "$H/state/.claude-autoarm-epoch" 12300; rm -f "$H/state/.session-activity"
pre --bogus; rm -f "$H/state/.session-activity"
pre --cursor; rm -f "$H/state/.session-activity"
cp "$H/state/.claude-autoarm-epoch" "$T/ledger.bak"
printf 'epoch=\x00\xff owner_pid=nope outcome= updated_at=never\n' > "$H/state/.claude-autoarm-epoch"
pre --claude
cp "$T/ledger.bak" "$H/state/.claude-autoarm-epoch"; age "$H/state/.claude-autoarm-epoch" 12300
chmod 000 "$H/state"; pre --claude; chmod 755 "$H/state"

say "S7 no ledger (non-Claude home) -> silent"
mv "$H/state/.claude-autoarm-epoch" "$T/l"; rm -f "$H/state/.session-activity"
pre --claude
mv "$T/l" "$H/state/.claude-autoarm-epoch"

say "S8 away mode -> silent; Cursor payload -> silent"
rm -f "$H/state/.session-activity"; : > "$H/state/.afk"; pre --claude; rm -f "$H/state/.afk" "$H/state/.session-activity"
printf '%s\n' '{"session_id":"x","cursor_version":"1.7","hook_event_name":"preToolUse","workspace_roots":["/x"]}' | FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$PRE" --claude; echo "[exit=$?]"

say "S9 watcher-down banners on the parked home"
rm -f "$H/state/.session-activity"
echo "--- fm-guard.sh (claude, parked):"
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_SUPERVISION_MODEL=autoarm "$ROOT/bin/fm-guard.sh" 2>&1; echo "[exit=$?]"
echo "--- fm-guard.sh (claude, session active 30s ago):"
: > "$H/state/.session-activity"; age "$H/state/.session-activity" 30
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_SUPERVISION_MODEL=autoarm "$ROOT/bin/fm-guard.sh" 2>&1; echo "[exit=$?]"
echo "--- fm-guard.sh (cursor home with stale Claude ledger):"
env -u CLAUDECODE CURSOR_AGENT=1 FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_SUPERVISION_MODEL=autoarm "$ROOT/bin/fm-guard.sh" 2>&1; echo "[exit=$?]"
echo "--- fm-turnend-guard.sh (parked):"
rm -f "$H/state/.session-activity"
printf '%s\n' '{"session_id":"drive","stop_hook_active":false}' | FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 FM_CLAUDE_AUTOARM_EPOCH_FRESH=1 "$ROOT/bin/fm-turnend-guard.sh" --claude 2>&1; echo "[exit=$?]"
chmod -R u+rwx "$T"; rm -rf "$T"

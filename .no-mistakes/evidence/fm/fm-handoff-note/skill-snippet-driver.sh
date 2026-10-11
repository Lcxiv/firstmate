#!/usr/bin/env bash
set -u
WT=/Users/louiscondevaux/.no-mistakes/worktrees/71bad1a6f2bc/01M4MJ4CVC7KXTS0G6BY3328ED
L=/tmp/fm-handoff-lab/skill
mkdir -p "$L"
SNIP=$(awk '/^```sh$/{f=1;next} /^```$/{f=0} f' "$WT/.agents/skills/handoff-note/SKILL.md")
echo "### Skill dated-copy snippet, extracted verbatim from .agents/skills/handoff-note/SKILL.md:"
printf '%s\n\n' "$SNIP"
main=$L/main; mkdir -p "$main/sub/dir" "$main/data/handoff" "$main/bin" "$main/state" "$main/config"
git -c user.name=lab -c user.email=lab@example.invalid init -q -b main "$main"
git -c user.name=lab -c user.email=lab@example.invalid -C "$main" commit -q --allow-empty -m init
printf '# lab\n' > "$main/AGENTS.md"
printf '# Handoff, lab\nSynthetic.\n\n## Waiting on the captain\n- SYNTHETIC-SKILL-MARKER\n' > "$main/data/handoff/latest.md"
echo "## (a) main home, FM_HOME unset, cwd=$main/sub/dir"
( cd "$main/sub/dir" && unset FM_HOME && set -e && eval "$SNIP" ) && echo "exit 0"
ls -1 "$main/data/handoff"
sm=$L/secondmate-home; mkdir -p "$sm/data/handoff"
printf '# Handoff, sm\n- SYNTHETIC-SM-MARKER\n' > "$sm/data/handoff/latest.md"
echo; echo "## (b) FM_HOME=$sm, cwd=$main (a different repo)"
( cd "$main" && export FM_HOME="$sm" && set -e && eval "$SNIP" ) && echo "exit 0"
ls -1 "$sm/data/handoff"
echo; echo "main home after (b) (must be unchanged):"; ls -1 "$main/data/handoff"
echo
f=$(ls "$main/data/handoff" | grep -v latest.md)
printf '%s\n' "$f" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.md$' && echo "CHECK (a) stamp format YYYY-MM-DD-HHMM: OK ($f)"
cmp -s "$main/data/handoff/latest.md" "$main/data/handoff/$f" && echo "CHECK (a) dated copy identical to latest.md: OK"
g=$(ls "$sm/data/handoff" | grep -v latest.md)
printf '%s\n' "$g" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.md$' && cmp -s "$sm/data/handoff/latest.md" "$sm/data/handoff/$g" && echo "CHECK (b) FM_HOME copy landed in FM_HOME with the stamp format: OK ($g)"
[ "$(ls "$main/data/handoff" | wc -l | tr -d ' ')" = 2 ] && echo "CHECK (b) main home untouched by the FM_HOME run: OK"

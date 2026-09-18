#!/usr/bin/env bash
# Drives the real bin/ scripts against a throwaway fixture home. Usage: drive-1-seed.sh <repo-root> <tmp>
set -u
ROOT=$1; T=$2
main=$T/main; sub=$T/sub
G="git -c user.name=T -c user.email=t@example.invalid"
run() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }
mkdir -p $main/projects $main/data $main/state
alpha=$main/projects/alpha
git init -q -b main $alpha
printf 'private/\n' > $alpha/.gitignore; echo '# alpha' > $alpha/README.md
$G -C $alpha add -A; $G -C $alpha commit -qm initial
echo dropped > $alpha/dropped.txt; $G -C $alpha add -A; $G -C $alpha commit -qm dropped
UNREACH=$(git -C $alpha rev-parse HEAD); git -C $alpha reset -q --hard HEAD~1
mkdir $alpha/private; echo "SECRET-APPLICANT-ROW" > $alpha/private/applications.csv
echo scratch-SECRET-NOTE > $alpha/untracked-notes.txt
echo '#!/bin/sh' > $alpha/.git/hooks/pre-commit; git -C $alpha config fixture.secret SECRET-CONFIG
git init -q -b main $main/projects/beta; echo b > $main/projects/beta/f; $G -C $main/projects/beta add -A; $G -C $main/projects/beta commit -qm b
git clone -q --bare $main/projects/beta $T/remotes-beta.git; git -C $main/projects/beta remote add origin $T/remotes-beta.git
cat > $main/data/projects.md <<EOP
- alpha [local-only +yolo] - private local project (added 2026-09-18)
- beta [direct-PR] - remote-backed project (added 2026-09-18)
EOP
echo "== fixture: alpha has NO remote:"; run git -C $alpha remote -v
A=$(cd $alpha && pwd -P)
echo "== S1a: bare local-only name keeps its refusal + hint"
FM_HOME=$main FM_SECONDMATE_CHARTER='alpha and beta work' run $ROOT/bin/fm-home-seed.sh jt $sub alpha beta
run ls -d $sub
echo "== S1b: seed as alpha=<checkout>"
FM_HOME=$main FM_SECONDMATE_CHARTER='alpha and beta work' run $ROOT/bin/fm-home-seed.sh jt $sub "alpha=$A" beta
run git -C $sub/projects/alpha remote -v
run git -C $sub/projects/beta remote -v
run cat $sub/data/projects.md
run cat $main/data/projects.md
run cat $main/data/jt/local-origins
run ls $sub/data
run cat $main/data/secondmates.md
echo "== privacy sweep of the whole secondmate home"
run grep -rl "SECRET" $sub
run ls -a $sub/projects/alpha
run git -C $sub/projects/alpha cat-file -e $UNREACH
run git -C $sub/projects/alpha config fixture.secret
run ls $sub/projects/alpha/.git/hooks/pre-commit
echo "== S2: annotation read"
FM_HOME=$sub run $ROOT/bin/fm-project-mode.sh --origin alpha
FM_HOME=$sub run $ROOT/bin/fm-project-mode.sh alpha
FM_HOME=$sub run $ROOT/bin/fm-project-mode.sh --origin beta
FM_HOME=$main run $ROOT/bin/fm-project-mode.sh --origin alpha
FM_HOME=$sub run $ROOT/bin/fm-brief.sh jt-task alpha --mode local-only
FM_HOME=$main run $ROOT/bin/fm-brief.sh main-task alpha --mode local-only
echo "--- mirror brief (secondmate home) delivery lines:"; grep -n -i "push\|origin\|force\|Delivery contract" $sub/data/jt-task/brief.md
echo "--- authority brief (main home) delivery lines:"; grep -n -i "push\|origin\|force\|Delivery contract" $main/data/main-task/brief.md
echo "--- charter mirror rules:"; grep -n -i "local-only\|mirror" $sub/data/charter.md

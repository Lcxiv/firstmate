#!/usr/bin/env bash
# Live drive of the local-origin (Shape 2B) path against throwaway fixtures.
set -u
ROOT=$1
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
G="git -c user.name=t -c user.email=t@example.invalid"
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' $?; }
main=$T/main; sub=$T/sub; A=$main/projects/alpha
mkdir -p $main/projects $main/data $main/state
git init -q -b main $A
printf 'private/\n' > $A/.gitignore; echo '# alpha' > $A/README.md
$G -C $A add .; $G -C $A commit -qm initial
echo dropped > $A/d.txt; $G -C $A add d.txt; $G -C $A commit -qm dropped
UNREACH=$(git -C $A rev-parse HEAD); git -C $A reset -q --hard HEAD~1
mkdir $A/private; echo "SECRET-PERSONAL-ROW" > $A/private/applications.csv
echo "SECRET-SCRATCH" > $A/untracked.txt
mkdir -p $A/.git/hooks; printf '#!/bin/sh\n# SECRET-HOOK\n' > $A/.git/hooks/pre-push; chmod +x $A/.git/hooks/pre-push
git -C $A config fixture.secret SECRET-CONFIG
git -C $A remote add github https://example.invalid/private/alpha.git
git init -q --bare $T/beta.git; git init -q -b main $main/projects/beta
echo b > $main/projects/beta/f; $G -C $main/projects/beta add .; $G -C $main/projects/beta commit -qm b
git -C $main/projects/beta remote add origin $T/beta.git; git -C $main/projects/beta push -q origin main
cat > $main/data/projects.md <<R
- alpha [local-only +yolo] - private local project (added 2026-09-18)
- beta [direct-PR] - remote-backed project (added 2026-09-18)
R
export FM_SECONDMATE_CHARTER='alpha and beta work'

say "S1 bare local-only name keeps its refusal, plus hint"
FM_HOME=$main run $ROOT/bin/fm-home-seed.sh jt $sub alpha
run test -e $sub

say "S2 seed local-only project (no usable remote for the mirror) as local-origin mirror, beside remote-backed beta"
FM_HOME=$main run $ROOT/bin/fm-home-seed.sh jt $sub alpha=$A beta
M=$sub/projects/alpha
run git -C $M remote -v
run git -C $sub/projects/beta remote get-url origin
run cat $main/data/jt/local-origins
run grep -E '^- (alpha|beta) ' $sub/data/projects.md
run cat $main/data/projects.md

say "S3 annotation is read"
FM_HOME=$sub run $ROOT/bin/fm-project-mode.sh --origin alpha
FM_HOME=$sub run $ROOT/bin/fm-project-mode.sh alpha
FM_HOME=$sub run $ROOT/bin/fm-project-mode.sh --origin beta
FM_HOME=$main run $ROOT/bin/fm-project-mode.sh --origin alpha

say "S4 privacy: nothing private anywhere in the secondmate home"
run grep -rl -e SECRET- $sub
run git -C $M cat-file -e $UNREACH
run ls -A $M
run git -C $M config --get fixture.secret
run test -e $M/.git/hooks/pre-push
run test -e $sub/data/jt/local-origins

say "S5 worker contract in mirror vs. authority home"
FM_HOME=$sub run $ROOT/bin/fm-brief.sh jt-task alpha --mode local-only
run grep -n -i -E 'push|origin|never read' $sub/data/jt-task/brief.md
FM_HOME=$main run $ROOT/bin/fm-brief.sh main-task alpha --mode local-only
run grep -n -i -E 'push' $main/data/main-task/brief.md

say "S6 worker pushes fm/jt-task; secondmate cannot land; main lands"
git -C $M checkout -q -b fm/jt-task; echo change >> $M/README.md; $G -C $M commit -qam change
run git -C $M push origin fm/jt-task
printf 'project=%s\nmode=local-only\n' $M > $sub/state/jt-task.meta
B=$(git -C $A rev-parse main)
FM_HOME=$sub run $ROOT/bin/fm-merge-local.sh jt-task
echo "authority main unchanged: $([ "$(git -C $A rev-parse main)" = $B ] && echo yes || echo NO)"
say "dirty-tree guard still fires on --secondmate"
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt jt-task
rm $A/untracked.txt
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt jt-task
run git -C $A log --oneline -3 main
run cat $A/private/applications.csv

say "S7 diverged: no force-push, retry branch -r2"
git -C $M checkout -q main; git -C $M pull -q origin main
git -C $M checkout -q -b fm/t2; echo t2 >> $M/README.md; $G -C $M commit -qam t2
git -C $M push -q origin fm/t2; printf 'project=%s\nmode=local-only\n' $M > $sub/state/t2.meta
echo moved > $A/moved.txt; $G -C $A add moved.txt; $G -C $A commit -qm moved
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt t2
git -C $M fetch -q origin; $G -C $M rebase -q origin/main
run git -C $M push origin fm/t2
run git -C $M push origin fm/t2:refs/heads/fm/t2-r2
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt --branch fm/other t2
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt --branch fm/t2-r2 t2

say "S8 adversarial: worker rewrites mirror origin to another real repo"
git clone -q --no-local $A $T/other; O=$T/other
git -C $M remote set-url origin $O
git -C $M checkout -q -b fm/evil origin/main 2>/dev/null; echo evil >> $M/README.md; $G -C $M commit -qam evil
git -C $M push -q origin fm/evil; printf 'project=%s\nmode=local-only\n' $M > $sub/state/evil.meta
OB=$(git -C $O rev-parse main); AB=$(git -C $A rev-parse main)
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt evil
echo "other main unchanged: $([ "$(git -C $O rev-parse main)" = $OB ] && echo yes || echo NO); authority main unchanged: $([ "$(git -C $A rev-parse main)" = $AB ] && echo yes || echo NO)"
git -C $M remote set-url origin $A
mv $main/data/jt/local-origins $main/data/jt/lo.moved
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt evil
mv $main/data/jt/lo.moved $main/data/jt/local-origins

say "S9 reseed idempotent; misapplied origin refused"
FM_HOME=$main run $ROOT/bin/fm-home-seed.sh jt $sub alpha=$A beta
run cat $main/data/jt/local-origins
run grep -c -- '- alpha ' $sub/data/projects.md
FM_HOME=$main run $ROOT/bin/fm-home-seed.sh jt2 $T/sub2 beta=$main/projects/beta
run test -e $T/sub2
rm -rf "$T"

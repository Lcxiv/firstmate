#!/usr/bin/env bash
# Continues from drive-1: worker delivery, landing, rebase retry, adversarial landings.
set -u
ROOT=$1; T=$2
main=$T/main; sub=$T/sub; A=$(cd $main/projects/alpha && pwd -P); M=$sub/projects/alpha
G="git -c user.name=T -c user.email=t@example.invalid"
run() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }
heads() { echo "   authority main=$(git -C $A rev-parse --short main)"; }
echo "== precise privacy sweep (fixture-unique needles)"
run grep -rlE "SECRET-APPLICANT-ROW|scratch-SECRET-NOTE|SECRET-CONFIG" $sub
echo "== S3: worker pushes fm/jt-task; secondmate cannot land; main home lands"
$G -C $M checkout -q -b fm/jt-task; echo change >> $M/README.md; $G -C $M commit -qam change
run git -C $M push origin fm/jt-task
mkdir -p $sub/state; printf 'project=%s\nmode=local-only\n' $M > $sub/state/jt-task.meta
heads
FM_HOME=$sub run $ROOT/bin/fm-merge-local.sh jt-task
heads
echo "-- dirty-tree guard still applies (untracked file in authority):"
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt jt-task
heads
rm $A/untracked-notes.txt
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt jt-task
heads; run git -C $A log --oneline -3 main
run cat $A/private/applications.csv
echo "== S4: default branch advances; rebased retry lands as -r2 with no force-push"
$G -C $M checkout -q main; $G -C $M pull -q origin main
$G -C $M checkout -q -b fm/t2; echo t2 > $M/t2.txt; $G -C $M add -A; $G -C $M commit -qm t2
run git -C $M push origin fm/t2
printf 'project=%s\nmode=local-only\n' $M > $sub/state/t2.meta
echo other > $A/other.txt; $G -C $A add other.txt; $G -C $A commit -qm "main home lands other work"
heads
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt t2
heads
$G -C $M fetch -q origin; $G -C $M rebase -q origin/main
echo "-- plain re-push of rebased fm/t2 is rejected by git (non-ff), as the contract expects:"
run git -C $M push origin fm/t2
run git -C $M push origin fm/t2:refs/heads/fm/t2-r2
echo "-- bad --branch values:"
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt --branch main t2
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt --branch fm/other-r2 t2
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt --branch fm/t2-r1 t2
heads
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt --branch fm/t2-r2 t2
heads; run git -C $A log --oneline -4 main
echo "== S5 adversarial: mirror origin rewritten to another real repo"
V=$T/victim; git init -q -b main $V; echo v > $V/v; $G -C $V add -A; $G -C $V commit -qm victim; V=$(cd $V && pwd -P)
git -C $M remote set-url origin $V
$G -C $M checkout -q --orphan fm/evil; $G -C $M commit -qm evil; git -C $M push -q origin fm/evil
printf 'project=%s\nmode=local-only\n' $M > $sub/state/evil.meta
vb=$(git -C $V rev-parse main); ab=$(git -C $A rev-parse main)
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt evil
echo "   victim main moved? $([ $vb = $(git -C $V rev-parse main) ] && echo no || echo YES)  authority main moved? $([ $ab = $(git -C $A rev-parse main) ] && echo no || echo YES)"
git -C $M remote set-url origin $A
echo "== S5b adversarial: main-home record missing"
mv $main/data/jt/local-origins $T/lo.bak
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt --branch fm/t2-r2 t2
mv $T/lo.bak $main/data/jt/local-origins
echo "== S5c: secondmate-side forged record is ignored (record only read from main home)"
mkdir -p $sub/data/jt; printf 'alpha\t%s\n' $V > $sub/data/jt/local-origins
git -C $M remote set-url origin $V
FM_HOME=$main run $ROOT/bin/fm-merge-local.sh --secondmate jt evil
echo "   victim main moved? $([ $vb = $(git -C $V rev-parse main) ] && echo no || echo YES)"

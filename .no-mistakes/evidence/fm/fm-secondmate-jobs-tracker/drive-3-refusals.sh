#!/usr/bin/env bash
# Seed refusals for the local-origin form, and remote-backed behaviour compared between base and target bin/.
# Usage: drive-3-refusals.sh <target-root> <base-root> <tmp>
set -u
ROOT=$1; BASE=$2; T=$3
G="git -c user.name=T -c user.email=t@example.invalid"
run() { echo; echo "\$ $*" | sed "s#$T#<T>#g; s#$ROOT#<target>#g; s#$BASE#<base>#g"; "$@" 2>&1 | sed "s#/private$T#<T>#g; s#$T#<T>#g"; echo "[exit ${PIPESTATUS[0]}]"; }
mkhome() { # <home>
  local h=$1; mkdir -p $h/projects $h/data $h/state
  git init -q -b main $h/projects/alpha; echo a > $h/projects/alpha/f; $G -C $h/projects/alpha add -A; $G -C $h/projects/alpha commit -qm a
  git init -q -b main $h/projects/beta; echo b > $h/projects/beta/f; $G -C $h/projects/beta add -A; $G -C $h/projects/beta commit -qm b
  git clone -q --bare $h/projects/beta $h/beta.git; git -C $h/projects/beta remote add origin $h/beta.git
  git init -q -b main $h/projects/gone; echo g > $h/projects/gone/f; $G -C $h/projects/gone add -A; $G -C $h/projects/gone commit -qm g
  git -C $h/projects/gone remote add origin $h/does-not-exist.git
  git init -q -b main $h/projects/noremote; echo n > $h/projects/noremote/f; $G -C $h/projects/noremote add -A; $G -C $h/projects/noremote commit -qm n
  cat > $h/data/projects.md <<EOP
- alpha [local-only] - private (added 2026-09-18)
- beta [direct-PR] - remote-backed (added 2026-09-18)
- gone [direct-PR] - unreachable remote (added 2026-09-18)
- noremote [direct-PR] - misconfigured, no origin (added 2026-09-18)
EOP
}
h=$T/ref; mkhome $h; A=$(cd $h/projects/alpha && pwd -P)
seed() { FM_HOME=$h FM_SECONDMATE_CHARTER=c run $ROOT/bin/fm-home-seed.sh rx $T/ref-sub "$@"; echo "   subhome created? $([ -e $T/ref-sub ] && echo YES || echo no); main record? $([ -e $h/data/rx/local-origins ] && echo YES || echo no)"; }
echo "== local-origin form refusals (target)"
seed alpha
seed alpha=projects/alpha
seed alpha=$T/nope
git clone -q --bare $A $T/alpha-bare.git; seed alpha=$T/alpha-bare.git
mkdir -p $A/subdir; seed alpha=$A/subdir
git -C $A checkout -q -b side; seed alpha=$A; git -C $A checkout -q main
seed beta=$h/projects/beta
seed alpha=
echo; echo "== remote-backed path: identical output on base vs target"
for which in base target; do
  if [ $which = base ]; then R=$BASE; else R=$ROOT; fi
  hh=$T/cmp-$which; mkhome $hh
  for spec in gone noremote beta; do
    out=$(FM_HOME=$hh FM_SECONDMATE_CHARTER=c $R/bin/fm-home-seed.sh rx $T/cmp-$which-sub $spec 2>&1 | grep -v "^Note: switching\|detached HEAD\|^$\|^You are in\|^changes and\|^state without\|^If you want\|^do so\|git switch\|^Or undo\|^Turn off" ; echo "exit=${PIPESTATUS[0]}")
    printf '%s\n' "$out" | sed "s#/private$T/cmp-$which#<H>#g; s#$T/cmp-$which#<H>#g" > $T/cmp-$which-$spec.out
  done
  { cat $hh/data/secondmates.md; cat $T/cmp-$which-sub/data/projects.md; git -C $T/cmp-$which-sub/projects/beta remote get-url origin; ls $hh/data/rx; } 2>&1 | sed "s#/private$T/cmp-$which#<H>#g; s#$T/cmp-$which#<H>#g" > $T/cmp-$which-state.out
done
for f in gone noremote beta state; do echo "--- $f (target output):"; cat $T/cmp-target-$f.out; echo "--- diff base vs target for $f:"; diff $T/cmp-base-$f.out $T/cmp-target-$f.out && echo IDENTICAL; done

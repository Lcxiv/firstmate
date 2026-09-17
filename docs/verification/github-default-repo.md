# GitHub default-repository verification

Audience: maintainer verification.

This record supports `bin/fm-gh-default-repo-lib.sh` and the spawn refusal it arms in `bin/fm-spawn.sh`.
It records only the vendor facts that library rests on, so they can be re-established when `gh` or `gh-axi` changes.
Task chronology and incident transcripts stay in private reports or PR evidence.

The library pins `remote.origin.gh-resolved=base`, which is what `gh repo set-default` itself writes.
`tests/fm-gh-default-repo.test.sh` is the regression that keeps the behavior below enforced.

## gh ranks remotes by name when nothing is pinned

Verified 2026-09-17 against `gh version 2.100.0 (2026-09-03)`.

With `origin` alone, an unqualified lookup resolves to `origin`.
Adding a second remote named `upstream`, changing nothing else, moves every unqualified lookup to `upstream`.
Pinning `origin` moves it back.

```
$ git remote add origin https://github.com/Lcxiv/firstmate.git
$ gh repo view --json nameWithOwner
{"nameWithOwner":"Lcxiv/firstmate"}

$ git remote add upstream https://github.com/kunchenguid/firstmate.git
$ gh repo view --json nameWithOwner
{"nameWithOwner":"kunchenguid/firstmate"}

$ git config remote.origin.gh-resolved base
$ gh repo view --json nameWithOwner
{"nameWithOwner":"Lcxiv/firstmate"}
```

A fork inherits its parent's history, so both repositories hold the same low PR and issue numbers.
The wrong lookup therefore returns a real, plausible PR of that number rather than a not-found error.

## A pin on another remote outranks origin's

Verified 2026-09-17 against the same release.
`gh` takes the first remote carrying `gh-resolved` in its own name order, and `upstream` outranks `origin` there, so writing origin's pin is not enough on its own.

```
$ git config remote.upstream.gh-resolved base   # origin is pinned too
$ gh repo view --json nameWithOwner
{"nameWithOwner":"kunchenguid/firstmate"}

$ git config --unset remote.upstream.gh-resolved
$ gh repo view --json nameWithOwner
{"nameWithOwner":"Lcxiv/firstmate"}
```

`fm_gh_default_repo_ensure` clears every competing pin before writing origin's for this reason.

## The pin is readable offline and exits 0 either way

Verified 2026-09-17 against the same release.
`gh repo set-default --view` needs no network and no valid credential, which is what lets the spawn preflight verify its own pin rather than assume it took.
It exits 0 whether or not a default is set, and prints nothing on stdout when none is, so the verdict must come from stdout and never from the exit status.

```
$ gh repo set-default --view; echo "exit=$?"          # unpinned
X No default remote repository has been set. ...
exit=0
$ gh repo set-default --view; echo "exit=$?"          # pinned
Lcxiv/firstmate
exit=0
```

Note that the unpinned reading does not name `upstream`.
`gh` reports only that no default is set, never the ranking it is about to fall back to, so the wrong target is invisible at this surface.

## A linked worktree shares the pin with its primary checkout

Verified 2026-09-17 against `git version 2.50.1 (Apple Git-155)`.
`git config` from a linked worktree writes the shared common config unless `--worktree` is passed, so pinning one task worktree settles every worktree of that clone and the primary checkout with it.
This is why the spawn preflight alone converges a repository that firstmate also queries directly.

## gh-axi labels output with a repository it did not necessarily query

Verified 2026-09-17 against `gh-axi 0.1.35`.
`gh-axi` resolves its own target with the priority `--repo` flag, then `GH_REPO`, then `git remote get-url origin`, and appends `--repo` to the `gh` call only for the first two.
A git-derived target is therefore printed in the `repo:` header while the payload is left to gh's ranking above.
On a fork with both remotes the header named `Lcxiv/firstmate` while the listed issues and PRs were upstream's four-digit numbers, inside one command's output.

The cause is in `gh-axi`, not in firstmate, and this repository does not own that tool.
Pinning origin removes the divergence for both tools at once, because it makes gh's answer agree with the header gh-axi already prints.

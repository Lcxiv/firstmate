#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> [<origin>] prints the
# block on stdout with no trailing blank line. <origin> is the project's
# `fm-project-mode.sh --origin` answer; local-origin renders the local-only
# variant for a secondmate's mirror clone, whose worker pushes fm/<id> to the
# project's authoritative working repository instead of waiting for a local
# merge in its own clone. That contract never force-pushes: a rebased delivery
# goes to a new, never-reused branch name (fm/<id>-r2, fm/<id>-r3, ...), which
# bin/fm-merge-local.sh --secondmate --branch lands.
# The caller validates the mode; an unknown mode is refused rather than silently
# rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

fm_dod_block() {  # <mode> <task-id> [<origin>]
  local mode=$1 id=$2 origin=${3:-default}
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      if [ "$origin" = local-origin ]; then
        cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only** from a local-origin mirror: no PR, no pipeline, and the only remote is \`origin\`, the project's authoritative working repository.
The task is complete only when committed on your branch \`fm/$id\` and that branch is pushed to \`origin\` with \`git push origin fm/$id\`. Push nothing else anywhere, do NOT open a PR, and do NOT merge.
Never force-push, in any form: no \`--force\`, no \`--force-with-lease\`, no \`+\` refspec, and never delete a branch in \`origin\`. A branch name you have pushed is never pushed to again.
Touch \`origin\` only through \`git fetch\`, \`git ls-remote\`, and those pushes: never read, copy, or write the files of the repository it points at.
Keep your work a clean fast-forward onto \`origin\`'s default branch. If that branch has advanced after you pushed, fetch, rebase your local \`fm/$id\` onto it, and push the result under the next unused delivery name instead: \`git push origin fm/$id:refs/heads/fm/$id-r2\`, then \`fm/$id-r3\`, and so on. Check \`git ls-remote --heads origin 'fm/$id*'\` first so the name you pick does not exist yet.
When it is implemented, committed, and pushed, append \`done: ready in branch <exact branch name you last pushed> pushed to origin\` to the status file (for example \`done: ready in branch fm/$id pushed to origin\`, or \`fm/$id-r2\` after one rebase) and stop.
The configured merge authority approves the ready branch, then the main firstmate lands exactly that named branch through the guarded fast-forward path.
EOF
        return
      fi
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}

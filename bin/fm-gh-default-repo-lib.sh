# shellcheck shell=bash
# Pin `origin` as the GitHub default repository of a checkout, so that an
# unqualified `gh` or `gh-axi` lookup made from it resolves to the repository
# firstmate pushes to and opens PRs against.
# Usage: . bin/fm-gh-default-repo-lib.sh
#
# Why this exists: gh picks its target repository from the git remotes, and with
# no `remote.<name>.gh-resolved` pin it ranks remotes by NAME, placing `upstream`
# above `origin`. A fork checkout that keeps both remotes therefore sends every
# unqualified lookup to the parent repository. Because a fork inherits the
# parent's history, the same low PR and issue numbers exist in both, so the
# wrong lookup returns a real, plausible PR instead of a not-found error.
# gh-axi compounds this: it labels its output with the repository it reads from
# `git remote get-url origin`, but it appends `--repo` only when the repository
# came from its --repo flag or GH_REPO, so a git-derived target is left to gh's
# own ranking. The header then names origin while the payload came from
# upstream, and nothing in the output marks the split.
#
# Pinning origin removes the ambiguity at its source, for gh and for every tool
# that wraps it, without any caller having to remember `--repo`.

# Echo the gh host these helpers resolve against.
fm_gh_default_repo_host() {
  printf '%s\n' "${GH_HOST:-github.com}"
}

# Echo OWNER/NAME when <url> names a repository on the gh host.
# Return 1 for a remote on any other host, so a non-GitHub origin is left alone.
fm_gh_default_repo_nwo_from_url() {  # <url>
  local url=$1 host rest owner name
  host=$(fm_gh_default_repo_host)
  case $url in
    *://*) rest=${url#*://} ;;
    *) rest=$url ;;
  esac
  rest=${rest#*@}
  case $rest in
    "$host/"*) rest=${rest#"$host/"} ;;
    "$host:"*) rest=${rest#"$host:"} ;;
    *) return 1 ;;
  esac
  rest=${rest%/}
  rest=${rest%.git}
  owner=${rest%%/*}
  name=${rest#*/}
  [ -n "$owner" ] && [ -n "$name" ] && [ "$owner" != "$rest" ] || return 1
  case $name in */*) return 1 ;; esac
  printf '%s/%s\n' "$owner" "$name"
}

# Echo the repository an unqualified gh lookup from <path> will target.
# Return 1 when gh is absent or reports no default, which is also what gh prints
# when it is about to fall back to its own remote ranking: that fallback is
# exactly the ambiguity this library removes, and gh never names it.
fm_gh_default_repo_resolved() {  # <path>
  local dir=$1 view
  command -v gh >/dev/null 2>&1 || return 1
  view=$(cd "$dir" 2>/dev/null && gh repo set-default --view 2>/dev/null) || return 1
  view=${view%%$'\n'*}
  case $view in
    ?*/?*) printf '%s\n' "$view" ;;
    *) return 1 ;;
  esac
}

# Pin origin as <path>'s default repository and clear any competing pin.
# Idempotent. A checkout with no origin, or an origin on another host, has no
# GitHub lookup to disambiguate and is reported as an untouched success.
# Refuse rather than report success when the pin cannot be written or when gh
# is installed and still resolves somewhere other than origin, because a silent
# wrong answer is the whole failure this guards.
fm_gh_default_repo_ensure() {  # <path>
  local dir=$1 url nwo remote current resolved
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "error: '$dir' is not a git worktree; cannot set its default repository" >&2
    return 1
  }
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  nwo=$(fm_gh_default_repo_nwo_from_url "$url") || return 0

  # gh takes the FIRST remote carrying a gh-resolved pin in its own name order,
  # which ranks `upstream` above `origin`. A pin left anywhere else outranks the
  # one written below, so competing pins are cleared before origin's is set.
  while IFS= read -r remote; do
    [ -n "$remote" ] && [ "$remote" != origin ] || continue
    git -C "$dir" config --get "remote.$remote.gh-resolved" >/dev/null 2>&1 || continue
    git -C "$dir" config --unset-all "remote.$remote.gh-resolved" || {
      echo "error: could not clear the '$remote' default-repository pin in '$dir'" >&2
      return 1
    }
  done <<EOF
$(git -C "$dir" remote 2>/dev/null)
EOF

  current=$(git -C "$dir" config --get remote.origin.gh-resolved 2>/dev/null || true)
  if [ "$current" != base ]; then
    git -C "$dir" config remote.origin.gh-resolved base || {
      echo "error: could not pin '$nwo' as the default repository for '$dir'" >&2
      return 1
    }
  fi

  # Verify rather than assume gh agrees. A wrapper assuming it and gh resolve a
  # repository alike is the failure this library exists to stop, so the same
  # assumption is not repeated here. gh reads the pin offline, so this costs no
  # network. With gh absent there is no gh lookup to be misled and nothing to
  # verify, so the written pin stands on its own.
  resolved=$(fm_gh_default_repo_resolved "$dir") || {
    command -v gh >/dev/null 2>&1 || return 0
    echo "error: '$dir' still reports no default repository after pinning '$nwo'" >&2
    return 1
  }
  if [ "$resolved" != "$nwo" ]; then
    echo "error: lookups from '$dir' resolve to '$resolved', not origin '$nwo'" >&2
    return 1
  fi
}

#!/usr/bin/env bash
set -euo pipefail

# rename to 'origin' or 'upstream' depending on your setup
GIT_REMOTE="eels"

usage() {
  cat <<EOF
usage: gitrebasecompare [remote-branch]

Compare the current local branch to its copy on the \$GIT_REMOTE (hardcoded) remote
(defaults to a branch of the same name, or the given remote-branch).

Examples:
  gitrebasecompare         (now we will compare current branch against GIT_REMOTE/<current-branch-name>)
  gitrebasecompare testabc (now we will compare current branch against GIT_REMOTE/testabc)
EOF
}

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  color_red=$'\033[31m'
  color_green=$'\033[32m'
  color_yellow=$'\033[33m'
  color_reset=$'\033[0m'
else
  color_red=''
  color_green=''
  color_yellow=''
  color_reset=''
fi

die() {
  printf '%berror:%b %s\n' "$color_red" "$color_reset" "$*" >&2
  exit 1
}

warn() {
  printf '%bwarning:%b %s\n' "$color_yellow" "$color_reset" "$*" >&2
}

print_range_diff() {
  local range_diff_output="$1"

  awk \
    -v color_green="$color_green" \
    -v color_red="$color_red" \
    -v color_yellow="$color_yellow" \
    -v color_reset="$color_reset" '
    /^[[:space:]]*[0-9]+:/ && / = / {
      state = "same"
      print color_green $0 color_reset
      next
    }

    /^[[:space:]]*[0-9]+:/ && / ! / {
      state = "modified"
      print color_red $0 color_reset
      next
    }

    / ---------- > / {
      state = "inspect"
      print color_yellow $0 color_reset
      next
    }

    /^[[:space:]]*[0-9]+:/ && / < / {
      state = "inspect"
      print color_yellow $0 color_reset
      next
    }

    /^$/ {
      state = ""
      print
      next
    }

    {
      if (state == "modified") {
        print color_red $0 color_reset
      } else if (state == "inspect") {
        print color_yellow $0 color_reset
      } else if (state == "same") {
        print color_green $0 color_reset
      } else {
        print
      }
    }
  ' <<<"$range_diff_output"
}

resolve_remote_ref() {
  local branch_arg="${1:-}"
  local current_branch="$2"
  local branch="${branch_arg:-$current_branch}"

  printf '%s/%s\n' "$GIT_REMOTE" "$branch"
}

resolve_base_ref() {
  local current_branch="$1"
  local configured_merge=""
  local candidate=""

  configured_merge="$(git config --get "branch.$current_branch.merge" 2>/dev/null || true)"
  if [[ -n "$configured_merge" ]]; then
    candidate="${configured_merge#refs/heads/}"
    if [[ "$candidate" != "$current_branch" ]] && git rev-parse --verify --quiet "$candidate" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 0
}

summarize_range_diff() {
  local range_diff_output="$1"
  local counts=""
  local same=0
  local modified=0
  local added=0
  local dropped=0
  local same_color=""
  local modified_color=""
  local added_color=""
  local dropped_color=""

  counts="$(printf '%s\n' "$range_diff_output" | awk '
    / ---------- > / { added++ }
    /^[[:space:]]*[0-9]+:/ && / = / { same++ }
    /^[[:space:]]*[0-9]+:/ && / ! / { modified++ }
    / < / { dropped++ }
    END {
      printf "%d %d %d %d\n", same + 0, modified + 0, added + 0, dropped + 0
    }
  ')"

  read -r same modified added dropped <<<"$counts"

  same_color=""
  modified_color="$color_green"
  added_color="$color_green"
  dropped_color="$color_green"

  if ((modified + added + dropped == 0)); then
    same_color="$color_green"
  fi

  if ((modified != 0)); then
    modified_color="$color_yellow"
  fi

  if ((added != 0)); then
    added_color="$color_yellow"
  fi

  if ((dropped != 0)); then
    dropped_color="$color_yellow"
  fi

  printf '%bSummary:%b same=%b%d%b modified=%b%d%b added=%b%d%b dropped=%b%d%b\n' \
    "" "" \
    "$same_color" "$same" "$color_reset" \
    "$modified_color" "$modified" "$color_reset" \
    "$added_color" "$added" "$color_reset" \
    "$dropped_color" "$dropped" "$color_reset"

  if ((modified + added + dropped == 0)); then
    printf '%bVerdict: likely a harmless rebase; the patch series is effectively unchanged.%b\n' \
      "$color_green" "$color_reset"
  else
    printf '%bVerdict: not a pure rebase; inspect the added/modified/dropped commits above.%b\n' \
      "$color_red" "$color_reset"
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (($# > 1)); then
  usage >&2
  exit 2
fi

git remote get-url "$GIT_REMOTE" >/dev/null 2>&1 \
  || die "configured GIT_REMOTE '$GIT_REMOTE' is not a known git remote; edit the GIT_REMOTE constant at the top of this script"

current_branch="$(git branch --show-current)"
[[ -n "$current_branch" ]] || die "detached HEAD or no current branch"

remote_ref="$(resolve_remote_ref "${1:-}" "$current_branch")"
base_ref="$(resolve_base_ref "$current_branch")"

if ! git fetch "$GIT_REMOTE" >/dev/null 2>&1; then
  warn "git fetch $GIT_REMOTE failed; using locally available refs"
fi

if ! git rev-parse --verify --quiet "$remote_ref" >/dev/null; then
  if [[ -n "${1:-}" ]]; then
    die "remote branch '$remote_ref' does not exist"
  else
    die "remote branch '$remote_ref' does not exist; either rename your local branch to match an existing remote branch, or pass the remote branch name as an argument"
  fi
fi

local_tip="$(git rev-parse HEAD)"
remote_tip="$(git rev-parse "$remote_ref")"
old_base="$(git merge-base HEAD "$remote_ref")"

if [[ -n "$base_ref" ]] && git rev-parse --verify --quiet "$base_ref" >/dev/null; then
  new_base="$(git merge-base "$remote_ref" "$base_ref")"
else
  base_ref=""
  new_base="$old_base"
fi

printf 'Local:\t\t%s (%s)\n' "$local_tip" "$current_branch"
printf 'Remote:\t\t%s (%s)\n' "$remote_tip" "$remote_ref"
printf 'Shared base:\t%s\n' "$old_base"
if [[ -n "$base_ref" ]]; then
  printf 'Base ref:     %s\n' "$base_ref"
  printf 'Remote base:  %s\n' "$new_base"
fi
printf '\n'

if [[ "$local_tip" == "$remote_tip" ]]; then
  printf '%bLocal and remote are identical; nothing to compare.%b\n' \
    "$color_green" "$color_reset"
  exit 0
fi

if [[ "$old_base" == "$local_tip" && "$new_base" == "$remote_tip" ]]; then
  printf '%bBoth ranges are empty; nothing to compare.%b\n' \
    "$color_green" "$color_reset"
  exit 0
fi

printf 'Command:\n'
printf 'git range-diff %s..%s %s..%s\n' \
  "$old_base" "$local_tip" "$new_base" "$remote_tip"
printf '\n'

range_diff_output="$(git range-diff --no-color \
  "$old_base..$local_tip" \
  "$new_base..$remote_tip"
)"

print_range_diff "$range_diff_output"
printf '\n'
summarize_range_diff "$range_diff_output"

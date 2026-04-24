#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <PR_URL|PR_NUMBER>" >&2
}

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  usage
  exit 2
fi

input="$1"
owner="ethereum"
repo="execution-specs"
pr_num=""

if [[ "$input" =~ ^[0-9]+$ ]]; then
  pr_num="$input"
elif [[ "$input" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)(/.*)?$ ]]; then
  owner="${BASH_REMATCH[1]}"
  repo="${BASH_REMATCH[2]}"
  pr_num="${BASH_REMATCH[3]}"
else
  echo "error: expected a PR number or GitHub PR URL, got: $input" >&2
  usage
  exit 2
fi

echo "Getting commits for $owner/$repo PR #$pr_num..."

commits="$(
  gh api "repos/$owner/$repo/pulls/$pr_num/commits" \
    --paginate \
    --jq '.[].sha'
)"

if [[ -z "$commits" ]]; then
  echo "error: no commits found for $owner/$repo PR #$pr_num" >&2
  echo "       check the PR exists and that 'gh auth status' is healthy" >&2
  exit 1
fi

while read -r commit; do
  [[ -n "$commit" ]] || continue
  echo "Cherry-picking commit: $commit"
  if ! git cherry-pick "$commit"; then
    echo "Failed to cherry-pick $commit. Resolve conflicts and continue."
    exit 1
  fi
done <<< "$commits"

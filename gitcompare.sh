#!/usr/bin/env bash
set -euo pipefail

remote="${1:-eels}"
branch="$(git branch --show-current)"

if [[ -z "$branch" ]]; then
  echo "Error: detached HEAD or no current branch."
  exit 1
fi

git fetch "$remote" >/dev/null 2>&1

if ! git show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
  echo "Error: remote branch '$remote/$branch' does not exist."
  exit 1
fi

local_hash="$(git rev-parse HEAD)"
remote_hash="$(git rev-parse "$remote/$branch")"

local_date="$(git show -s --format=%cd --date=format-local:'%Y-%m-%d %H:%M:%S' "$local_hash")"
remote_date="$(git show -s --format=%cd --date=format-local:'%Y-%m-%d %H:%M:%S' "$remote_hash")"

if [[ "$local_hash" == "$remote_hash" ]]; then
  echo "OK ($local_hash, $local_date)"
else
  printf 'NOT SYNCED\n'
  printf '\tlocal:\t%-40s, %s\n'  "$local_hash"  "$local_date"
  printf '\t%s:\t%-40s, %s\n'     "$remote"      "$remote_hash" "$remote_date"
fi

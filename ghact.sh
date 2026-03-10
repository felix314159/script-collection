#!/usr/bin/env bash
set -euo pipefail

# ghact.sh
#
# Show recent commit activity for a GitHub user, grouped by PR.
#
# Included commits are the union of:
#   1. commits on the repo default branch by the user within the past N hours
#   2. commits within the past N hours belonging to open PRs authored by the user
#      targeting OWNER/REPO
#   3. if OWNER/REPO is a fork, commits within the past N hours belonging to open
#      PRs on the parent repo whose head repo is OWNER/REPO and whose author is the
#      given user
#
# Requirements:
#   - gh
#   - jq
#
# Usage:
#   ./ghact.sh OWNER/REPO[,OWNER/REPO...] GITHUB_USERNAME HOURS
#
# Example:
#   ./ghact.sh felix314159/execution-specs,ethereum/hive felix314159 24

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh is required but not installed." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 OWNER/REPO[,OWNER/REPO...] GITHUB_USERNAME HOURS" >&2
  exit 1
fi

OWNER_REPO="$1"
GITHUB_USER="$2"
HOURS="$3"

if ! [[ "$HOURS" =~ ^[0-9]+$ ]]; then
  echo "Error: HOURS must be an integer." >&2
  exit 1
fi

if [[ "$OWNER_REPO" == *,* ]]; then
  IFS=',' read -r -a OWNER_REPOS <<< "$OWNER_REPO"
  overall_status=0
  repo_index=0

  for repo_name in "${OWNER_REPOS[@]}"; do
    [[ -z "$repo_name" ]] && continue

    if (( repo_index > 0 )); then
      echo
    fi

    echo "================================================================================"
    echo "Repository: ${repo_name}"
    echo "================================================================================"

    if ! "$0" "$repo_name" "$GITHUB_USER" "$HOURS"; then
      overall_status=1
    fi

    repo_index=$((repo_index + 1))
  done

  exit "$overall_status"
fi

OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"

if [[ -z "$OWNER" || -z "$REPO" || "$OWNER" == "$REPO" ]]; then
  echo "Error: repo must be in OWNER/REPO format." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

since_ts="$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"
since_epoch="$(date -u -d "${since_ts}" +%s)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repo_meta_json="$tmp_dir/repo_meta.json"
repo_meta_err="$tmp_dir/repo_meta.err"
recent_commits_jsonl="$tmp_dir/recent_commits.jsonl"
prs_jsonl="$tmp_dir/prs.jsonl"
combined_jsonl="$tmp_dir/combined.jsonl"

: > "$recent_commits_jsonl"
: > "$prs_jsonl"
: > "$combined_jsonl"
: > "$repo_meta_err"

echo "Recent activity (past ${HOURS} hours) of user ${GITHUB_USER}:"
echo

if ! gh api "/repos/${OWNER}/${REPO}" > "$repo_meta_json" 2> "$repo_meta_err"; then
  if grep -q "HTTP 404" "$repo_meta_err"; then
    echo "Could not find repo ${OWNER_REPO}, are you sure it exists?" >&2
  else
    cat "$repo_meta_err" >&2
  fi
  exit 1
fi

IS_FORK="$(jq -r '.fork // false' "$repo_meta_json")"
PARENT_FULL_NAME="$(jq -r '.parent.full_name // empty' "$repo_meta_json")"

# 1) Recent commits by the user on the repo's default branch.
gh api --paginate \
  "/repos/${OWNER}/${REPO}/commits?author=${GITHUB_USER}&since=${since_ts}&per_page=100" \
  --jq '.[]' > "$recent_commits_jsonl" || true

# 2) Open PRs targeting OWNER/REPO authored by the user.
gh api --paginate \
  "/repos/${OWNER}/${REPO}/pulls?state=open&per_page=100" \
  --jq '.[] | select(.user.login == "'"${GITHUB_USER}"'")' >> "$prs_jsonl" || true

# 3) If OWNER/REPO is a fork, also inspect open PRs on the parent repo
#    where the source/head repo is exactly OWNER/REPO and the PR author matches.
if [[ "$IS_FORK" == "true" && -n "$PARENT_FULL_NAME" ]]; then
  PARENT_OWNER="${PARENT_FULL_NAME%%/*}"
  PARENT_REPO="${PARENT_FULL_NAME##*/}"

  gh api --paginate \
    "/repos/${PARENT_OWNER}/${PARENT_REPO}/pulls?state=open&per_page=100" \
    --jq '.[]
      | select(.user.login == "'"${GITHUB_USER}"'")
      | select(.head.repo.full_name == "'"${OWNER_REPO}"'")' >> "$prs_jsonl" || true
fi

# De-duplicate PR entries by target repo + PR number.
if [[ -s "$prs_jsonl" ]]; then
  tmp_prs_dedup="$tmp_dir/prs_dedup.jsonl"
  jq -s -c '
    map(select(.number != null))
    | unique_by(.base.repo.full_name + "#" + (.number | tostring))
    | .[]
  ' "$prs_jsonl" > "$tmp_prs_dedup"
  mv "$tmp_prs_dedup" "$prs_jsonl"
fi

# Add recent default-branch commits first.
while IFS= read -r commit_row; do
  [[ -z "$commit_row" ]] && continue

  sha="$(jq -r '.sha' <<<"$commit_row")"
  date_iso="$(jq -r '.commit.author.date // .commit.committer.date // ""' <<<"$commit_row")"
  title="$(jq -r '.commit.message | split("\n")[0]' <<<"$commit_row")"

  prs="$(gh api "/repos/${OWNER}/${REPO}/commits/${sha}/pulls" 2>/dev/null || echo '[]')"

  pr_obj="$(jq -c '
    if length == 0 then
      null
    else
      (map(select(.state == "open")) | .[0])
      // (map(select(.merged_at != null)) | .[0])
      // .[0]
    end
  ' <<<"$prs")"

  if [[ "$pr_obj" == "null" ]]; then
    jq -nc \
      --arg sha "$sha" \
      --arg date "$date_iso" \
      --arg title "$title" \
      '{
        sha: $sha,
        date: $date,
        title: $title,
        pr_number: null,
        pr_title: null,
        pr_url: null,
        base_branch: null,
        head_repo: null,
        head_ref: null,
        target_repo: null,
        group_type: "no_pr",
        group_key: "no_pr",
        source: "recent_default_branch"
      }' >> "$combined_jsonl"
  else
    pr_number="$(jq -r '.number' <<<"$pr_obj")"
    pr_title="$(jq -r '.title' <<<"$pr_obj")"
    pr_url="$(jq -r '.html_url' <<<"$pr_obj")"
    base_branch="$(jq -r '.base.ref' <<<"$pr_obj")"
    head_repo="$(jq -r '.head.repo.full_name // ""' <<<"$pr_obj")"
    head_ref="$(jq -r '.head.ref // ""' <<<"$pr_obj")"
    target_repo="$(jq -r '.base.repo.full_name // ""' <<<"$pr_obj")"

    jq -nc \
      --arg sha "$sha" \
      --arg date "$date_iso" \
      --arg title "$title" \
      --arg pr_number "$pr_number" \
      --arg pr_title "$pr_title" \
      --arg pr_url "$pr_url" \
      --arg base_branch "$base_branch" \
      --arg head_repo "$head_repo" \
      --arg head_ref "$head_ref" \
      --arg target_repo "$target_repo" \
      '{
        sha: $sha,
        date: $date,
        title: $title,
        pr_number: ($pr_number | tonumber),
        pr_title: $pr_title,
        pr_url: $pr_url,
        base_branch: $base_branch,
        head_repo: $head_repo,
        head_ref: $head_ref,
        target_repo: $target_repo,
        group_type: "pr",
        group_key: ($target_repo + "#pr-" + $pr_number),
        source: "recent_default_branch"
      }' >> "$combined_jsonl"
  fi
done < "$recent_commits_jsonl"

# Add recent commits from each open PR.
while IFS= read -r pr_row; do
  [[ -z "$pr_row" ]] && continue

  pr_number="$(jq -r '.number' <<<"$pr_row")"
  pr_title="$(jq -r '.title' <<<"$pr_row")"
  pr_url="$(jq -r '.html_url' <<<"$pr_row")"
  base_branch="$(jq -r '.base.ref' <<<"$pr_row")"
  head_repo="$(jq -r '.head.repo.full_name // ""' <<<"$pr_row")"
  head_ref="$(jq -r '.head.ref // ""' <<<"$pr_row")"
  target_repo="$(jq -r '.base.repo.full_name // ""' <<<"$pr_row")"

  target_owner="${target_repo%%/*}"
  target_repo_name="${target_repo##*/}"

  gh api --paginate \
    "/repos/${target_owner}/${target_repo_name}/pulls/${pr_number}/commits?per_page=100" \
    --jq '.[]' |
  while IFS= read -r commit_row; do
    [[ -z "$commit_row" ]] && continue

    sha="$(jq -r '.sha' <<<"$commit_row")"
    date_iso="$(jq -r '.commit.author.date // .commit.committer.date // ""' <<<"$commit_row")"
    title="$(jq -r '.commit.message | split("\n")[0]' <<<"$commit_row")"

    if [[ -z "$date_iso" ]]; then
      continue
    fi

    if ! commit_epoch="$(date -u -d "${date_iso}" +%s 2>/dev/null)"; then
      continue
    fi

    if (( commit_epoch < since_epoch )); then
      continue
    fi

    jq -nc \
      --arg sha "$sha" \
      --arg date "$date_iso" \
      --arg title "$title" \
      --arg pr_number "$pr_number" \
      --arg pr_title "$pr_title" \
      --arg pr_url "$pr_url" \
      --arg base_branch "$base_branch" \
      --arg head_repo "$head_repo" \
      --arg head_ref "$head_ref" \
      --arg target_repo "$target_repo" \
      '{
        sha: $sha,
        date: $date,
        title: $title,
        pr_number: ($pr_number | tonumber),
        pr_title: $pr_title,
        pr_url: $pr_url,
        base_branch: $base_branch,
        head_repo: $head_repo,
        head_ref: $head_ref,
        target_repo: $target_repo,
        group_type: "pr",
        group_key: ($target_repo + "#pr-" + $pr_number),
        source: "open_pr"
      }' >> "$combined_jsonl"
  done
done < "$prs_jsonl"

if [[ ! -s "$combined_jsonl" ]]; then
  echo "No commits found."
  exit 0
fi

jq -s -r '
  def spaces($n):
    if $n <= 0 then
      ""
    else
      reduce range(0; $n) as $i (""; . + " ")
    end;

  def repeat($text; $n):
    if $n <= 0 then
      ""
    else
      reduce range(0; $n) as $i (""; . + $text)
    end;

  def pad_right($text; $width):
    $text + spaces($width - ($text | length));

  def format_date($date):
    if ($date // "") == "" then
      "unknown-date"
    else
      (
        $date
        | fromdateiso8601
        | strflocaltime("%Y-%m-%d, %I:%M %p")
        | capture("(?<day>\\d{4}-\\d{2}-\\d{2}), (?<hour>\\d{2}):(?<minute>\\d{2}) (?<ampm>AM|PM)")
        | "\(.day), \(.hour | tonumber):\(.minute) \(.ampm)"
      )
    end;

  def pr_header_lines($row):
    (
      [
        ["PR #\($row.pr_number):", $row.pr_title],
        ["URL:", $row.pr_url],
        ["Target repo:", $row.target_repo],
        ["Target branch:", $row.base_branch]
      ]
      + (
          if ($row.head_repo // "") != "" then
            [
              ["Source repo:", $row.head_repo],
              ["Source branch:", $row.head_ref]
            ]
          else
            []
          end
        )
    ) as $lines
    | ([ $lines[] | .[0] | length ] | max) as $label_width
    | ($lines | map("\(pad_right(.[0]; $label_width))  \(.[1])"));

  def commit_table_lines($rows):
    ([ "Date" ] + ($rows | map(format_date(.date))) | map(length) | max) as $date_width
    | ([ "Commit Hash" ] + ($rows | map(.sha[0:7])) | map(length) | max) as $sha_width
    | ([ "Commit Message" ] + ($rows | map(.title)) | map(length) | max) as $title_width
    | [
        "  | \(pad_right("Date"; $date_width)) | \(pad_right("Commit Hash"; $sha_width)) | \(pad_right("Commit Message"; $title_width)) |",
        "  | \(repeat("-"; $date_width)) | \(repeat("-"; $sha_width)) | \(repeat("-"; $title_width)) |"
      ]
      + (
          $rows
          | map(
              "  | \(pad_right(format_date(.date); $date_width)) | \(pad_right(.sha[0:7]; $sha_width)) | \(pad_right(.title; $title_width)) |"
            )
        );

  def group_lines($rows):
    (
      if $rows[0].group_type == "pr" then
        pr_header_lines($rows[0])
      else
        ["Commits with no associated PR"]
      end
    ) + [""] + commit_table_lines($rows);

  map(select(.sha != null and .sha != ""))
  | sort_by(
      .sha,
      (if .group_type == "pr" then 0 else 1 end),
      (if .source == "open_pr" then 0 else 1 end)
    )
  | group_by(.sha)
  | map(.[0])
  | sort_by(
      (if .group_type == "pr" then 0 else 1 end),
      .target_repo,
      .pr_number,
      .date
    )
  | if length == 0 then
      "No commits found."
    else
      (
        group_by(.group_key) as $groups
        | ($groups | map(group_lines(.))) as $rendered_groups
        | ($rendered_groups | map(map(length) | max) | max) as $separator_width
        | $rendered_groups[]
        | (. + ["", repeat("-"; $separator_width), ""])[]
      )
    end
' "$combined_jsonl"

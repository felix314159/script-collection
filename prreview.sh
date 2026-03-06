#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $(basename "$0") <PR_URL>" >&2
  exit 2
fi

pr_url="$1"
owner=""
repo=""
pr_number=""

if [[ "$pr_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  owner="${BASH_REMATCH[1]}"
  repo="${BASH_REMATCH[2]}"
  pr_number="${BASH_REMATCH[3]}"
else
  echo "error: unsupported PR URL format: $pr_url" >&2
  exit 2
fi

trap 'echo "ERR line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

_strip_nulls() {
  jq '
    def stripnulls:
      if type == "object" then
        with_entries(select(.value != null) | .value |= stripnulls)
      elif type == "array" then
        map(stripnulls)
      else
        .
      end;
    stripnulls
  '
}

_gql_must_ok() {
  local resp="$1"
  local errs
  errs="$(printf '%s' "$resp" | jq -c '.errors // empty' 2>/dev/null || true)"
  if [[ -n "$errs" && "$errs" != "null" && "$errs" != "[]" ]]; then
    echo "gh: GraphQL errors: $errs" >&2
    return 1
  fi
}

_fetch_patches() {
  local owner="$1" repo="$2" pr_number="$3"
  gh api "repos/$owner/$repo/pulls/$pr_number/files" --paginate | jq '[.[] | {
    path: .filename,
    status: .status,
    additions: .additions,
    deletions: .deletions,
    changes: .changes,
    patch: (.patch // null)
  }]'
}

_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

pr_meta_file="$_tmpdir/pr_meta.json"
all_threads_file="$_tmpdir/all_threads.json"
pr_comments_file="$_tmpdir/pr_comments.json"
patches_file="$_tmpdir/patches.json"

printf '{}' > "$pr_meta_file"
printf '[]' > "$all_threads_file"
printf '[]' > "$pr_comments_file"

cursor="null"
while :; do
  resp="$(gh api graphql \
    -F owner="$owner" \
    -F name="$repo" \
    -F number="$pr_number" \
    -F cursor="$cursor" \
    -f query='
      query($owner:String!, $name:String!, $number:Int!, $cursor:String) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            number
            title
            url
            updatedAt
            reviewThreads(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isResolved
                isOutdated
                path
                line
                originalLine
                startLine
                originalStartLine
                comments(first: 100) {
                  pageInfo { hasNextPage endCursor }
                  nodes {
                    id
                    author { login }
                    body
                    createdAt
                    updatedAt
                    url
                  }
                }
              }
            }
          }
        }
      }'
  )"

  _gql_must_ok "$resp"

  printf '%s' "$resp" | jq '.data.repository.pullRequest | {number,title,url,updatedAt}' > "$pr_meta_file"

  page_threads_file="$_tmpdir/page_threads.json"
  printf '%s' "$resp" | jq '.data.repository.pullRequest.reviewThreads.nodes // []' > "$page_threads_file"

  expanded_threads_file="$_tmpdir/expanded_threads.json"
  jq -c '.[]' "$page_threads_file" | while IFS= read -r thread; do
    thread_id="$(printf '%s' "$thread" | jq -r '.id')"
    comments_has_next="$(printf '%s' "$thread" | jq -r '.comments.pageInfo.hasNextPage')"

    if [[ "$comments_has_next" != "true" ]]; then
      printf '%s\n' "$thread" | jq 'del(.comments.pageInfo)'
      continue
    fi

    all_comments_file="$_tmpdir/thread_${thread_id//[^A-Za-z0-9._-]/_}_comments.json"
    printf '%s' "$thread" | jq '.comments.nodes // []' > "$all_comments_file"
    comment_cursor="$(printf '%s' "$thread" | jq -r '.comments.pageInfo.endCursor')"

    while :; do
      cresp="$(gh api graphql \
        -F owner="$owner" \
        -F name="$repo" \
        -F number="$pr_number" \
        -F threadId="$thread_id" \
        -F cursor="$comment_cursor" \
        -f query='
          query($owner:String!, $name:String!, $number:Int!, $threadId:ID!, $cursor:String) {
            repository(owner:$owner, name:$name) {
              pullRequest(number:$number) {
                reviewThread(id:$threadId) {
                  comments(first: 100, after: $cursor) {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                      id
                      author { login }
                      body
                      createdAt
                      updatedAt
                      url
                    }
                  }
                }
              }
            }
          }'
      )"

      _gql_must_ok "$cresp"

      next_comments_file="$_tmpdir/thread_${thread_id//[^A-Za-z0-9._-]/_}_next_comments.json"
      printf '%s' "$cresp" | jq '.data.repository.pullRequest.reviewThread.comments.nodes // []' > "$next_comments_file"

      jq -s '.[0] + .[1]' "$all_comments_file" "$next_comments_file" > "$all_comments_file.new"
      mv "$all_comments_file.new" "$all_comments_file"

      hn="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.reviewThread.comments.pageInfo.hasNextPage')"
      ec="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.reviewThread.comments.pageInfo.endCursor')"

      if [[ "$hn" != "true" || "$ec" == "null" ]]; then
        break
      fi
      comment_cursor="$ec"
    done

    printf '%s\n' "$thread" | jq --slurpfile all "$all_comments_file" '.comments = {nodes: $all[0]}'
  done | jq -s '.' > "$expanded_threads_file"

  jq -s '.[0] + .[1]' "$all_threads_file" "$expanded_threads_file" > "$all_threads_file.new"
  mv "$all_threads_file.new" "$all_threads_file"

  has_next="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')"
  end_cursor="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')"

  if [[ "$has_next" != "true" || "$end_cursor" == "null" ]]; then
    break
  fi
  cursor="$end_cursor"
done

c_cursor="null"
while :; do
  cresp="$(gh api graphql \
    -F owner="$owner" \
    -F name="$repo" \
    -F number="$pr_number" \
    -F cursor="$c_cursor" \
    -f query='
      query($owner:String!, $name:String!, $number:Int!, $cursor:String) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            comments(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                author { login }
                body
                createdAt
                updatedAt
                url
              }
            }
          }
        }
      }'
  )"

  _gql_must_ok "$cresp"

  page_comments_file="$_tmpdir/page_comments.json"
  printf '%s' "$cresp" | jq '.data.repository.pullRequest.comments.nodes // []' > "$page_comments_file"

  jq -s '.[0] + .[1]' "$pr_comments_file" "$page_comments_file" > "$pr_comments_file.new"
  mv "$pr_comments_file.new" "$pr_comments_file"

  hn="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage')"
  ec="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor')"

  if [[ "$hn" != "true" || "$ec" == "null" ]]; then
    break
  fi
  c_cursor="$ec"
done

_fetch_patches "$owner" "$repo" "$pr_number" > "$patches_file"

jq -n \
  --slurpfile pr "$pr_meta_file" \
  --slurpfile threads "$all_threads_file" \
  --slurpfile prComments "$pr_comments_file" \
  --slurpfile patches "$patches_file" '
  def review_timeline($threads):
    [ $threads[]
      as $t
      | ($t.comments.nodes // [])[]
      | {
          kind: "review",
          threadId: $t.id,
          isResolved: $t.isResolved,
          isOutdated: $t.isOutdated,
          path: $t.path,
          line: $t.line,
          originalLine: $t.originalLine,
          startLine: $t.startLine,
          originalStartLine: $t.originalStartLine,
          id: .id,
          author: (.author.login // null),
          body: .body,
          createdAt: .createdAt,
          updatedAt: .updatedAt,
          url: .url
        }
    ];

  def issue_timeline($cs):
    [ $cs[]
      | {
          kind: "issue",
          id: .id,
          author: (.author.login // null),
          body: .body,
          createdAt: .createdAt,
          updatedAt: .updatedAt,
          url: .url
        }
    ];

  {
    pr: $pr[0],
    threads: $threads[0],
    prComments: $prComments[0],
    patches: $patches[0],
    timeline: (
      review_timeline($threads[0]) +
      issue_timeline($prComments[0]) |
      sort_by(.createdAt, .url)
    )
  }
' | _strip_nulls

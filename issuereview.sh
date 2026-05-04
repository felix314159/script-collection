#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $(basename "$0") <ISSUE_URL>" >&2
  exit 2
fi

issue_url="$1"
owner=""
repo=""
issue_number=""

if [[ "$issue_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/issues/([0-9]+) ]]; then
  owner="${BASH_REMATCH[1]}"
  repo="${BASH_REMATCH[2]}"
  issue_number="${BASH_REMATCH[3]}"
else
  echo "error: unsupported issue URL format: $issue_url" >&2
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

_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

issue_meta_file="$_tmpdir/issue_meta.json"
issue_comments_file="$_tmpdir/issue_comments.json"

printf '{}' > "$issue_meta_file"
printf '[]' > "$issue_comments_file"

meta_resp="$(gh api graphql \
  -F owner="$owner" \
  -F name="$repo" \
  -F number="$issue_number" \
  -f query='
    query($owner:String!, $name:String!, $number:Int!) {
      repository(owner:$owner, name:$name) {
        issue(number:$number) {
          number
          title
          url
          state
          stateReason
          createdAt
          updatedAt
          closedAt
          author { login }
          body
          labels(first: 50) { nodes { name } }
          assignees(first: 50) { nodes { login } }
          milestone { title }
        }
      }
    }'
)"

_gql_must_ok "$meta_resp"

printf '%s' "$meta_resp" | jq '
  .data.repository.issue
  | {
      number,
      title,
      url,
      state,
      stateReason,
      createdAt,
      updatedAt,
      closedAt,
      author: (.author.login // null),
      body,
      labels: [.labels.nodes[]?.name],
      assignees: [.assignees.nodes[]?.login],
      milestone: (.milestone.title // null)
    }
' > "$issue_meta_file"

cursor="null"
while :; do
  resp="$(gh api graphql \
    -F owner="$owner" \
    -F name="$repo" \
    -F number="$issue_number" \
    -F cursor="$cursor" \
    -f query='
      query($owner:String!, $name:String!, $number:Int!, $cursor:String) {
        repository(owner:$owner, name:$name) {
          issue(number:$number) {
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

  _gql_must_ok "$resp"

  page_comments_file="$_tmpdir/page_comments.json"
  printf '%s' "$resp" | jq '.data.repository.issue.comments.nodes // []' > "$page_comments_file"

  jq -s '.[0] + .[1]' "$issue_comments_file" "$page_comments_file" > "$issue_comments_file.new"
  mv "$issue_comments_file.new" "$issue_comments_file"

  hn="$(printf '%s' "$resp" | jq -r '.data.repository.issue.comments.pageInfo.hasNextPage')"
  ec="$(printf '%s' "$resp" | jq -r '.data.repository.issue.comments.pageInfo.endCursor')"

  if [[ "$hn" != "true" || "$ec" == "null" ]]; then
    break
  fi
  cursor="$ec"
done

jq -n \
  --slurpfile issue "$issue_meta_file" \
  --slurpfile comments "$issue_comments_file" '
  def comment_timeline($cs):
    [ $cs[]
      | {
          kind: "comment",
          id: .id,
          author: (.author.login // null),
          body: .body,
          createdAt: .createdAt,
          updatedAt: .updatedAt,
          url: .url
        }
    ];

  def opening_post($i):
    [{
      kind: "issue",
      id: ($i.url // null),
      author: $i.author,
      body: $i.body,
      createdAt: $i.createdAt,
      updatedAt: $i.updatedAt,
      url: $i.url
    }];

  {
    issue: $issue[0],
    comments: $comments[0],
    timeline: (
      opening_post($issue[0]) +
      comment_timeline($comments[0]) |
      sort_by(.createdAt, .url)
    )
  }
' | _strip_nulls

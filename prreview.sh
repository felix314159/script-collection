#!/usr/bin/env bash
set -euo pipefail

# prreview: fetch PR review threads + PR issue comments + file patches into one JSON blob.
# Requirements: gh, jq. Auth: gh auth login.

prreview() {
  if [[ $# -ne 1 ]]; then
    echo "usage: prreview <PR_URL>" 1>&2
    return 2
  fi

  local pr_url="$1"
  local owner repo pr_number

  if [[ "$pr_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    pr_number="${BASH_REMATCH[3]}"
  else
    echo "error: unsupported PR URL format: $pr_url" 1>&2
    return 2
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
      echo "gh: GraphQL errors: $errs" 1>&2
      return 1
    fi
  }

  _fetch_patches() {
    local owner="$1" repo="$2" pr_number="$3"
    gh api "repos/$owner/$repo/pulls/$pr_number/files" --paginate |
      jq -c '[.[] | {
        path: .filename,
        status: .status,
        additions: .additions,
        deletions: .deletions,
        changes: .changes,
        patch: (.patch // null)
      }]'
  }

  local cursor="null"
  local all_threads='[]'
  local pr_meta='{}'

  # Fetch review threads (paginate threads; also paginate comments within a thread if needed)
  while :; do
    local resp
    resp="$(
      gh api graphql \
        -F owner="$owner" -F name="$repo" -F number="$pr_number" -F cursor="$cursor" \
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

    pr_meta="$(printf '%s' "$resp" | jq '.data.repository.pullRequest | {number,title,url,updatedAt}')"
    local page_threads
    page_threads="$(printf '%s' "$resp" | jq '.data.repository.pullRequest.reviewThreads.nodes // []')"

    # Expand threads that have >100 comments
    page_threads="$(
      printf '%s' "$page_threads" |
        jq -c '.[]' |
        while IFS= read -r thread; do
          local thread_id comments_has_next
          thread_id="$(printf '%s' "$thread" | jq -r '.id')"
          comments_has_next="$(printf '%s' "$thread" | jq -r '.comments.pageInfo.hasNextPage')"

          if [[ "$comments_has_next" != "true" ]]; then
            printf '%s\n' "$thread" | jq 'del(.comments.pageInfo)'
            continue
          fi

          local comment_cursor all_comments
          comment_cursor="$(printf '%s' "$thread" | jq -r '.comments.pageInfo.endCursor')"
          all_comments="$(printf '%s' "$thread" | jq '.comments.nodes // []')"

          while :; do
            local cresp next_comments hn ec
            cresp="$(
              gh api graphql \
                -F owner="$owner" -F name="$repo" -F number="$pr_number" \
                -F threadId="$thread_id" -F cursor="$comment_cursor" \
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

            next_comments="$(printf '%s' "$cresp" | jq '.data.repository.pullRequest.reviewThread.comments.nodes // []')"
            all_comments="$(jq -n --argjson a "$all_comments" --argjson b "$next_comments" '$a + $b')"
            hn="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.reviewThread.comments.pageInfo.hasNextPage')"
            ec="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.reviewThread.comments.pageInfo.endCursor')"

            if [[ "$hn" != "true" || "$ec" == "null" ]]; then
              break
            fi
            comment_cursor="$ec"
          done

          printf '%s\n' "$thread" | jq --argjson all "$all_comments" '.comments = {nodes: $all}'
        done | jq -s '.'
    )"

    all_threads="$(jq -n --argjson a "$all_threads" --argjson b "$page_threads" '$a + $b')"

    local has_next end_cursor
    has_next="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')"
    end_cursor="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')"
    if [[ "$has_next" != "true" || "$end_cursor" == "null" ]]; then
      break
    fi
    cursor="$end_cursor"
  done

  # Fetch PR issue comments (paginate)
  local pr_comments='[]'
  local c_cursor="null"
  while :; do
    local cresp
    cresp="$(
      gh api graphql \
        -F owner="$owner" -F name="$repo" -F number="$pr_number" -F cursor="$c_cursor" \
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

    local page_comments
    page_comments="$(printf '%s' "$cresp" | jq '.data.repository.pullRequest.comments.nodes // []')"
    pr_comments="$(jq -n --argjson a "$pr_comments" --argjson b "$page_comments" '$a + $b')"

    local hn ec
    hn="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage')"
    ec="$(printf '%s' "$cresp" | jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor')"
    if [[ "$hn" != "true" || "$ec" == "null" ]]; then
      break
    fi
    c_cursor="$ec"
  done

  # Fetch file patches via REST
  local patches
  patches="$(_fetch_patches "$owner" "$repo" "$pr_number")"

  # Emit final JSON
  jq -n \
    --argjson pr "$pr_meta" \
    --argjson threads "$all_threads" \
    --argjson prComments "$pr_comments" \
    --argjson patches "$patches" '
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
        pr: $pr,
        threads: $threads,
        prComments: $prComments,
        patches: $patches,
        timeline: (review_timeline($threads) + issue_timeline($prComments) | sort_by(.createdAt, .url))
      }
    ' | _strip_nulls
}

prreview "$@"

#!/usr/bin/env bash
# realcommitdate <github-commit-url>
#
# Queries GitHub's repo events feed for the PushEvent that introduced the
# given commit, and prints when GitHub actually received it. Unlike the
# author/committer dates in the commit object, this timestamp is stamped by
# GitHub on receipt and cannot be spoofed by the pusher.
#
# Caveat: GitHub's events API retains only ~90 days of history. Older pushes
# are not queryable this way.

set -euo pipefail

url="${1:-}"
if [[ -z "$url" ]]; then
    echo "Usage: realcommitdate <github-commit-url>" >&2
    exit 64
fi

if [[ ! "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/commit/([0-9a-fA-F]+) ]]; then
    echo "Error: not a GitHub commit URL: $url" >&2
    echo "Expected: https://github.com/OWNER/REPO/commit/SHA" >&2
    exit 64
fi
owner="${BASH_REMATCH[1]}"
repo="${BASH_REMATCH[2]}"
sha="${BASH_REMATCH[3]}"

for cmd in gh jq; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 69; }
done

# Walk repo events (up to 10 pages × 100 = ~1000 entries, though GitHub caps
# total event history at 300 entries / ~90 days for public users).
match=""
for page in 1 2 3 4 5 6 7 8 9 10; do
    page_json=$(gh api -X GET "repos/$owner/$repo/events" \
        -f per_page=100 -f page="$page" 2>/dev/null || echo "[]")
    [[ "$page_json" == "[]" || "$page_json" == "null" ]] && break

    # The /repos/:owner/:repo/events endpoint returns PushEvent payloads with
    # commits: null — only `head`, `before`, `ref` are populated. So we match
    # on payload.head (the tip of the push). Commits in the middle of a multi-
    # commit push won't match directly; for those, look up the push that
    # contains them and match its head instead.
    match=$(echo "$page_json" | jq -c --arg sha "$sha" '
        [ .[]
          | select(.type == "PushEvent")
          | (.payload.head // "") as $h
          | select(
              ($h | startswith($sha)) or
              ($sha | startswith($h))
            )
          | select($h != "")
          | {
              created_at: .created_at,
              actor:      .actor.login,
              ref:        .payload.ref,
              head:       .payload.head,
              before:     .payload.before,
              matched:    .payload.head
            }
        ] | first // empty
    ')

    [[ -n "$match" ]] && break
done

if [[ -z "$match" ]]; then
    # Fallback: scrape the public activity page. It embeds a JSON blob with
    # all recent pushes (including force pushes, which the events API filters
    # out) and retains them longer than the events feed.
    activity_html=$(curl -sL "https://github.com/$owner/$repo/activity" || true)
    activity_json=$(echo "$activity_html" | python3 -c '
import sys, re, json, html as htmllib
data = sys.stdin.read()
m = re.search(r"<script type=\"application/json\" data-target=\"react-app\.embeddedData\">(.*?)</script>", data, re.S)
if not m:
    sys.exit(0)
raw = htmllib.unescape(m.group(1))
try:
    obj = json.loads(raw)
    items = obj.get("payload", {}).get("activityList", {}).get("items", [])
    print(json.dumps(items))
except Exception:
    pass
' 2>/dev/null)

    if [[ -n "$activity_json" && "$activity_json" != "[]" ]]; then
        match=$(echo "$activity_json" | jq -c --arg sha "$sha" '
            [ .[]
              | (.after  // "") as $a
              | (.before // "") as $b
              | (($a != "" and (($a | startswith($sha)) or ($sha | startswith($a))))) as $hit_after
              | (($b != "" and (($b | startswith($sha)) or ($sha | startswith($b))))) as $hit_before
              | select($hit_after or $hit_before)
              | {
                  created_at: .pushedAt,
                  actor:      (.pusher.login // "unknown"),
                  ref:        .ref,
                  head:       .after,
                  before:     .before,
                  push_type:  .pushType,
                  matched:    (if $hit_after then .after else .before end),
                  source:     "activity-page"
                }
            ] | first // empty
        ')
    fi
fi

if [[ -z "$match" ]]; then
    cat >&2 <<EOF
No PushEvent found for ${sha:0:12} in $owner/$repo (events API + activity page both checked).

Possible reasons:
  - The push is older than ~90 days (GitHub events API retention limit).
  - The commit is mid-push, not the head; the /repos/.../events endpoint
    only reports the head SHA of each push. Find which push contains it
    via the repo's Activity tab and re-run with that push's head SHA.
  - The commit reached this repo via a merge/fork rather than a direct push.
  - The repo is private and your token lacks access.

You can still inspect the activity log manually:
  https://github.com/$owner/$repo/activity
EOF
    exit 1
fi

pushed_at_utc=$(echo "$match" | jq -r '.created_at')
push_type=$(echo "$match"     | jq -r '.push_type // "push"')
matched=$(echo "$match"       | jq -r '.matched')

# `date -d` parses the UTC ISO string and `%s` emits UTC epoch seconds — both
# legs of the subtraction are UTC epochs, so the math is timezone-invariant.
pushed_epoch=$(date -d "$pushed_at_utc" +%s)
now_epoch=$(date +%s)
pushed_local=$(date -d "@$pushed_epoch" '+%Y-%m-%d %H:%M:%S %Z (UTC%:z)')

# Fetch the commit object so we can compare its self-reported dates against
# the push timestamp.
commit_json=$(gh api "repos/$owner/$repo/commits/$matched" 2>/dev/null || echo "{}")
author_date=$(echo "$commit_json"    | jq -r '.commit.author.date    // empty')
committer_date=$(echo "$commit_json" | jq -r '.commit.committer.date // empty')

# Spoof detection. Two checks, asymmetric on purpose:
#   - push vs committer: tight (2 days). The committer date is stamped at
#     `git commit` time and a fresh commit is normally pushed within hours.
#     A large gap here is the strongest signal of backdating.
#   - author vs committer: loose (30 days). Protects against false positives
#     from (a) rebasing an old branch onto a fresh base (author date stays
#     original, committer date is rewritten to now), (b) cherry-picking a
#     commit from months ago into a new branch, and (c) applying a patch
#     emailed/PR'd a long time before it lands (git am preserves author
#     date). All three legitimately produce a large author↔committer gap,
#     so we only flag egregious disagreement here.
# Note: push vs author is intentionally NOT checked — long-lived feature
# branches make old author dates against a recent push legitimate. The two
# checks above still cover the threat model: backdating both dates trips
# push↔committer; backdating only author trips author↔committer.
PUSH_COMMITTER_TOLERANCE=$(( 2 * 86400 ))
AUTHOR_COMMITTER_TOLERANCE=$(( 30 * 86400 ))
lie=false
lie_reasons=()

if [[ -n "$author_date" ]]; then
    author_epoch=$(date -d "$author_date" +%s)
fi
if [[ -n "$committer_date" ]]; then
    committer_epoch=$(date -d "$committer_date" +%s)
    d=$(( committer_epoch - pushed_epoch )); cdd=${d#-}
    if (( cdd > PUSH_COMMITTER_TOLERANCE )); then
        lie=true
        lie_reasons+=("committer date is $(( cdd / 86400 )) days from push date")
    fi
fi
if [[ -n "$author_date" && -n "$committer_date" ]]; then
    d=$(( author_epoch - committer_epoch )); acd=${d#-}
    if (( acd > AUTHOR_COMMITTER_TOLERANCE )); then
        lie=true
        lie_reasons+=("author and committer dates disagree by $(( acd / 86400 )) days")
    fi
fi

delta=$(( now_epoch - pushed_epoch ))
abs=${delta#-}

# Pick value+unit, then strip trailing "s" if the value is exactly 1.
if   (( abs < 60 ));       then n=$abs;                unit="seconds"
elif (( abs < 3600 ));     then n=$(( abs / 60 ));     unit="minutes"
elif (( abs < 86400 ));    then n=$(( abs / 3600 ));   unit="hours"
elif (( abs < 604800 ));   then n=$(( abs / 86400 ));  unit="days"
elif (( abs < 2592000 ));  then n=$(( abs / 604800 )); unit="weeks"
elif (( abs < 31536000 )); then n=$(( abs / 2592000 ));unit="months"
else                            n=$(( abs / 31536000 ));unit="years"
fi
(( n == 1 )) && unit="${unit%s}"
if (( delta < 0 )); then rel_value="$n $unit in the future"; else rel_value="$n $unit ago"; fi

if $lie; then lie_str="True"; else lie_str="False"; fi

# Longest label is "Commit lies about its date:" at 27 chars; pad every label
# to 28 (label + 1 space) so all values start at the same column.
LW=28
printf "%-${LW}s%s\n" "Repo:"              "$owner/$repo"
printf "%-${LW}s%s\n" "Commit:"            "$matched"
printf "%-${LW}s%s\n" "Push type:"         "$push_type"
printf "%-${LW}s%s\n" "Real Commit Date:"  "$pushed_local"
printf "%-${LW}s%s\n" "Commit was pushed:" "$rel_value"
echo
printf "%-${LW}s%s\n" "Commit lies about its date:" "$lie_str"

if $lie; then
    printf "%-${LW}s%s\n" "CLAIMED AUTHOR DATE:"    "$author_date"
    printf "%-${LW}s%s\n" "CLAIMED COMMITTER DATE:" "$committer_date"
    for r in "${lie_reasons[@]}"; do
        echo "  -> $r"
    done
fi

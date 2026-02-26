#!/usr/bin/env bash
# Usage: cifail URL [OUTPUT_DIR] [--debug]
# Example: ./cifail.sh "https://github.com/org/repo/actions/runs/123"

input_url="${1:-}"
base_out="${2:-/tmp}"
debug="${3:-}"

if [ -z "$input_url" ]; then
  echo "usage: cifail <github actions job-or-run url> [OUTPUT_DIR] [--debug]" >&2
  exit 2
fi

if [ "${base_out:-}" = "--debug" ]; then
  debug="--debug"
  base_out="/tmp"
fi
if [ "${debug:-}" = "--debug" ]; then
  set -x
fi

# Safer strict mode: no -u (unbound vars) to avoid hard exits from missing fields.
set -eo pipefail

# Error trap that prints line + command
trap 'rc=$?; echo "cifail: error (exit=$rc) at line $LINENO: $BASH_COMMAND" >&2; exit $rc' ERR

for bin in gh jq curl unzip; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found" >&2; exit 127; }
done

# Ensure gh is authenticated (gives a readable error if not)
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh not authenticated. Run: gh auth login" >&2
  exit 1
fi

_cif_sanitize() {
  echo "$1" | tr -c '[:alnum:].+_-' '_' | tr ' ' '_' | sed 's/_\{2,\}/_/g;s/^_//;s/_$//'
}

# Normalize URL to run URL and extract repo + run_id
cleaned="${input_url%%\?*}"
cleaned="${cleaned%%#*}"

if [[ "$cleaned" =~ ^https://github\.com/([^/]+/[^/]+)/actions/runs/([0-9]+)(/job/[0-9]+)?$ ]]; then
  repo="${BASH_REMATCH[1]}"
  run_id="${BASH_REMATCH[2]}"
  run_url="https://github.com/${repo}/actions/runs/${run_id}"
else
  echo "error: unsupported URL format: $input_url" >&2
  exit 2
fi

# Suppress xtrace for API calls and jq on large JSON to avoid crashing
# the terminal when --debug is used (set -x expands multi-MB variables).
{ _xtrace=false; [[ $- == *x* ]] && _xtrace=true; set +x; } 2>/dev/null

# Fetch run info (guard jq with //)
run_json="$(gh api -H "Accept: application/vnd.github+json" "repos/${repo}/actions/runs/${run_id}")"
run_name="$(jq -r '.name // .display_title // "workflow_run"' <<<"$run_json")"
head_sha="$(jq -r '.head_sha // ""' <<<"$run_json")"
event="$(jq -r '.event // ""' <<<"$run_json")"
created_at="$(jq -r '.created_at // ""' <<<"$run_json")"
updated_at="$(jq -r '.updated_at // ""' <<<"$run_json")"

# Fetch jobs
jobs_json="$(gh api --paginate -H "Accept: application/vnd.github+json" \
  "repos/${repo}/actions/runs/${run_id}/jobs?per_page=100" \
  | jq -s '[.[].jobs[]]')"
total_jobs="$(jq 'length' <<<"$jobs_json")"

overview="$(jq -r '
  sort_by(.name) |
  .[] |
  "\(.name)\t\((.conclusion // .status // "unknown"))"
' <<<"$jobs_json")"

# Determine failing jobs (only "failure" as requested)
failing_jobs_json="$(jq '[.[] | select(.conclusion == "failure")]' <<<"$jobs_json")"
failing_count="$(jq 'length' <<<"$failing_jobs_json")"

# Restore xtrace if it was on
{ $_xtrace && set -x; } 2>/dev/null

if [ "$failing_count" -eq 0 ]; then
  echo "Run: ${run_url}"
  echo "Repo: ${repo}"
  echo "Run ID: ${run_id}"
  [ -n "$head_sha" ] && [ "$head_sha" != "null" ] && echo "Head SHA: ${head_sha}"
  echo
  echo "CI jobs (${total_jobs}):"
  echo "$overview" | awk -F'\t' '{ printf "  - %s: %s\n", $1, $2 }'
  echo
  echo "Result: no failed jobs."
  exit 0
fi

# Output directories
ts="$(date -u +"%Y%m%d_%H%M%SZ")"
repo_slug="$(_cif_sanitize "$repo")"
run_slug="$(_cif_sanitize "$run_name")"
base_out="$(cd "$base_out" && pwd)"
outdir="${base_out%/}/cifail_${ts}_${repo_slug}_run${run_id}"
run_dir="${outdir}/run_${run_id}__${run_slug}"
mkdir -p "$run_dir"

# Save overview file immediately (even if downloads later fail)
{
  echo "Run URL: $run_url"
  echo "Repo: $repo"
  echo "Run ID: $run_id"
  echo "Run name: $run_name"
  echo "Head SHA: $head_sha"
  echo "Event: $event"
  echo "Created: $created_at"
  echo "Updated: $updated_at"
  echo
  echo "All jobs:"
  echo "$overview" | awk -F'\t' '{ printf "  - %s: %s\n", $1, $2 }'
  echo
  echo "Failing jobs: $failing_count"
} > "${run_dir}/overview.txt"

out_jobs='[]'

# Download logs for failing jobs; failure per job is recorded, not fatal
for ((j=0; j<failing_count; j++)); do
  # Suppress xtrace for jq on large JSON
  { _xt2=false; [[ $- == *x* ]] && _xt2=true; set +x; } 2>/dev/null
  job_id="$(jq -r ".[$j].id" <<<"$failing_jobs_json")"
  job_name="$(jq -r ".[$j].name" <<<"$failing_jobs_json")"
  job_html="$(jq -r ".[$j].html_url" <<<"$failing_jobs_json")"
  job_conclusion="$(jq -r ".[$j].conclusion" <<<"$failing_jobs_json")"
  job_started="$(jq -r ".[$j].started_at" <<<"$failing_jobs_json")"
  job_completed="$(jq -r ".[$j].completed_at" <<<"$failing_jobs_json")"

  job_slug="$(_cif_sanitize "$job_name")"
  job_prefix="${run_dir}/job_${job_id}__${job_slug}"
  zip_path="${job_prefix}.zip"
  log_path="${job_prefix}.log"
  headers_file="${job_prefix}__headers.txt"

  { $_xt2 && set -x; } 2>/dev/null

  bytes=0 ok=false err=""
  log_url=""

  # Get redirect URL
  if gh api -i -H "Accept: application/vnd.github+json" \
    "repos/${repo}/actions/jobs/${job_id}/logs" >"$headers_file" 2>/dev/null; then
    log_url="$(awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' "$headers_file" | tr -d '\r')"
  else
    # even if headers fetch fails, keep going
    err="gh_api_logs_failed"
  fi

  if [ -z "$err" ]; then
    if [ -z "${log_url:-}" ]; then
      err="no_location_header"
    elif ! curl -fsSL "$log_url" -o "$zip_path"; then
      err="download_failed"
    elif ! unzip -p "$zip_path" >"$log_path" 2>/dev/null; then
      err="unzip_failed"
    else
      bytes="$(wc -c <"$log_path" | tr -d ' ')"
      ok=true
    fi
  fi

  { _xt3=false; [[ $- == *x* ]] && _xt3=true; set +x; } 2>/dev/null
  out_jobs="$(jq -c \
    --argjson job_id "$job_id" \
    --arg job_name "$job_name" \
    --arg job_html "$job_html" \
    --arg job_conclusion "$job_conclusion" \
    --arg job_started "$job_started" \
    --arg job_completed "$job_completed" \
    --arg log_path "$log_path" \
    --arg zip_path "$zip_path" \
    --argjson log_bytes "$bytes" \
    --arg ok "$ok" \
    --arg err "$err" \
    '. + [{
      job_id: $job_id,
      name: $job_name,
      html_url: $job_html,
      conclusion: $job_conclusion,
      started_at: $job_started,
      completed_at: $job_completed,
      logs: {
        ok: ($ok == "true"),
        bytes: $log_bytes,
        log_path: $log_path,
        zip_path: $zip_path,
        error: (if $err == "" then null else $err end)
      }
    }]' <<<"$out_jobs")"
  { $_xt3 && set -x; } 2>/dev/null
done

{ _xt4=false; [[ $- == *x* ]] && _xt4=true; set +x; } 2>/dev/null
jq -n \
  --arg input_url "$input_url" \
  --arg run_url "$run_url" \
  --arg repo "$repo" \
  --argjson run_id "$run_id" \
  --arg run_name "$run_name" \
  --arg head_sha "$head_sha" \
  --arg event "$event" \
  --arg created_at "$created_at" \
  --arg updated_at "$updated_at" \
  --arg outdir "$outdir" \
  --arg run_dir "$run_dir" \
  --argjson total_jobs "$total_jobs" \
  --argjson failing_jobs_count "$failing_count" \
  --argjson failing_jobs "$out_jobs" \
  '{
    input_url: $input_url,
    run_url: $run_url,
    repo: $repo,
    run: {
      id: $run_id,
      name: $run_name,
      head_sha: (if $head_sha == "null" or $head_sha == "" then null else $head_sha end),
      event: (if $event == "null" or $event == "" then null else $event end),
      created_at: (if $created_at == "null" or $created_at == "" then null else $created_at end),
      updated_at: (if $updated_at == "null" or $updated_at == "" then null else $updated_at end)
    },
    output: {
      output_dir: $outdir,
      run_dir: $run_dir,
      overview_path: ($run_dir + "/overview.txt")
    },
    summary: {
      total_jobs: $total_jobs,
      failing_jobs: $failing_jobs_count
    },
    failing_jobs: $failing_jobs
  }'
{ $_xt4 && set -x; } 2>/dev/null

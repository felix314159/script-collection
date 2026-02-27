#!/usr/bin/env bash

main() {
    local url=$1
    if [[ -z "$url" ]]; then
        # $(basename "$0") gets the name of the script automatically
        echo "Usage: $(basename "$0") <pr-url>"
        return 1
    fi

    echo "Fetching commit list for PR..."

    local pr_data
    pr_data=$(gh pr view "$url" --json commits --jq '.commits[] | "\(.oid)\t\(.messageHeadline)"' 2>/dev/null)

    if [[ -z "$pr_data" ]]; then
        echo "Error: No commits found. Ensure you are authenticated with 'gh auth login' and the URL is valid."
        return 1
    fi

    local all_local=true
    local total_commits=0

    echo "----------------------------------------------------------------"
    printf "%-9s | %-7s | %s\n" "STATUS" "COMMIT" "MESSAGE"
    echo "----------------------------------------------------------------"

    while IFS=$'\t' read -r sha msg; do
        ((total_commits++))
        local short_sha="${sha:0:7}"

        local short_msg
        if ((${#msg} > 80)); then
            short_msg="${msg:0:80}..."
        else
            short_msg="$msg"
        fi

        if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
            printf "✅ Local  | %-7s | %s\n" "$short_sha" "$short_msg"
        else
            printf "❌ Miss   | %-7s | %s\n" "$short_sha" "$short_msg"
            all_local=false
        fi
    done < <(echo "$pr_data") 

    echo "----------------------------------------------------------------"

    if $all_local; then
        echo "🎉 All $total_commits commits from this PR are present in your local repository."
    else
        echo "⚠️ Some commits are missing (out of $total_commits total)."
        echo ""
        echo "💡 If you already ran 'git fetch' and they are still missing, your Git"
        echo "   repository might not be configured to download PRs from the remote."
        echo "   Run this command to configure all remotes, then fetch again:"
        echo ""
        echo '   for r in $(git remote); do git config --add remote."$r".fetch "+refs/pull/*/head:refs/remotes/$r/pr/*"; done; git fetch --all'
        echo ""
    fi
}

# Execute the main function, passing along any arguments provided to the script
main "$@"

#!/usr/bin/env bash
set -euo pipefail

dry_run=0

usage() {
    cat <<'EOF'
Usage: worktreeremove [--dry]

Force-remove all git worktrees for the current repository whose paths are under /tmp/.

Options:
  --dry      Print the git worktree remove commands without running them.
  -h, --help Show this help.
EOF
}

while (($#)); do
    case "$1" in
        --dry)
            dry_run=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'worktreeremove: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

git rev-parse --git-dir >/dev/null

remove_args=(worktree remove --force)

found=0
while IFS= read -r wt; do
    case "$wt" in
        /tmp/*)
            found=1
            if ((dry_run)); then
                printf 'git'
                printf ' %q' "${remove_args[@]}" "$wt"
                printf '\n'
            else
                git "${remove_args[@]}" "$wt"
            fi
            ;;
    esac
done < <(git worktree list --porcelain | awk '/^worktree / {print substr($0, 10)}')

if ((dry_run)) && ((! found)); then
    printf 'No /tmp/ worktrees found for this repository.\n'
fi

#!/usr/bin/env python3
"""Find and verify the hardcoded ReferenceSpec refspec for an EIP branch."""

from __future__ import annotations

import argparse
import ast
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# customize for your setup
#    local paths of both repo's (fetching latest once and then re-using avoids ratelimits of gh api)  # noqa: E501
DEFAULT_REPO_ROOT = Path("/home/user/Documents/execution-specs")
DEFAULT_EIPS_REPO_ROOT = Path("/home/user/Documents/EIPs")
#    git setup (e.g. u might have to replace 'eels' with 'origin' / 'upstream')
EIPS_REMOTE_REF = "eip/master"
GIT_REMOTE_BRANCH_NAME = "eels"  # for me that is ethereum/execution-specs

# EIPs whose per-EIP branches have been merged into forks/amsterdam.
# For these, resolve the refspec from that fork branch instead of the
# (no longer existing) per-EIP branches.
MERGED_INTO_AMSTERDAM = [
    "7708",
    "7778",
    "7843",
    "7928",
    "7954",
    "7976",
    "7981",
    "8024",
]
AMSTERDAM_FORK_BRANCH = "forks/amsterdam"
AMSTERDAM_FORK_NAME = "amsterdam"

# define colors
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
RED = "\033[31m"
RESET = "\033[0m"

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*m")


class RefspecFindError(RuntimeError):
    """Raised when the EIP refspec cannot be resolved unambiguously."""


class NoEelsBranchFoundError(RefspecFindError):
    """Raised when there is no EELS branch for the requested EIP."""


def parse_eip_numbers(raw_value: str) -> list[str]:
    """Parse a comma-separated list of EIP numbers."""
    numbers = [item.strip() for item in raw_value.split(",") if item.strip()]
    if not numbers:
        raise RefspecFindError("please provide at least one EIP number")
    return numbers


def resolve_repo_root(repo_root: str | None) -> Path:
    """Resolve the repo root for git commands."""
    if repo_root is not None:
        return Path(repo_root).expanduser().resolve()
    return DEFAULT_REPO_ROOT


def resolve_eips_repo_root() -> Path:
    """Return the local EIPs repository root."""
    return DEFAULT_EIPS_REPO_ROOT


def run_command(repo_root: Path, *args: str) -> str:
    """Run a command in the repo root and return its stdout."""
    result = subprocess.run(
        args,
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def fetch_remote(repo_root: Path, remote: str) -> None:
    """Refresh the remote-tracking refs before resolving the EIP branch."""
    subprocess.run(
        ("git", "fetch", remote),
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )


def candidate_branch_refs(
    repo_root: Path, eip_number: str, remote: str
) -> list[str]:
    """Return matching EIP branch refs for the requested remote."""
    output = run_command(
        repo_root,
        "git",
        "for-each-ref",
        "--format=%(refname:short)",
        f"refs/remotes/{remote}/eips/*/eip-{eip_number}",
    )
    return [line for line in output.splitlines() if line]


def preferred_branch_ref(eip_number: str, remote: str) -> str | None:
    """Return a preferred branch ref for EIPs with a known canonical fork."""
    if eip_number == "7805":
        return f"{remote}/eips/amsterdam/eip-{eip_number}"
    return None


def extract_fork(branch_ref: str) -> str:
    """Extract the fork segment from an EIP branch ref."""
    parts = branch_ref.split("/")
    if "eips" not in parts:
        raise RefspecFindError(
            f"unable to determine fork from branch ref: {branch_ref}"
        )

    eips_index = parts.index("eips")
    try:
        return parts[eips_index + 1]
    except IndexError as exc:
        raise RefspecFindError(
            f"unable to determine fork from branch ref: {branch_ref}"
        ) from exc


def resolve_branch_ref(
    repo_root: Path,
    eip_number: str,
    remote: str,
    branch: str | None,
) -> tuple[str, str]:
    """Resolve the unique EIP branch ref and its fork."""
    if branch is not None:
        return branch, extract_fork(branch)

    if eip_number in MERGED_INTO_AMSTERDAM:
        return f"{remote}/{AMSTERDAM_FORK_BRANCH}", AMSTERDAM_FORK_NAME

    matches = candidate_branch_refs(repo_root, eip_number, remote)
    if not matches:
        raise NoEelsBranchFoundError
    if len(matches) > 1:
        preferred_ref = preferred_branch_ref(eip_number, remote)
        if preferred_ref in matches:
            return preferred_ref, extract_fork(preferred_ref)
        choices = "\n".join(f"  - {match}" for match in matches)
        raise RefspecFindError(
            f"multiple {remote} EIP branches found "
            f"for EIP-{eip_number}:\n{choices}\n"
            "rerun with --branch to choose one"
        )

    branch_ref = matches[0]
    return branch_ref, extract_fork(branch_ref)


def find_spec_path(
    repo_root: Path, branch_ref: str, fork: str, eip_number: str
) -> str:
    """Locate the EIP spec.py file on the target branch."""
    output = run_command(
        repo_root,
        "git",
        "ls-tree",
        "-r",
        "--name-only",
        branch_ref,
        f"tests/{fork}",
    )
    matches = [
        path
        for path in output.splitlines()
        if path.startswith(f"tests/{fork}/eip{eip_number}")
        and path.endswith("/spec.py")
    ]

    if not matches:
        raise RefspecFindError(
            f"no spec.py found for EIP-{eip_number} under "
            f"tests/{fork} on {branch_ref}"
        )
    if len(matches) > 1:
        choices = "\n".join(f"  - {match}" for match in matches)
        raise RefspecFindError(
            f"multiple spec.py files found for EIP-{eip_number} "
            f"on {branch_ref}:\n{choices}"
        )

    return matches[0]


def extract_reference_spec_version(
    repo_root: Path, branch_ref: str, spec_path: str
) -> str:
    """Extract the ReferenceSpec.version string from the target spec.py."""
    source = run_command(repo_root, "git", "show", f"{branch_ref}:{spec_path}")
    module = ast.parse(source, filename=spec_path)

    for node in module.body:
        if not isinstance(node, ast.Assign):
            continue
        if not isinstance(node.value, ast.Call):
            continue

        call = node.value
        if (
            not isinstance(call.func, ast.Name)
            or call.func.id != "ReferenceSpec"
        ):
            continue

        for keyword in call.keywords:
            if keyword.arg == "version":
                version = ast.literal_eval(keyword.value)
                if isinstance(version, str):
                    return version
                break

        if len(call.args) >= 2:
            version = ast.literal_eval(call.args[1])
            if isinstance(version, str):
                return version

    raise RefspecFindError(
        f"no ReferenceSpec.version found in {branch_ref}:{spec_path}"
    )


def run_refspec(eip_number: str) -> str:
    """Return the current local EIPs blob hash for the EIP markdown file."""
    eips_repo_root = resolve_eips_repo_root()
    return run_command(
        eips_repo_root,
        "git",
        "rev-parse",
        f"{EIPS_REMOTE_REF}:EIPS/eip-{eip_number}.md",
    )


def resolve_current_eip_commit(eip_number: str) -> str:
    """Return the latest EIPs commit SHA touching the EIP markdown file."""
    eips_repo_root = resolve_eips_repo_root()
    return run_command(
        eips_repo_root,
        "git",
        "log",
        "-n",
        "1",
        "--format=%H",
        EIPS_REMOTE_REF,
        "--",
        f"EIPS/eip-{eip_number}.md",
    )


def format_github_commit_date(date_value: str | None) -> str:
    """Format an ISO timestamp as `yy-mm-dd, hh:mm`."""
    if not date_value:
        return "??-??-??, ??:??"

    try:
        parsed = datetime.fromisoformat(date_value.replace("Z", "+00:00"))
    except ValueError:
        return "??-??-??, ??:??"

    return parsed.strftime("%y-%m-%d, %H:%M")


def shorten_commit_sha(commit_sha: str) -> str:
    """Return the short display form of a commit SHA."""
    return commit_sha[:7]


def resolve_missed_eip_commits(
    eip_number: str, eels_refspec: str
) -> tuple[str, list[tuple[str, str, str]]] | None:
    """Return the matched EELS commit SHA and later commits, newest first."""
    eips_repo_root = resolve_eips_repo_root()
    path_in_repo = f"EIPS/eip-{eip_number}.md"
    missed_commits: list[tuple[str, str, str]] = []
    log_output = run_command(
        eips_repo_root,
        "git",
        "log",
        EIPS_REMOTE_REF,
        "--format=%H%x1f%cI%x1f%s",
        "--",
        path_in_repo,
    )
    if not log_output:
        return None

    for line in log_output.splitlines():
        parts = line.split("\x1f", 2)
        if len(parts) != 3:
            continue

        commit_sha, date_value, subject = parts
        formatted_date = format_github_commit_date(date_value)
        try:
            blob_sha = run_command(
                eips_repo_root,
                "git",
                "rev-parse",
                f"{commit_sha}:{path_in_repo}",
            )
        except subprocess.CalledProcessError:
            return None

        if blob_sha == eels_refspec:
            return commit_sha, missed_commits

        missed_commits.append(
            (formatted_date, commit_sha, subject or "(no message)")
        )

    return None


def build_parser() -> argparse.ArgumentParser:
    """Build the CLI parser."""
    parser = argparse.ArgumentParser(
        description=(
            "Find the hardcoded ReferenceSpec.version for an EIP branch and "
            "compare it with `refspec <EIP>`."
        )
    )
    parser.add_argument(
        "eip_numbers",
        help="EIP number or comma-separated EIP numbers, for example 7981 or 7981,8024,7976",  # noqa: E501
    )
    parser.add_argument(
        "--remote",
        default=GIT_REMOTE_BRANCH_NAME,
        help="Git remote to inspect for EELS EIP branches",
    )
    parser.add_argument(
        "--branch",
        help="Explicit branch ref to inspect, for example eels/eips/amsterdam/eip-7981",  # noqa: E501
    )
    parser.add_argument(
        "--repo-root",
        help=f"Path to the execution-specs checkout (default: {DEFAULT_REPO_ROOT}",  # noqa: E501
    )
    parser.add_argument(
        "--no-fetch",  # we only fetch both remotes once, then use no-fetch for any further EIPs  # noqa: E501
        action="store_true",
        help="Skip fetching both the EELS and EIPs repositories before resolving the EIP branch",  # noqa: E501
    )
    return parser


def build_separator(width: int) -> str:
    """Build a dark blue separator line with the requested width."""
    return f"{BLUE}{'=' * width}{RESET}"


def visible_length(line: str) -> int:
    """Return the visible length of a line without ANSI color codes."""
    return len(ANSI_ESCAPE_RE.sub("", line))


def check_eip(
    repo_root: Path, eip_number: str, remote: str, branch: str | None
) -> tuple[list[str], int]:
    """Check a single EIP and return its output lines and exit status."""
    try:
        branch_ref, fork = resolve_branch_ref(
            repo_root, eip_number, remote, branch
        )
        spec_path = find_spec_path(repo_root, branch_ref, fork, eip_number)
        eels_refspec = extract_reference_spec_version(
            repo_root, branch_ref, spec_path
        )
        eips_refspec = run_refspec(eip_number)
        eips_commit_sha = resolve_current_eip_commit(eip_number)
    except NoEelsBranchFoundError:
        return [
            f"EIP-{eip_number}: No EELS branch found, don't worry about it"
        ], 0
    except RefspecFindError as exc:
        return [f"{RED}EIP-{eip_number}: {exc}{RESET}"], 1
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip() if exc.stderr else str(exc)
        return [f"{RED}EIP-{eip_number}: {stderr}{RESET}"], exc.returncode or 1

    commit_mapping = resolve_missed_eip_commits(eip_number, eels_refspec)
    if commit_mapping is None:
        eels_line = f"EELS: {eels_refspec}"
        missed_commits = None
    else:
        eels_commit_sha, missed_commits = commit_mapping
        eels_line = f"EELS: {eels_refspec} (commit: {shorten_commit_sha(eels_commit_sha)})"  # noqa: E501

    lines = [
        f"EIP-{eip_number}",
        eels_line,
        f"EIPs: {eips_refspec} (commit: {shorten_commit_sha(eips_commit_sha)})",  # noqa: E501
    ]

    if eels_refspec != eips_refspec:
        lines.append(
            f"{YELLOW}Mismatch! Please update the respective "
            f"EIP branch if necessary!{RESET}"
        )
        if missed_commits is None:
            lines.append(
                f"{RED}Could not map the EELS refspec to "
                f"local EIPs commit history.{RESET}"
            )
        else:
            lines.append(
                f"{YELLOW}Missed EIP commits: {len(missed_commits)}{RESET}"
            )
            for formatted_date, commit_sha, subject in missed_commits:
                short_sha = shorten_commit_sha(commit_sha)
                lines.append(
                    f"{YELLOW}- {formatted_date} {RESET}{short_sha}{YELLOW} {subject}{RESET}"  # noqa: E501
                )
        lines.append(
            f"-> https://github.com/ethereum/EIPs/commits/master/EIPS/eip-{eip_number}.md"
        )
        return lines, 1

    lines.append(f"{GREEN}Up-to-date!{RESET}")
    return lines, 0


def main() -> int:
    """CLI entry point."""
    parser = build_parser()
    args = parser.parse_args()
    repo_root = resolve_repo_root(args.repo_root)
    eip_numbers = parse_eip_numbers(args.eip_numbers)

    try:
        if not args.no_fetch:
            print("Fetching latest EELS remote..", flush=True)
            fetch_remote(repo_root, args.remote)
            print("Fetching latest EIPs remote..", flush=True)
            fetch_remote(resolve_eips_repo_root(), "eip")
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip() if exc.stderr else str(exc)
        print(stderr, file=sys.stderr)
        return exc.returncode or 1

    blocks: list[tuple[list[str], int]] = []
    overall_status = 0
    for eip_number in eip_numbers:
        lines, status = check_eip(
            repo_root, eip_number, args.remote, args.branch
        )
        blocks.append((lines, status))
        if status != 0:
            overall_status = 1

    separator_width = max(
        visible_length(line) for lines, _ in blocks for line in lines
    )
    separator = build_separator(separator_width)

    print(separator)
    for lines, _ in blocks:
        for line in lines:
            print(line)
        print(separator)

    return overall_status


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Find non-whitelisted Unicode characters in text files."""

from __future__ import annotations

import os
import sys
import time
from collections import Counter
from pathlib import Path

SELF_PATH = Path(__file__).resolve()
COMMON_UNICODE_THRESHOLD = 5

# Hardcoded directories to ignore completely, recursively.
# Add absolute or relative paths here.
IGNORED_DIRS = [
    ".git",
    ".venv",
    ".vscode",
    "venv",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".tox",
    "node_modules",
    "dist",
    "build",
    "fixtures",
    "logs",
]

# Hardcoded file extensions to ignore
IGNORED_FILETYPES = []  # e.g. ".txt",

# Hardcoded non-ASCII characters to allow anywhere without flagging.
# Add exact characters here, such as emoji you want to permit.
WHITELISTED_UNICODE_CHARS = [
    "✅",
    "❌",
    "🔥",
    "💥",
    "🚀",
    "❓",
    "🤝",
    "🔗",
    "🚨",
    "💡",
    "🛠",
    "✨",
    "🐞",
    "🔁",
    "🔀",
    "📄",
    "📁",
    "📂",
    "🟢",
    "🟡",
    "🔴",
    "🎉",
    "🧪",
    "📋",
    "🐍",
    "🐘",
    "🗑",
    "⚠",
    "►",
    "→",
    "✓",
    "✗",
    "┌",
    "┬",
    "┘",
    "┌",
    "├",
    "┤",
    "├",
    "┼",
    "│",
    "┴",
    "└",
    "┐",
    "╔",
    "╗",
    "╚",
    "╝",
    "±",
    "²",
    "³",
    "≡",
    "═",
    "≤",
    "≥",
    "≠",
    "≈",
    "─",
    "—",
    "ł",
    "’",
    "\xa0",  # more than 160 occurrences in our codebase after applying filters
]

IGNORED_FILETYPES_SET = {ext.lower() for ext in IGNORED_FILETYPES}
WHITELISTED_UNICODE_CHARS_SET = set(WHITELISTED_UNICODE_CHARS)


def normalize_ignore_paths(root: Path, ignored_dirs: list[str]) -> set[Path]:
    """Resolve ignored directory entries relative to the scan root."""
    ignored: set[Path] = set()

    for entry in ignored_dirs:
        p = Path(entry)
        if not p.is_absolute():
            p = (root / p).resolve()
        else:
            p = p.resolve()
        ignored.add(p)

    return ignored


def is_ignored_path(path: Path, ignored_paths: set[Path]) -> bool:
    """Return whether a path should be skipped entirely."""
    path = path.resolve()
    for ignored in ignored_paths:
        if path == ignored or ignored in path.parents:
            return True
    return False


def is_ignored_filetype(path: Path) -> bool:
    """Return whether a path has an ignored suffix."""
    return path.suffix.lower() in IGNORED_FILETYPES_SET


def is_binary_file(path: Path) -> bool:
    """Best-effort check for binary files based on NUL bytes."""
    try:
        with path.open("rb") as f:
            chunk = f.read(4096)
        return b"\x00" in chunk
    except Exception:
        return True


def scan_file(path: Path) -> list[tuple[int, int, str, str]]:
    """Collect non-whitelisted Unicode findings for one file."""
    findings: list[tuple[int, int, str, str]] = []

    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, 1):
                for colno, ch in enumerate(line, 1):
                    if (
                        ord(ch) > 127
                        and ch not in WHITELISTED_UNICODE_CHARS_SET
                    ):
                        findings.append(
                            (lineno, colno, ch, f"U+{ord(ch):04X}")
                        )
    except Exception as e:
        print(f"ERROR reading {path}: {e}", file=sys.stderr)

    return findings


def print_summary(
    total_findings: int,
    scanned_files: int,
    files_with_findings: set[Path],
    char_counts: Counter[str],
    elapsed_seconds: float,
) -> None:
    """Print aggregated counts for the full scan."""
    print()
    print(
        "Summary:"
        f" {total_findings} non-whitelisted unicode character"
        f"{'' if total_findings == 1 else 's'} found in"
        f" {len(files_with_findings)} file"
        f"{'' if len(files_with_findings) == 1 else 's'}."
    )
    print(
        f"Scanned {scanned_files} file"
        f"{'' if scanned_files == 1 else 's'} in"
        f" {elapsed_seconds:.3f} seconds."
    )
    print(
        "Most common unicode chars "
        f"(minimum {COMMON_UNICODE_THRESHOLD} occurrences):"
    )

    common_chars = [
        (ch, count)
        for ch, count in sorted(
            char_counts.items(),
            key=lambda item: (-item[1], ord(item[0])),
        )
        if count >= COMMON_UNICODE_THRESHOLD
    ]

    if not common_chars:
        print("  none")
        return

    for ch, count in common_chars:
        print(f"  U+{ord(ch):04X} {ch!r}: {count}")


def iter_files(root: Path, ignored_paths: set[Path]):
    """Yield non-ignored, non-binary files beneath the root."""
    for dirpath, dirnames, filenames in os.walk(root):
        current_dir = Path(dirpath).resolve()

        dirnames[:] = [
            d
            for d in dirnames
            if not is_ignored_path(current_dir / d, ignored_paths)
        ]

        for filename in filenames:
            path = current_dir / filename

            if is_ignored_path(path, ignored_paths):
                continue
            if is_ignored_filetype(path):
                continue
            if is_binary_file(path):
                continue

            yield path


def main() -> int:
    """Run the Unicode scan and report detailed and aggregated findings."""
    start_time = time.perf_counter()
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

    if not root.exists():
        print(f"ERROR: path does not exist: {root}", file=sys.stderr)
        return 2

    ignored_paths = normalize_ignore_paths(root, IGNORED_DIRS)
    ignored_paths.add(SELF_PATH)

    found_any = False
    scanned_files = 0
    total_findings = 0
    files_with_findings: set[Path] = set()
    char_counts: Counter[str] = Counter()

    if root.is_file():
        if (
            not is_ignored_path(root, ignored_paths)
            and not is_ignored_filetype(root)
            and not is_binary_file(root)
        ):
            scanned_files += 1
            findings = scan_file(root)
            for lineno, colno, ch, codepoint in findings:
                found_any = True
                total_findings += 1
                files_with_findings.add(root)
                char_counts[ch] += 1
                print(f"{root}:{lineno}:{colno}: {codepoint} {ch!r}")
    else:
        for path in iter_files(root, ignored_paths):
            scanned_files += 1
            findings = scan_file(path)
            for lineno, colno, ch, codepoint in findings:
                found_any = True
                total_findings += 1
                files_with_findings.add(path)
                char_counts[ch] += 1
                print(f"{path}:{lineno}:{colno}: {codepoint} {ch!r}")

    print_summary(
        total_findings,
        scanned_files,
        files_with_findings,
        char_counts,
        time.perf_counter() - start_time,
    )

    return 1 if found_any else 0


if __name__ == "__main__":
    raise SystemExit(main())

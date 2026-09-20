#!/usr/bin/env python3
"""Verify that every relative link in tracked Markdown files resolves.

`docs/README.md` requires the documentation set to stay mutually consistent, and
`AGENTS.md` §7 lists link checking among the mandatory checks. Running it in CI
stops a renamed or moved document from silently breaking the navigation that the
authority order depends on.

Design notes:

* Only files tracked by Git are examined, so build output, the Flutter SDK
  checkout and dependency caches cannot produce noise.
* External links are not fetched. CI must not depend on third-party sites being
  reachable, and a transient network failure must not fail the build.
* Percent-encoded paths and `#anchors` are handled, because document names in this
  repository contain non-ASCII characters.

Usage:
    python3 tooling/checks/check_links.py [--root PATH] [--verbose]

Exit codes: 0 all links resolve, 1 at least one broken link, 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

# `[text](target)` and `[text](target "title")`, plus the image form `![alt](src)`.
LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)>\s]+)>?(?:\s+\"[^\"]*\")?\s*\)")

# Fenced code blocks and inline code spans are removed before links are extracted.
# Documentation legitimately *shows* link syntax as an example, and an example is
# not a link: treating `[text](target "title")` inside backticks as a real target
# produced a false failure the first time this check ran in CI. HTML comments are
# removed for the same reason.
FENCED_CODE_RE = re.compile(r"^[ \t]*(?:```|~~~).*?^[ \t]*(?:```|~~~)[ \t]*$", re.DOTALL | re.MULTILINE)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)

EXTERNAL_SCHEMES = ("http:", "https:", "mailto:", "tel:", "data:")


def strip_non_link_text(text: str) -> str:
    """Remove regions where link syntax is illustrative rather than real."""
    text = FENCED_CODE_RE.sub("", text)
    text = HTML_COMMENT_RE.sub("", text)
    text = INLINE_CODE_RE.sub("", text)
    return text


def tracked_markdown(root: Path) -> list[Path]:
    """Return every Markdown file tracked by Git, as paths relative to root."""
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--", "*.md", "*.markdown"],
            check=True,
            capture_output=True,
        )
    except FileNotFoundError:
        print("ERROR: git is required but was not found on PATH", file=sys.stderr)
        raise SystemExit(2)
    except subprocess.CalledProcessError as exc:
        print(f"ERROR: git ls-files failed: {exc.stderr.decode(errors='replace')}", file=sys.stderr)
        raise SystemExit(2)

    names = [n for n in result.stdout.decode("utf-8").split("\0") if n]
    return [root / n for n in names]


def untracked_markdown(root: Path) -> list[str]:
    """Markdown files present in the working tree but not tracked by Git."""
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "-z",
                "--others",
                "--exclude-standard",
                "--",
                "*.md",
                "*.markdown",
            ],
            check=True,
            capture_output=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return []

    return [n for n in result.stdout.decode("utf-8").split("\0") if n]


def check_file(path: Path, root: Path) -> list[str]:
    """Return a list of problem descriptions for one Markdown file."""
    problems: list[str] = []
    text = strip_non_link_text(path.read_text(encoding="utf-8"))

    for match in LINK_RE.finditer(text):
        raw = match.group(1)
        if not raw or raw.startswith("#"):
            continue
        if raw.startswith(EXTERNAL_SCHEMES):
            continue

        split = urlsplit(raw)
        target = unquote(split.path)
        if not target:
            # Pure anchor inside the same document.
            continue

        # A link may be written from the repository root.
        candidate = (path.parent / target).resolve()
        if not candidate.exists():
            root_relative = (root / target.lstrip("/")).resolve()
            if root_relative.exists():
                continue
            problems.append(f"{path.relative_to(root).as_posix()} -> {raw}")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=".",
        help="repository root (default: current directory)",
    )
    parser.add_argument("--verbose", action="store_true", help="list every file checked")
    parser.add_argument(
        "--strict",
        action="store_true",
        help=(
            "fail when untracked Markdown exists instead of only warning. Use this "
            "from the local check entry point: a verdict that does not cover the "
            "working tree is misleading, and staging the file is a one-line fix."
        ),
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not (root / ".git").exists():
        print(f"ERROR: {root} is not a Git working tree", file=sys.stderr)
        return 2

    files = tracked_markdown(root)
    if not files:
        print("ERROR: no tracked Markdown files found", file=sys.stderr)
        return 2

    total_links = 0
    problems: list[str] = []
    for path in files:
        file_problems = check_file(path, root)
        problems.extend(file_problems)
        if args.verbose:
            status = "FAIL" if file_problems else "ok"
            print(f"  [{status}] {path.relative_to(root).as_posix()}")
        total_links += len(
            LINK_RE.findall(strip_non_link_text(path.read_text(encoding="utf-8")))
        )

    print(f"checked {len(files)} Markdown files, {total_links} links")

    # Only tracked files are checked. That is the right scope for CI, but locally it
    # means a new document is invisible until it is staged - which is exactly how a
    # broken link reached CI twice. Say so loudly, and carry the caveat into the
    # verdict line too, because a truncated log can easily hide a notice above it.
    untracked = untracked_markdown(root)
    if untracked:
        print(
            f"\nWARNING: {len(untracked)} untracked Markdown file(s) were NOT "
            "checked. Stage them to include them:\n"
        )
        for name in untracked:
            print(f"  {name}")

    if problems:
        print(f"\nBROKEN LINKS ({len(problems)}):")
        for problem in problems:
            print(f"  {problem}")
        return 1

    if untracked and args.strict:
        print(
            "\nFAILED: untracked Markdown is not covered by this check. Stage the "
            "files or run without --strict to get a tracked-only verdict."
        )
        return 1

    coverage = (
        'tracked files only - see the warning above'
        if untracked
        else 'all tracked Markdown'
    )
    print(f"no broken relative links ({coverage})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

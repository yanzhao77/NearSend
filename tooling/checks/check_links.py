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

EXTERNAL_SCHEMES = ("http:", "https:", "mailto:", "tel:", "data:")


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


def check_file(path: Path, root: Path) -> list[str]:
    """Return a list of problem descriptions for one Markdown file."""
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")

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
        total_links += len(LINK_RE.findall(path.read_text(encoding="utf-8")))

    print(f"checked {len(files)} Markdown files, {total_links} links")

    if problems:
        print(f"\nBROKEN LINKS ({len(problems)}):")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print("all relative links resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Fail if credential material looks like it has been committed.

`AGENTS.md` §5 forbids private keys, recovery secrets, access tokens and signing
credentials from entering ordinary source, logs or test snapshots, and §7 lists a
sensitive-information check among the mandatory checks.

Design notes:

* Only files tracked by Git are examined. Build output, caches and the Flutter SDK
  checkout are irrelevant and would only produce noise.
* Binary files are skipped: a compiled artefact legitimately contains byte
  sequences that look like key headers.
* Findings are **redacted** before printing. A scanner that echoes the secret it
  found turns the CI log into a new leak, which is exactly what this check exists
  to prevent.
* Short values are never reported from the generic assignment patterns; they would
  match ordinary configuration such as `password="false"` in a UI dump.

Usage:
    python3 tooling/checks/check_secrets.py [--root PATH] [--verbose]

Exit codes: 0 clean, 1 findings, 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# A line carrying this marker is skipped, so documentation may show a token
# format on purpose. The marker is visible in review and easy to grep for.
ALLOW_MARKER = "nearsend-secret-scan: allow"

# Every pattern targets a concrete credential shape. Avoid broad
# "looks random" heuristics here: false positives train people to ignore the check.
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("GitHub fine-grained token", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("AWS access key id", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("OpenAI-style key", re.compile(r"\bsk-[A-Za-z0-9]{32,}\b")),
    (
        "JWT",
        re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    ),
    (
        "assigned secret literal",
        re.compile(
            r"(?i)\b(?:api[_-]?key|secret|passwd|password|access[_-]?token|"
            r"client[_-]?secret|private[_-]?key)\b\s*[=:]\s*[\"'][A-Za-z0-9+/_\-]{16,}[\"']"
        ),
    ),
    (
        "Android signing property",
        re.compile(r"(?i)\bstorePassword\s*=\s*\S{8,}"),
    ),
]

MAX_BYTES = 4 * 1024 * 1024


def tracked_files(root: Path) -> list[Path]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z"],
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


def is_binary(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return b"\0" in handle.read(8192)
    except OSError:
        return True


def redact(text: str) -> str:
    """Describe a match without reproducing it."""
    keep = 4
    if len(text) <= keep:
        return f"<{len(text)} chars>"
    return f"{text[:keep]}...<{len(text)} chars>"


def scan_file(path: Path, root: Path) -> list[str]:
    try:
        if path.stat().st_size > MAX_BYTES:
            return []
    except OSError:
        return []
    if is_binary(path):
        return []

    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []

    findings: list[str] = []
    relative = path.relative_to(root).as_posix()

    for number, line in enumerate(text.splitlines(), start=1):
        if ALLOW_MARKER in line:
            continue
        for name, pattern in PATTERNS:
            for match in pattern.finditer(line):
                findings.append(f"{relative}:{number}: {name}: {redact(match.group(0))}")

    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    parser.add_argument("--verbose", action="store_true", help="report how many files were scanned")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not (root / ".git").exists():
        print(f"ERROR: {root} is not a Git working tree", file=sys.stderr)
        return 2

    files = tracked_files(root)
    if not files:
        print("ERROR: no tracked files found", file=sys.stderr)
        return 2

    findings: list[str] = []
    scanned = 0
    for path in files:
        if not path.is_file():
            continue
        scanned += 1
        findings.extend(scan_file(path, root))

    if args.verbose:
        print(f"scanned {scanned} tracked files")

    if findings:
        print(f"SENSITIVE INFORMATION FOUND ({len(findings)}):")
        for finding in findings:
            print(f"  {finding}")
        print(
            "\nRemove the value, rotate the credential, and use platform secure "
            "storage or a protected CI secret instead (AGENTS.md section 5)."
        )
        return 1

    print(f"no credential material found in {scanned} tracked files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

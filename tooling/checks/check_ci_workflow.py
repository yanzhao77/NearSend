#!/usr/bin/env python3
"""Enforce the invariants that .github/workflows/ci.yml claims in its own comments.

Claims in a comment are not guarantees. This check turns them into something CI
verifies, so a later edit cannot quietly weaken the gate:

* every `uses:` is pinned to a full commit SHA - a moved tag would silently change
  what executes with access to this repository;
* no `continue-on-error` key exists - a gate that cannot fail is not a gate;
* workflow permissions stay read-only - nothing here needs to write to the repo;
* the pinned Flutter version matches the one in tooling/ci/install_flutter.sh, so
  the workflow environment and the installer cannot drift apart.

Written with the standard library only. Adding PyYAML would mean CI installing a
dependency to check a file whose shape is known, which is a poor trade for a
project that gates every new dependency.

Usage:
    python3 tooling/checks/check_ci_workflow.py [--root PATH]

Exit codes: 0 clean, 1 violations, 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

WORKFLOW_RELATIVE = Path(".github/workflows/ci.yml")
INSTALLER_RELATIVE = Path("tooling/ci/install_flutter.sh")

USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*(\S+)(?:\s+#.*)?$")
SHA_PIN_RE = re.compile(r"^[^@]+@[0-9a-f]{40}$")
CONTINUE_ON_ERROR_RE = re.compile(r"^\s*continue-on-error\s*:")
PERMISSIONS_RE = re.compile(r"^permissions:\s*$")
FLUTTER_VERSION_ENV_RE = re.compile(r"^\s*FLUTTER_VERSION:\s*['\"]?([0-9][^'\"\s]*)['\"]?\s*$")
FLUTTER_VERSION_SH_RE = re.compile(r"^FLUTTER_VERSION=\"([^\"]+)\"")


def check_workflow(root: Path) -> list[str]:
    workflow_path = root / WORKFLOW_RELATIVE
    installer_path = root / INSTALLER_RELATIVE

    if not workflow_path.is_file():
        return [f"{WORKFLOW_RELATIVE.as_posix()} does not exist"]
    if not installer_path.is_file():
        return [f"{INSTALLER_RELATIVE.as_posix()} does not exist"]

    lines = workflow_path.read_text(encoding="utf-8").splitlines()
    problems: list[str] = []

    uses_count = 0
    for number, line in enumerate(lines, start=1):
        match = USES_RE.match(line)
        if match:
            uses_count += 1
            reference = match.group(1)
            if not SHA_PIN_RE.match(reference):
                problems.append(
                    f"{WORKFLOW_RELATIVE.as_posix()}:{number}: 'uses: {reference}' is not "
                    "pinned to a 40-character commit SHA"
                )

        if CONTINUE_ON_ERROR_RE.match(line):
            problems.append(
                f"{WORKFLOW_RELATIVE.as_posix()}:{number}: 'continue-on-error' would let a "
                "failing check pass"
            )

    if uses_count == 0:
        problems.append(
            f"{WORKFLOW_RELATIVE.as_posix()}: no 'uses:' entries found; the CI workflow "
            "appears to have been emptied"
        )

    # Permissions must be declared and read-only.
    permission_lines: list[str] = []
    for index, line in enumerate(lines):
        if PERMISSIONS_RE.match(line):
            base_indent = len(line) - len(line.lstrip())
            for follower in lines[index + 1:]:
                if not follower.strip():
                    continue
                indent = len(follower) - len(follower.lstrip())
                if indent <= base_indent:
                    break
                permission_lines.append(follower.strip())
    if not permission_lines:
        problems.append(
            f"{WORKFLOW_RELATIVE.as_posix()}: no top-level 'permissions:' block; the default "
            "token permissions are broader than this workflow needs"
        )
    for entry in permission_lines:
        if not re.match(r"^[A-Za-z-]+:\s*(read|none)\s*$", entry):
            problems.append(
                f"{WORKFLOW_RELATIVE.as_posix()}: permission '{entry}' is neither read nor none"
            )

    # The pinned Flutter version must be identical in both places.
    workflow_versions = {
        match.group(1) for line in lines if (match := FLUTTER_VERSION_ENV_RE.match(line))
    }
    installer_versions = {
        match.group(1)
        for line in installer_path.read_text(encoding="utf-8").splitlines()
        if (match := FLUTTER_VERSION_SH_RE.match(line))
    }

    if not workflow_versions:
        problems.append(
            f"{WORKFLOW_RELATIVE.as_posix()}: no FLUTTER_VERSION env value found"
        )
    if not installer_versions:
        problems.append(
            f"{INSTALLER_RELATIVE.as_posix()}: no FLUTTER_VERSION assignment found"
        )
    if workflow_versions and installer_versions and workflow_versions != installer_versions:
        problems.append(
            "Flutter version mismatch: workflow declares "
            f"{sorted(workflow_versions)} but {INSTALLER_RELATIVE.as_posix()} installs "
            f"{sorted(installer_versions)}"
        )

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    problems = check_workflow(root)

    if problems:
        print(f"CI WORKFLOW VIOLATIONS ({len(problems)}):")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print("CI workflow invariants hold (SHA-pinned actions, no continue-on-error, "
          "read-only permissions, Flutter version pinned consistently)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

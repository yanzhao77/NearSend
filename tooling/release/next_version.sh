#!/usr/bin/env bash
# Calculate the next patch release from the repository's version and tags.
# Usage: next_version.sh [base-version]

set -euo pipefail

base_version="${1:-$(sed -En 's/^version: *([0-9]+\.[0-9]+\.[0-9]+)(\+.*)?$/\1/p' pubspec.yaml | head -n 1)}"
if [[ ! "$base_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid base version: $base_version" >&2
  exit 1
fi

latest_tag="$(git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
if [ -n "$latest_tag" ]; then
  latest_version="${latest_tag#v}"
else
  latest_version="$base_version"
fi

IFS=. read -r major minor patch <<< "$latest_version"
printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"

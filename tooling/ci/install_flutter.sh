#!/usr/bin/env bash
#
# Install the pinned Flutter SDK, verifying the archive digest before extracting.
#
# Why a script instead of a third-party Action:
#   * AGENTS.md §3 requires a pinned, reproducible build toolchain, and §7 requires
#     dependency locks. The version and digest live here, in reviewable source.
#   * `docs/architecture/APP_AND_SERVICE_DESIGN.md` §12 requires recording purpose,
#     alternatives, maintenance status, licence and security impact before adding a
#     dependency. Installing from the vendor's own release bucket, digest-verified,
#     avoids adding a third-party Action to the supply chain for a single job.
#
# The digests are the values published in the Flutter release metadata
# (releases_<os>.json). The Windows digest was additionally cross-checked against a
# locally downloaded archive that was hashed independently.
#
# Usage: bash tooling/ci/install_flutter.sh
# Environment: GITHUB_PATH (appended when set), RUNNER_TEMP (scratch dir).

set -euo pipefail

FLUTTER_VERSION="3.47.5"
FLUTTER_BASE_URL="https://storage.googleapis.com/flutter_infra_release/releases"

case "$(uname -s)" in
  Linux*)
    OS="linux"
    ARCHIVE_EXT="tar.xz"
    SHA256="2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb"
    ;;
  MINGW* | MSYS* | CYGWIN*)
    OS="windows"
    ARCHIVE_EXT="zip"
    SHA256="0ccd71931f49c2fbe394b1eeb6d79af3d624058a043ea0d03d34160581624fb8"
    ;;
  *)
    echo "ERROR: unsupported platform '$(uname -s)'. macOS runs are not used because iOS" >&2
    echo "builds require Apple hardware and are tracked as B06/T09 in the project ledger." >&2
    exit 1
    ;;
esac

ARCHIVE="flutter_${OS}_${FLUTTER_VERSION}-stable.${ARCHIVE_EXT}"
URL="${FLUTTER_BASE_URL}/stable/${OS}/${ARCHIVE}"

WORK_DIR="${RUNNER_TEMP:-/tmp}"
SDK_ROOT="${WORK_DIR}/flutter-sdk"
FLUTTER_BIN="${SDK_ROOT}/flutter/bin/flutter"

# Reuse an already-installed SDK for this exact version (the workflow restores it
# from cache), so a repeat run does not re-download 1.8 GB.
if [ -x "${FLUTTER_BIN}" ] && "${FLUTTER_BIN}" --version 2>/dev/null | grep -q "Flutter ${FLUTTER_VERSION} "; then
  echo "Reusing cached Flutter ${FLUTTER_VERSION} at ${SDK_ROOT}"
else
  echo "Installing Flutter ${FLUTTER_VERSION} (${OS})"
  rm -rf "${SDK_ROOT}"
  mkdir -p "${SDK_ROOT}"

  DOWNLOAD="${WORK_DIR}/${ARCHIVE}"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "${DOWNLOAD}" "${URL}"

  echo "${SHA256}  ${DOWNLOAD}" | sha256sum -c -

  if [ "${ARCHIVE_EXT}" = "zip" ]; then
    # `unzip` is present in Git for Windows; bsdtar is the fallback because it
    # handles zip archives too.
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "${DOWNLOAD}" -d "${SDK_ROOT}"
    else
      tar -xf "${DOWNLOAD}" -C "${SDK_ROOT}"
    fi
  else
    tar -xf "${DOWNLOAD}" -C "${SDK_ROOT}"
  fi

  rm -f "${DOWNLOAD}"
fi

if [ ! -x "${FLUTTER_BIN}" ]; then
  echo "ERROR: ${FLUTTER_BIN} not found after extraction" >&2
  exit 1
fi

# Fail loudly if the installed SDK is not the pinned version: a silent drift here
# would make every other guarantee in this workflow meaningless.
REPORTED="$("${FLUTTER_BIN}" --version)"
echo "${REPORTED}"
if ! printf '%s' "${REPORTED}" | grep -q "Flutter ${FLUTTER_VERSION} "; then
  echo "ERROR: expected Flutter ${FLUTTER_VERSION}, got:" >&2
  printf '%s\n' "${REPORTED}" >&2
  exit 1
fi

"${FLUTTER_BIN}" config --no-analytics >/dev/null

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${SDK_ROOT}/flutter/bin" >> "${GITHUB_PATH}"
fi

echo "Flutter ${FLUTTER_VERSION} ready at ${SDK_ROOT}/flutter"

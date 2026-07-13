#!/bin/bash
set -euo pipefail

BASE_VERSION="${1:?usage: next-version.sh BASE_VERSION [LATEST_TAG]}"
LATEST_TAG="${2:-v0.0.0}"
LATEST_VERSION="${LATEST_TAG#v}"
LATEST_VERSION="${LATEST_VERSION#V}"

SEMVER_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! "$BASE_VERSION" =~ $SEMVER_PATTERN ]]; then
    echo "Invalid Info.plist version: $BASE_VERSION" >&2
    exit 1
fi
if [[ ! "$LATEST_VERSION" =~ $SEMVER_PATTERN ]]; then
    echo "Latest release tag is not vMAJOR.MINOR.PATCH: $LATEST_TAG" >&2
    exit 1
fi

IFS=. read -r base_major base_minor base_patch <<< "$BASE_VERSION"
IFS=. read -r latest_major latest_minor latest_patch <<< "$LATEST_VERSION"

# Info.plist controls intentional major/minor changes. Within the same release
# line, CI advances the patch beyond the latest published GitHub Release.
if (( base_major < latest_major || (base_major == latest_major && base_minor < latest_minor) )); then
    echo "Info.plist $BASE_VERSION is behind latest release $LATEST_VERSION" >&2
    exit 1
fi

if (( base_major == latest_major && base_minor == latest_minor )); then
    if (( base_patch <= latest_patch )); then
        base_patch=$((latest_patch + 1))
    fi
fi

echo "${base_major}.${base_minor}.${base_patch}"

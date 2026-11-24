#!/usr/bin/env bash
# Prints the CHANGELOG.md section for a version (without its heading).
#   .github/scripts/changelog-section.sh 0.1.0
set -euo pipefail
version=${1#v}
cd "$(dirname "$0")/../.."
section=$(awk -v v="$version" '
    /^## \[/ { if (found) exit; found = index($0, "## [" v "]") == 1; next }
    /^\[.*\]: / { next }
    found { print }
' CHANGELOG.md)
if [[ -z "${section//[[:space:]]/}" ]]; then
    echo "::error file=CHANGELOG.md::no section for $version" >&2
    exit 1
fi
printf '%s\n' "$section"

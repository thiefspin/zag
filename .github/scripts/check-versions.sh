#!/usr/bin/env bash
# Checks that the root package and every zag-* package declare the same
# version. With an argument (a tag like v0.2.0), also checks it matches.
#
#   .github/scripts/check-versions.sh            # versions agree
#   .github/scripts/check-versions.sh v0.2.0     # ...and equal 0.2.0
set -euo pipefail
cd "$(dirname "$0")/../.."

version_of() { sed -n 's/^ *\.version = "\(.*\)",/\1/p' "$1" | head -1; }

expected=$(version_of build.zig.zon)
status=0
for zon in zag-*/build.zig.zon; do
    v=$(version_of "$zon")
    if [[ "$v" != "$expected" ]]; then
        echo "::error file=$zon::version $v differs from the root build.zig.zon ($expected)"
        status=1
    fi
done

if [[ $# -gt 0 ]]; then
    tag=${1#refs/tags/}
    if [[ "$tag" != "v$expected" ]]; then
        echo "::error::tag $tag does not match build.zig.zon version $expected (expected v$expected)"
        status=1
    fi
fi

[[ $status -eq 0 ]] && echo "version $expected"
exit $status

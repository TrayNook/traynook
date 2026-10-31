#!/bin/bash
set -euo pipefail

number='(0|[1-9][0-9]*)'
pattern="^v$number\.$number\.$number(-(alpha|beta|rc)\.[1-9][0-9]*)?$"
if [[ $# -ne 1 || ! "$1" =~ $pattern ]]; then
    echo "Usage: Scripts/release-metadata.sh vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N] (N must be positive; no leading zeros)." >&2
    exit 2
fi

release_version=${1#v}
prerelease=false
if [[ "$release_version" == *-* ]]; then
    prerelease=true
fi
printf 'version=%s\nrelease_version=%s\nprerelease=%s\n' "${release_version%%-*}" "$release_version" "$prerelease"

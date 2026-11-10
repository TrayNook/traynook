#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/.build"
export TRAYNOOK_WEBSITE_SNAPSHOTS
TRAYNOOK_WEBSITE_SNAPSHOTS=$(mktemp -d "$root/.build/website-snapshot.XXXXXX")
export TRAYNOOK_SNAPSHOT_SOURCE_REVISION
TRAYNOOK_SNAPSHOT_SOURCE_REVISION=$(git -C "$root" rev-parse HEAD)
"$root/Scripts/test.sh" --filter WebsiteSnapshotTests
# Some sandboxed GUI test runners exit successfully before the native test completes.
for file in settings-light.png settings-dark.png dropdown-light.png dropdown-dark.png provenance.json; do
  test -s "$TRAYNOOK_WEBSITE_SNAPSHOTS/$file" || {
    echo "Native snapshot did not complete: $file. Run in an authorized macOS GUI session." >&2
    exit 1
  }
done
destination="$root/website/public/assets/native-ui"
mkdir -p "$destination"
cp "$TRAYNOOK_WEBSITE_SNAPSHOTS/"*.png "$TRAYNOOK_WEBSITE_SNAPSHOTS/provenance.json" "$destination/"
echo "Native website visuals: $destination"

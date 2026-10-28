#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# -gt 2 || "${1:-}" == --help ]]; then
    echo "Usage: Scripts/release.sh [Developer-ID-Application-identity] [notarytool-keychain-profile]"
    echo "Or set TRAYNOOK_SIGNING_IDENTITY and TRAYNOOK_NOTARY_PROFILE. Optional: TRAYNOOK_VERSION, TRAYNOOK_BUILD."
    exit 2
fi
export TRAYNOOK_SIGNING_IDENTITY=${1:-${TRAYNOOK_SIGNING_IDENTITY:-}}
profile=${2:-${TRAYNOOK_NOTARY_PROFILE:-}}
if [[ -z "$TRAYNOOK_SIGNING_IDENTITY" || -z "$profile" ]]; then
    echo "A Developer ID Application identity and a stored notarytool keychain profile are required." >&2
    exit 2
fi

"$root/Scripts/test.sh"
"$root/Scripts/build-app.sh" release
app="$root/dist/TrayNook.app"
"$root/Scripts/smoke-test.sh" "$app"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
work=$(mktemp -d "$root/.build/notary.XXXXXX")
trap 'rm -rf "$work"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/TrayNook.zip"
xcrun notarytool submit "$work/TrayNook.zip" --keychain-profile "$profile" --wait --output-format json > "$work/result.json"
if [[ "$(/usr/bin/plutil -extract status raw "$work/result.json")" != Accepted ]]; then
    echo "Apple did not accept the notarization. Inspect the submission with notarytool history/log." >&2
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/spctl --assess --type execute "$app"
archive="TrayNook-$version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$archive"
mv "$work/$archive" "$root/dist/$archive"
(cd "$root/dist" && /usr/bin/shasum -a 256 "$archive" > "$archive.sha256")
printf 'Ready for distribution: %s\nChecksum: %s\n' "$root/dist/$archive" "$root/dist/$archive.sha256"

#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# -gt 2 || "${1:-}" == --help ]]; then
    echo "Usage: Scripts/release.sh [Developer-ID-Application-identity] [notarytool-keychain-profile]"
    echo "TRAYNOOK_DISTRIBUTION defaults to adhoc; set notarized to require Apple signing and notarization."
    echo "Positional Apple credentials opt into notarized distribution when TRAYNOOK_DISTRIBUTION is unset."
    echo "Set TRAYNOOK_UPDATE_PUBLIC_KEY and, for stable releases, TRAYNOOK_UPDATE_PRIVATE_KEY_FILE (exported Sparkle key)."
    echo "Or set TRAYNOOK_SIGNING_IDENTITY and TRAYNOOK_NOTARY_PROFILE. Optional: TRAYNOOK_VERSION, TRAYNOOK_BUILD, TRAYNOOK_RELEASE_VERSION, TRAYNOOK_NOTARY_KEYCHAIN."
    exit 2
fi
if [[ -z "${TRAYNOOK_DISTRIBUTION+x}" && $# -gt 0 ]]; then
    export TRAYNOOK_DISTRIBUTION=notarized
else
    export TRAYNOOK_DISTRIBUTION=${TRAYNOOK_DISTRIBUTION-adhoc}
fi
if [[ "$TRAYNOOK_DISTRIBUTION" != adhoc && "$TRAYNOOK_DISTRIBUTION" != notarized ]]; then
    echo "TRAYNOOK_DISTRIBUTION must be adhoc or notarized." >&2
    exit 2
fi
export TRAYNOOK_SIGNING_IDENTITY=${1:-${TRAYNOOK_SIGNING_IDENTITY:-}}
profile=${2:-${TRAYNOOK_NOTARY_PROFILE:-}}
if [[ "$TRAYNOOK_DISTRIBUTION" == notarized && ( -z "$TRAYNOOK_SIGNING_IDENTITY" || "$TRAYNOOK_SIGNING_IDENTITY" == - || -z "$profile" ) ]]; then
    echo "Notarized distribution requires a Developer ID Application identity and a stored notarytool keychain profile." >&2
    exit 2
fi
notary_options=(--keychain-profile "$profile")
if [[ -n "${TRAYNOOK_NOTARY_KEYCHAIN:-}" ]]; then
    notary_options+=(--keychain "$TRAYNOOK_NOTARY_KEYCHAIN")
fi
release_version=${TRAYNOOK_RELEASE_VERSION:-${TRAYNOOK_VERSION:-1.0.0}}
"$root/Scripts/release-metadata.sh" "v$release_version" > /dev/null
if [[ "$release_version" != *-* && ( -z "${TRAYNOOK_UPDATE_PRIVATE_KEY_FILE:-}" || ! -f "${TRAYNOOK_UPDATE_PRIVATE_KEY_FILE:-}" ) ]]; then
    echo "Stable releases require TRAYNOOK_UPDATE_PRIVATE_KEY_FILE (exported Sparkle private key)." >&2
    exit 2
fi

"$root/Scripts/test.sh"
"$root/Scripts/build-app.sh" release
app="$root/dist/TrayNook.app"
"$root/Scripts/smoke-test.sh" "$app"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
if [[ "${release_version%%-*}" != "$version" ]]; then
    echo "TRAYNOOK_RELEASE_VERSION must match the app's marketing version (with an optional prerelease suffix)." >&2
    exit 2
fi
work=$(mktemp -d "$root/.build/release.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [[ "$TRAYNOOK_DISTRIBUTION" == notarized ]]; then
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/TrayNook.zip"
    xcrun notarytool submit "$work/TrayNook.zip" "${notary_options[@]}" --wait --output-format json > "$work/result.json"
    if [[ "$(/usr/bin/plutil -extract status raw "$work/result.json")" != Accepted ]]; then
        echo "Apple did not accept the notarization. Inspect the submission with notarytool history/log." >&2
        exit 1
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
if [[ "$TRAYNOOK_DISTRIBUTION" == notarized ]]; then
    /usr/sbin/spctl --assess --type execute "$app"
fi
archive="TrayNook-$release_version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$archive"
if [[ "$release_version" != *-* ]]; then
    python3 "$root/Scripts/update-feed.py" "$work/$archive" "$version" "${TRAYNOOK_BUILD:-1}" \
        --signer "$root/.build/distribution/x86_64/artifacts/sparkle/Sparkle/bin/sign_update" \
        --notes "$root/CHANGELOG.md" --output "$work/appcast.xml"
    mv "$work/appcast.xml" "$root/dist/appcast.xml"
fi
# The enclosure signature covers this exact final ZIP; never modify it afterward.
mv "$work/$archive" "$root/dist/$archive"
(cd "$root/dist" && /usr/bin/shasum -a 256 "$archive" > "$archive.sha256")
printf 'Ready for distribution: %s\nChecksum: %s\n' "$root/dist/$archive" "$root/dist/$archive.sha256"

#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-dev}
if [[ $# -gt 1 || ( "$mode" != dev && "$mode" != release ) ]]; then
    echo "Usage: Scripts/build-app.sh [dev|release]" >&2
    exit 2
fi
version=${TRAYNOOK_VERSION:-1.0.0}
build_number=${TRAYNOOK_BUILD:-1}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "TRAYNOOK_VERSION must be three numeric components; TRAYNOOK_BUILD must be a positive integer." >&2
    exit 2
fi

app_name="TrayNook Dev"
bundle_id="io.github.mahenzon.TrayNook.dev"
if [[ "$mode" == release ]]; then
    if [[ -z "${TRAYNOOK_SIGNING_IDENTITY:-}" ]]; then
        echo "Release builds require TRAYNOOK_SIGNING_IDENTITY (Developer ID Application)." >&2
        exit 2
    fi
    app_name="TrayNook"
    bundle_id="io.github.mahenzon.TrayNook"
fi

export CLANG_MODULE_CACHE_PATH="$root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$root/.build/cache" "$root/.build/config" "$root/.build/security" "$root/dist"
app="$root/dist/$app_name.app"
dev_signing_identity=${TRAYNOOK_DEV_SIGNING_IDENTITY:-}
if [[ "$mode" == dev && -z "$dev_signing_identity" ]]; then
    dev_signing_identity=$(/usr/bin/security find-identity -v -p codesigning |
        /usr/bin/awk '/"TrayNook Dev"$/ { print $2; exit }') || dev_signing_identity=
    if [[ -z "$dev_signing_identity" && -d "$app" ]]; then
        echo "No TrayNook Dev signing identity is available. Allow keychain access or set TRAYNOOK_DEV_SIGNING_IDENTITY explicitly; refusing an ad-hoc replacement that would invalidate macOS permissions." >&2
        exit 1
    fi
fi
staging=$(mktemp -d "$root/dist/.bundle.XXXXXX")
trap 'rm -rf "$staging"' EXIT
contents="$staging/$app_name.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"

build_for() {
    local architecture=$1
    local options=(--package-path "$root" --disable-sandbox --cache-path "$root/.build/cache"
        --config-path "$root/.build/config" --security-path "$root/.build/security"
        --scratch-path "$root/.build/distribution/$architecture" --configuration release --product TrayNook)
    if [[ "$architecture" != native ]]; then
        options+=(--triple "$architecture-apple-macosx14.0")
    fi
    swift build "${options[@]}"
    bin_dir=$(swift build "${options[@]}" --show-bin-path)
}

if [[ "$mode" == release ]]; then
    build_for arm64
    arm_binary="$bin_dir/TrayNook"
    build_for x86_64
    /usr/bin/lipo -create "$arm_binary" "$bin_dir/TrayNook" -output "$contents/MacOS/TrayNook"
    /usr/bin/lipo "$contents/MacOS/TrayNook" -verify_arch arm64 x86_64
else
    build_for native
    cp "$bin_dir/TrayNook" "$contents/MacOS/TrayNook"
fi
cp -R "$bin_dir/TrayNook_TrayNook.bundle" "$contents/Resources/"
cp "$root/Support/Info.plist" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$app_name" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$contents/Info.plist"
cp "$root/Support/AppIcon.icns" "$contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$contents/Info.plist"

if [[ "$mode" == release ]]; then
    /usr/bin/codesign --force --sign "$TRAYNOOK_SIGNING_IDENTITY" --options runtime --timestamp "$staging/$app_name.app"
    /usr/bin/codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$staging/$app_name.app"
elif [[ -n "$dev_signing_identity" ]]; then
    # A self-signed code-signing certificate keeps macOS privacy grants across
    # rebuilds; ad-hoc signatures change with every build. See README.
    /usr/bin/codesign --force --sign "$dev_signing_identity" "$staging/$app_name.app"
else
    /usr/bin/codesign --force --sign - "$staging/$app_name.app"
fi
/usr/bin/codesign --verify --deep --strict "$staging/$app_name.app"
# Replace the previous local build only after the new bundle is complete and verified.
rm -rf "$app"
mv "$staging/$app_name.app" "$app"
printf '%s\n' "$app"

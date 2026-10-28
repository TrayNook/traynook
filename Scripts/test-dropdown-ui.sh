#!/bin/bash
set -euo pipefail

# Full production UI regression; requires macOS GUI and Accessibility for the
# invoking terminal. Quit real TrayNook and leave input idle. Opens only the
# disposable fixture's menu. Layout and preferences use unique test bundle IDs.
# --layout copies existing placements read-only, then adds a selected fixture
# and an independently monitored Always Hidden sentinel. This
# lets crowded bars retain the user's requested hidden section during the test.
# --require-still-pointer enforces zero sampled motion; currently a known failure.
# Usage: Scripts/test-dropdown-ui.sh [--layout layout.json] [--invalid-positions] [--require-still-pointer] [app]
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
app="$repo_dir/dist/TrayNook Dev.app"
invalid=false
still_pointer=false
layout=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --invalid-positions) invalid=true ;;
    --require-still-pointer) still_pointer=true ;;
    --layout)
      if [[ $# -lt 2 || ! -f "$2" ]]; then
        echo "--layout requires an existing JSON file." >&2
        exit 2
      fi
      layout=$2
      shift
      ;;
    --*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) app=$1 ;;
  esac
  shift
done
if [[ ! -x "$app/Contents/MacOS/TrayNook" ]]; then
  echo "Build TrayNook first: Scripts/build-app.sh" >&2
  exit 2
fi
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/traynook-dropdown-ui.XXXXXX")
token=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')
harness="$check_dir/Harness.app/Contents/MacOS/DropdownUIRegression"
cleanup() {
  if [[ -x "$harness" ]]; then "$harness" "$check_dir" "$token" --cleanup; fi
  rm -rf "$check_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 6 -parse-as-library \
  "$repo_dir/Tests/Manual/DropdownUIRegression.swift" -o "$check_dir/DropdownUIRegression"
for role in Harness Fixture Sentinel; do
  app_dir="$check_dir/$role.app"
  mkdir -p "$app_dir/Contents/MacOS"
  cp "$check_dir/DropdownUIRegression" "$app_dir/Contents/MacOS/DropdownUIRegression"
  cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DropdownUIRegression</string>
<key>CFBundleIdentifier</key><string>io.github.mahenzon.TrayNook.UIRegression.$role.$token</string>
<key>CFBundleName</key><string>TrayNook UI $role</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
  codesign --force --sign - "$app_dir" >/dev/null
done
ditto "$app" "$check_dir/App.app"
plutil -replace CFBundleIdentifier -string "io.github.mahenzon.TrayNook.UIRegression.App.$token" "$check_dir/App.app/Contents/Info.plist"
codesign --force --sign - "$check_dir/App.app" >/dev/null
codesign --verify --deep --strict "$check_dir/App.app"
printf 'Testing packaged TrayNook build %s\n' "$(plutil -extract CFBundleVersion raw "$check_dir/App.app/Contents/Info.plist")"
set -- "$check_dir" "$token"
if [[ "$invalid" == true ]]; then set -- "$@" --invalid-positions; fi
if [[ "$still_pointer" == true ]]; then set -- "$@" --require-still-pointer; fi
if [[ -n "$layout" ]]; then set -- "$@" --layout "$layout"; fi
"$harness" "$@"

#!/bin/bash
set -euo pipefail
# GUI check of TrayNook-owned status items only; no Accessibility or input events.
# Quit TrayNook first so its inventory watcher cannot save the temporary fixture.
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --compile-only ) ]]; then
  echo "Usage: Scripts/test-native-boundary.sh [--compile-only]" >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/traynook-boundary-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$check_dir/modules"
swiftc -swift-version 6 -parse-as-library -whole-module-optimization \
  -emit-object -emit-module -module-name InventoryIdentityCore \
  -emit-module-path "$check_dir/InventoryIdentityCore.swiftmodule" \
  "$repo_dir"/Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore/*.swift \
  -o "$check_dir/InventoryIdentityCore.o"
app_dir="$check_dir/BoundaryCheck.app"
mkdir -p "$app_dir/Contents/MacOS"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" \
  "$check_dir/InventoryIdentityCore.o" "$repo_dir/Sources/TrayNook/NativeMenuBarController.swift" \
  "$repo_dir/Sources/TrayNook/WindowMetadataReader.swift" \
  "$repo_dir/Tests/Manual/BoundaryVisibilityCheck.swift" -o "$app_dir/Contents/MacOS/Check"
check_id="$(uuidgen)"
cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Check</string><key>CFBundleIdentifier</key><string>io.github.mahenzon.TrayNook.BoundaryCheck.$check_id</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
EOF
codesign --force --sign - "$app_dir" >/dev/null
if [[ "${1:-}" == --compile-only ]]; then exit 0; fi
log="$check_dir/result.log"
open -W -n --stdout "$log" --stderr "$log" "$app_dir"
cat "$log"
/usr/bin/grep -q '^BOUNDARY_VISIBILITY_CHECK_PASSED$' "$log"

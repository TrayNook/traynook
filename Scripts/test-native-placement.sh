#!/bin/bash
set -euo pipefail
# Live GUI check. Quit TrayNook and keep input idle; only owned fixtures move.
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --compile-only ) ]]; then
  echo "Usage: Scripts/test-native-placement.sh [--compile-only]" >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/traynook-placement-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 6 -parse-as-library -whole-module-optimization \
  -emit-object -emit-module -module-name InventoryIdentityCore \
  -emit-module-path "$check_dir/InventoryIdentityCore.swiftmodule" \
  "$repo_dir"/Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore/*.swift \
  -o "$check_dir/InventoryIdentityCore.o"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" \
  "$check_dir/InventoryIdentityCore.o" "$repo_dir/Sources/TrayNook/NativeMenuBarController.swift" \
  "$repo_dir/Sources/TrayNook/WindowMetadataReader.swift" \
  "$repo_dir/Tests/Manual/SelectivePlacementCheck.swift" -o "$check_dir/Check"
if [[ "${1:-}" == --compile-only ]]; then exit 0; fi
token="$(uuidgen)"
for role in Harness Source Sentinel Anchor; do
  app_dir="$check_dir/$role.app"
  mkdir -p "$app_dir/Contents/MacOS"
  cp "$check_dir/Check" "$app_dir/Contents/MacOS/Check"
  cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Check</string><key>CFBundleIdentifier</key><string>io.github.mahenzon.TrayNook.PlacementCheck.$role.$token</string><key>CFBundleName</key><string>TrayNook Placement $role</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
EOF
  codesign --force --sign - "$app_dir" >/dev/null
done
"$check_dir/Harness.app/Contents/MacOS/Check" "$check_dir" "$token" Harness

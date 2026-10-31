#!/bin/bash
set -euo pipefail

# Live macOS GUI check. Requires Accessibility for the invoking terminal.
# Moves/clicks only a disposable fixture; keep the pointer and keyboard idle.
# Quit TrayNook first so its inventory watcher does not save the test fixture.
# --pointer-motion checks AXPress while mouse-motion events remain active.
# It posts moves at the current position, without displacing the pointer.
# --reorder reverses/restores a disposable pair with a hidden sentinel witness.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/traynook-movement-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$check_dir/modules"

swiftc -swift-version 6 -parse-as-library -whole-module-optimization \
  -emit-object -emit-module -module-name InventoryIdentityCore \
  -emit-module-path "$check_dir/InventoryIdentityCore.swiftmodule" \
  "$repo_dir"/Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore/*.swift \
  -o "$check_dir/InventoryIdentityCore.o"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" \
  "$check_dir/InventoryIdentityCore.o" \
  "$repo_dir/Sources/TrayNook/NativeMenuBarController.swift" \
  "$repo_dir/Sources/TrayNook/NativeMenuInteraction.swift" \
  "$repo_dir/Tests/Manual/NativeMovementCheck.swift" \
  -o "$check_dir/NativeMovementCheck"

for role in Harness Fixture; do
  app_dir="$check_dir/$role.app"
  mkdir -p "$app_dir/Contents/MacOS"
  cp "$check_dir/NativeMovementCheck" "$app_dir/Contents/MacOS/NativeMovementCheck"
  cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NativeMovementCheck</string>
<key>CFBundleIdentifier</key><string>io.github.mahenzon.TrayNook.NativeCheck.$role</string>
<key>CFBundleName</key><string>TrayNook $role Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
  codesign --force --sign - "$app_dir" >/dev/null
done

"$check_dir/Harness.app/Contents/MacOS/NativeMovementCheck" "$check_dir" "$@"

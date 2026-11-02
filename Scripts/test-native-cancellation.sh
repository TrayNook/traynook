#!/bin/bash
set -euo pipefail
# Live owned-fixture check. Quit TrayNook first and keep input idle.
# Instruments only a temporary copy: production has no test hooks or flags.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/traynook-cancellation-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_dir/.build/ModuleCache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
python3 - "$repo_dir/Sources/TrayNook/NativeMenuBarController.swift" "$check_dir/NativeMenuBarController.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
replacements = {
    '    marker.postToPid(pid)\n': '    marker.postToPid(pid)\n    SelectiveCancellationHooks.callback?(event.type, "queued")\n',
    '          relay.event.post(tap: .cgSessionEventTap)\n': '          SelectiveCancellationHooks.posted(relay.event.type)\n          relay.event.post(tap: .cgSessionEventTap)\n',
    '          relay.onDelivered?()\n': '          relay.onDelivered?()\n          SelectiveCancellationHooks.callback?(relay.event.type, "delivered")\n',
    '    guard let release = pendingRelease else { return }\n': '    guard let release = pendingRelease else { return }\n    SelectiveCancellationHooks.emergencyReleases += 1\n',
}
for before, after in replacements.items():
    if source.count(before) != 1:
        raise SystemExit('Controller changed; review the exact cancellation instrumentation seam.')
    source = source.replace(before, after)
source += '''
@MainActor enum SelectiveCancellationHooks {
  static var callback: ((CGEventType, String) -> Void)?
  static var downPosts = 0
  static var upPosts = 0
  static var emergencyReleases = 0
  static func posted(_ type: CGEventType) {
    if type == .leftMouseDown { downPosts += 1 }
    if type == .leftMouseUp { upPosts += 1 }
  }
  static func reset() { downPosts = 0; upPosts = 0; emergencyReleases = 0 }
}
'''
Path(sys.argv[2]).write_text(source)
PY
swiftc -swift-version 6 -parse-as-library -whole-module-optimization \
  -emit-object -emit-module -module-name InventoryIdentityCore \
  -emit-module-path "$check_dir/InventoryIdentityCore.swiftmodule" \
  "$repo_dir"/Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore/*.swift \
  -o "$check_dir/InventoryIdentityCore.o"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" \
  "$check_dir/InventoryIdentityCore.o" "$check_dir/NativeMenuBarController.swift" \
  "$repo_dir/Sources/TrayNook/WindowMetadataReader.swift" \
  "$repo_dir/Tests/Manual/SelectiveCancellationCheck.swift" -o "$check_dir/Check"
for role in Harness Fixture Sentinel; do
  app_dir="$check_dir/$role.app"
  mkdir -p "$app_dir/Contents/MacOS"
  cp "$check_dir/Check" "$app_dir/Contents/MacOS/Check"
  cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Check</string><key>CFBundleIdentifier</key><string>io.github.mahenzon.TrayNook.CancellationCheck.$role</string><key>CFBundleName</key><string>TrayNook Cancellation $role</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
EOF
  codesign --force --sign - "$app_dir" >/dev/null
done
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
"$check_dir/Harness.app/Contents/MacOS/Check" "$check_dir"

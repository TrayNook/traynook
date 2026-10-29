#!/bin/bash
set -euo pipefail

# Requires a macOS GUI session and Accessibility for the invoking terminal.
# Briefly opens a disposable menu; it never moves or clicks the pointer.
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --compile-only ) ]]; then
  echo "Usage: Scripts/test-native-menu.sh [--compile-only]" >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/traynook-menu-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

python3 - "$repo_dir/Sources/TrayNook/NativeMenuInteraction.swift" "$check_dir/WithoutMenuNotifications.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
before = '        interaction.receive(element, notification: notification)\n'
after = '        _ = (interaction, element, notification) // Suppress only AX callback delivery in this temporary check.\n'
if source.count(before) != 1:
    raise SystemExit('Menu observer changed; review the exact notification-suppression seam.')
Path(sys.argv[2]).write_text(source.replace(before, after))
PY

for variant in NativeMenuInteraction WithoutMenuNotifications; do
  source="$repo_dir/Sources/TrayNook/NativeMenuInteraction.swift"
  if [[ "$variant" == WithoutMenuNotifications ]]; then
    source="$check_dir/WithoutMenuNotifications.swift"
  fi
  CLANG_MODULE_CACHE_PATH="$check_dir/modules" swiftc -swift-version 6 -parse-as-library \
    "$source" "$repo_dir/Tests/Manual/NativeMenuInteractionCheck.swift" \
    -o "$check_dir/$variant"
done
if [[ "${1:-}" == --compile-only ]]; then exit 0; fi

for variant in NativeMenuInteraction WithoutMenuNotifications; do
  echo "Checking $variant"
  "$check_dir/$variant" "$check_dir/$variant-start"
done

#!/bin/bash
set -euo pipefail

# Requires a macOS GUI session and Accessibility for the invoking terminal.
# Briefly opens a disposable menu; it never moves or clicks the pointer.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/traynook-menu-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

CLANG_MODULE_CACHE_PATH="$check_dir/modules" swiftc -swift-version 6 -parse-as-library \
  "$repo_dir/Sources/TrayNook/NativeMenuInteraction.swift" \
  "$repo_dir/Tests/Manual/NativeMenuInteractionCheck.swift" \
  -o "$check_dir/NativeMenuInteractionCheck"
"$check_dir/NativeMenuInteractionCheck" "$check_dir/start"

#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export CLANG_MODULE_CACHE_PATH="$root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$root/.build/cache" "$root/.build/config" "$root/.build/security"
exec swift test --package-path "$root" --disable-sandbox --cache-path "$root/.build/cache" \
    --config-path "$root/.build/config" --security-path "$root/.build/security" "$@"

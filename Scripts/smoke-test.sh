#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-"$root/dist/TrayNook Dev.app"}
if [[ $# -gt 1 || ! -d "$app" ]]; then
    echo "Usage: Scripts/smoke-test.sh [path/to/TrayNook.app]; build the app first." >&2
    exit 2
fi
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app"
if [[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")" != TrayNook ]]; then
    echo "Unexpected app executable." >&2
    exit 1
fi
if [[ "$(/usr/bin/plutil -extract LSUIElement raw "$app/Contents/Info.plist")" != true ||
    ! -s "$app/Contents/Resources/AppIcon.icns" ||
    ! -s "$app/Contents/Resources/TrayNook_TrayNook.bundle/en.lproj/Localizable.strings" ]]; then
    echo "Menu bar app configuration or bundled resources are missing." >&2
    exit 1
fi
log=$(mktemp "${TMPDIR:-/tmp}/traynook-smoke.XXXXXX")
pid=
watchdog=
cleanup() {
    if [[ -n "$watchdog" ]]; then
        kill "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
    fi
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$log"
}
trap cleanup EXIT
"$app/Contents/MacOS/TrayNook" --smoke-test > "$log" 2>&1 &
pid=$!
(sleep 20; kill "$pid" 2>/dev/null || true) &
watchdog=$!
if ! wait "$pid"; then
    cat "$log" >&2
    echo "TrayNook smoke test failed or timed out." >&2
    exit 1
fi
pid=
if ! /usr/bin/grep -q '^TRAYNOOK_SMOKE_OK$' "$log"; then
    cat "$log" >&2
    echo "TrayNook exited without confirming the smoke test." >&2
    exit 1
fi
echo "TrayNook bundle, signature, launcher, and Settings smoke test passed."

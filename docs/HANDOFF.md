# TrayNook: build 19, first native run done on two displays

Updated 2026-10-28 (evening). Build 18's measurements are in
[MVP_REPORT.md](MVP_REPORT.md); build 19's decisions are in
[ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md) and
[ADR 0010](adr/0010-geometry-follows-the-active-menu-bar-row.md).

## Current state

- Development app: `dist/TrayNook Dev.app`, **1.0.0 (19)**, signed with the
  user's `TrayNook Dev` certificate (README "Development signing and
  permissions"). Unit suite (72 tests), packaged smoke test, and both manual
  harnesses compile.
- **Verified on device (2026-10-28, notch MacBook + external display):**
  launch → automatic layout → two Command-drags (Macs Fan Control, Handy)
  → concealment with the separator at 2578 pt covering the wider display.
  Concealment held until the user interacted. Read the run with
  `/usr/bin/log show --last 5m --info --predicate 'subsystem == "io.github.mahenzon.TrayNook.dev"'`
  (`log` alone is a zsh builtin).
- Geometry follows the display of the latest inventory: the AX menu-bar row
  jumps to the display that holds the active app's key window, so any click
  on the other display used to break every decision (ADR 0010).
- Crowded bar: items left of the notch's safe area are offscreen; brand-new
  status items get no CG window at all. A drag to the hidden side may end
  clipped under the notch and is accepted as success. Menu Bar-placed items
  that are already clipped cannot be dragged out (status says "Offscreen —
  menu bar is full"); on the wider external display they are visible and
  draggable, so arranging with a window active there works better.
- Known false reveals fixed: Control Centre's camera indicator
  (`#ax:...audiovideo`) appearing and disappearing; a single incomplete scan
  (a launching app answers Accessibility late) now has to repeat three times
  before the section reveals, and the scan warning names the slow apps.
- Spurious "unassigned or protected item is behind the separator" reveals
  came from one poll reading Control Centre's Now Playing item mid-relayout
  (its frame overlapped the separator edge, `isBehindBoundary` was nil). The
  section now reveals only when two consecutive scans agree; the log line
  "unsafe once, waiting" shows each tolerated poll with frames and values.
  Watch for a genuine case that needs the second poll to catch it.
- A lazarus review of the two-display changes found five issues (panel
  windows becoming fake items, geometry read before the inventory, stale
  frames in placement, unsafe retry positions, over-eager re-key detection);
  all fixed in the "review findings" commit.

## Native harness status

Every harness needs `AXIsProcessTrusted()` in the launching process. Grant
Accessibility to Terminal.app and run each script through
`open -a Terminal x.command` with output redirected to a file (the Claude app
shell, its Terminal panel, and iTerm had no Accessibility). Quit Hidden Bar
and the real TrayNook first.

- `Scripts/test-native-menu.sh`: **passes**.
- `Scripts/test-native-cancellation.sh`: setup and `queued-down`,
  `delivered-down`, `delivered-up` pass; the `*-motion` phases compare the
  pointer with a fixed position and need an idle machine (the user was
  working during the run). One earlier run failed setup with an incomplete
  scan; it prints the setup scan now.
- `Scripts/test-dropdown-ui.sh --layout ...`: cannot complete on this bar.
  Its fixture and sentinel are brand-new items that get no status window in
  an overfull bar, and its final order check fails by design whenever Apply
  reorders the user's real items. Run it on a bar with free space, or
  without `--layout` after quitting a few menu-bar apps.
- Multi-item app and Menu Bar-restart checks (ADR 0009 §2) still unverified.

## Read before changing interaction

- `Sources/TrayNook/NativeMenuBarController.swift`: `hideCursor`/`showCursor`,
  `prepareActivation` (promotion loop tolerates AX lag), `accessibilityTarget`
  (sibling selection by expected frame), `stableTarget` (matches by persistent
  key), `conceal`/`canConceal` (`allowedKeys`), `adoptProcess`.
- `Sources/TrayNook/AppModel.swift`: `keyedChanges`, `rebindsProcess`,
  `inventoryRequiresReveal`, `refreshProxyImages`.
- `Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore/IdentityAssessor.swift`:
  `persistentKey` rules and `persistableIdentifier`.
- `Sources/TrayNook/ProxyImageCapture.swift`: capture and glyph luminance.

## Failed experiments: do not assume these are untried fixes

1. Session event at current cursor, original targeted event to PID: delivered
   events but no WindowServer promotion.
2. Annotated-session delivery: preserved cursor but no promotion after down/up.
3. Tagged null-event substitution at session tap: relay timeout, no promotion.
4. No down dwell: intermittent missed reorder; reverted.
5. Public offscreen window capture: nil on macOS 15.7 for every offscreen
   status window.

Never reveal peers as a normal activation fallback. Never retry an uncertain AX
action. `.optionAll` is required to find offscreen windows.

## Repeat checks

```sh
Scripts/test.sh
TRAYNOOK_BUILD=19 Scripts/build-app.sh
Scripts/smoke-test.sh
Scripts/test-native-cancellation.sh --compile-only
"dist/TrayNook Dev.app/Contents/MacOS/TrayNook" --diagnose
```

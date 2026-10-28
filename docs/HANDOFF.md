# TrayNook: build 19, awaiting native acceptance

Updated 2026-10-28. Build 18's measurements and verified checks are in
[MVP_REPORT.md](MVP_REPORT.md); the decisions behind build 19 are in
[ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md).

## Current state

- Development app: `dist/TrayNook Dev.app`, **1.0.0 (19)**, ad-hoc signed.
  Unit suite (69 tests), packaged smoke test, and both manual harnesses compile
  and pass. **No native check has been run on build 19**: the user asked that
  no synthesized input touch the pointer until they say so.
- Pointer: hidden with `CGDisplayHideCursor` during synthesized moves and
  clicks, warped back, then shown. The jump still happens; it is meant to be
  invisible. The 200 ms settle window stays; the wait for released buttons and
  keys is at most one second instead of ten.
- Proxies: with Screen Recording, each Dropdown item shows its last onscreen
  capture (`CGWindowListCreateImage` returns nil for offscreen windows on
  15.7; `--diagnose` prints the capture counts). Without it, app icons.
- Identity: `bundle` for an app's only item; `bundle#ax:<id>` or
  `bundle#w<rank>` for siblings. Restarted hidden sources rebind their PID
  instead of revealing. Menu Bar sources, unknown bundles, ambiguous groups,
  and ranked siblings whose set or window changes still reveal.
- Work is committed on `master` (baseline `74f0dc7`, then one commit per step
  and one for the review fixes).

## Native acceptance to run first (needs the user's go-ahead)

1. `Scripts/test-dropdown-ui.sh --layout "$HOME/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json" --invalid-positions "dist/TrayNook Dev.app"`.
   Its cursor witness samples pointer **position**, so displacement is expected;
   watch the screen for a visible pointer during promotion. If the pointer is
   visible, `CGDisplayHideCursor` is being ignored for a non-frontmost process.
   Next option: keep TrayNook active across `moveTargeted` (drop the early
   `NSApp.deactivate()` in `runOperation`/`interact` for the move only). Do not
   use a private connection property.
2. `Scripts/test-native-cancellation.sh` and `Scripts/test-native-menu.sh`:
   release paths must still show the pointer (every `hideCursor` is paired in a
   `defer`, and `reveal()` shows it).
3. Grant Screen Recording to the rebuilt app, quit and reopen it, open the
   dropdown: proxies should be captured glyphs on a dark or light backdrop.
   Run `--diagnose` to confirm "Status windows captured".
4. A multi-item app (two `AXMenuBarItem`s in one process): both appear in
   Layout with distinct keys; promoting one moves only that one. Quit and
   relaunch the app while concealed: the proxies keep working, no reveal.
5. Restart a Menu Bar-placed app while concealed: it must either be visible or
   the section must reveal.

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

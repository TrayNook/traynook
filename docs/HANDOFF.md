# TrayNook: build 26, focused Settings tabs

Updated 2026-10-29. Build 18's measurements are in
[MVP_REPORT.md](MVP_REPORT.md); build 19's decisions are in
[ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md) and
[ADR 0010](adr/0010-geometry-follows-the-active-menu-bar-row.md).

## Current state

- **Menu Bar ordering (2026-10-31):** preview drops and detail-row drops now
  apply the relative order of manageable Menu Bar sources, including Undo/Redo.
  Apply Saved Layout also enforces that order. Clipped sources are left untouched,
  protected sources are never dragged, and RTL keeps the physical icon strip
  left-to-right. Six caller tests, five native planning/eligibility tests, and
  three rendered drag tests pass. After rebuilding and reopening the signed app,
  WindowServer confirmed the real BroGlow source left of Tunnelblick, matching
  their saved order. The separate disposable `--reorder` check compiled but
  stopped before posting input because its harness lacks Accessibility permission.
- Development app: `dist/TrayNook Dev.app`, **1.0.0 (26)**, signed with the
  user's `TrayNook Dev` certificate (README "Development signing and
  permissions"). The unit suite, packaged smoke test, and opt-in GUI preview
  snapshots pass, including minimum Settings width and row capacities 1/30.
- **Settings responsibilities (2026-10-29):** Layout is the sole home of the
  interactive preview and row capacity. Item details can collapse while retaining
  names, statuses, placement pickers, Retry, Forget, and row handles. Reset Layout
  lives here too. General groups startup, dropdown icon appearance, diagnostics,
  and About/privacy information; it reads the actual bundle version/build.
  Missing Screen Recording disables the glyph preference and offers a link to
  Permissions. Permissions groups access status and grant actions in a scroll
  view. Minimum-size GUI checks cover all tabs with permissions granted and
  absent and assert exactly one preview surface in Layout and none elsewhere.
  The preview's drag state and cancellation lifecycle are unchanged; hiding the
  detailed rows finalizes any active row-handle reorder.
- **Preview dragging (2026-10-29):** grab a manageable icon directly in Saved
  layout preview to reorder it or move it among Menu Bar, Dropdown, and Always
  Hidden. A floating icon tracks the pointer with a closed-hand cursor; the
  hovered zone highlights and neighbors animate around an empty insertion slot.
  A stable app-local event monitor keeps tracking across cell reparenting;
  pointer updates redraw only the floating icon. Mouse movement
  does not save or run native placement. A valid drop saves once with one Undo
  step. Changed Placements and Menu Bar source order apply native movement. Escape, outside
  drops, stale source identity, loss of edit permission, and closing the preview
  discard the draft. Window/focus loss also cancels and removes the monitor.
  Protected icons, Settings, and Launcher stay fixed.
  Preview Menu Bar drops and detail-row reordering apply manageable sources' relative
  native order without revealing hidden items. Undo/Redo also synchronize that order;
  Apply Saved Layout retries it. Protected sources and the Launcher are never moved
  by the reorder operation, so their positions can differ from the preview.
  Isolated window checks confirmed draft movement before release, the closed-hand
  cursor, one commit on drop, and zero commits on Escape/outside/window-close;
  each case also verified cursor restoration and event-monitor removal.
- **Review fixes (2026-10-29):** proxy promotion and return now bind to the
  same display's control windows used for geometry checks. Ranked sibling
  window replacement triggers review even when position and metadata do not
  change, and a stale proxy cannot activate the sibling that inherited its
  rank between polling and clicking. Pure regression tests cover both paths;
  live multi-display interaction still needs device verification.
- A panel watcher is canceled when another activation starts or items are
  revealed, including when the new activation has no observable new windows.
  Closing an older panel can no longer return the newer source. The smoke
  regression failed before this fix and passes in the packaged build.
- Layout loading distinguishes a missing file from an inaccessible or invalid
  parent directory. Read errors enter recovery and preserve the original;
  regression fixtures verify both errors and the normal first-launch case.
- **Idle recurrence (2026-10-29):** scan recovery succeeded three times in
  build 21, then an inventory change at 20:31 revealed the section and
  canceled recovery. The log truncated the triggering source's name; its
  owning app is unconfirmed. Build 22 temporarily reveals new or returning
  Menu Bar sources, then reapplies the saved layout through the existing
  geometry checks. Ambiguous identities and sibling re-keying still stop
  for review, including during recovery. Each actual trigger is now logged
  separately without irrelevant order changes.
- An incomplete/stale scan or interrupted input during automatic reapply
  now retries after three seconds and a complete scan. Explicit Reveal,
  identity review, permission/save failures, and placement errors stop
  recovery. Native activation is never retried. The packaged model
  regression failed before the fix and passes with build 22; prolonged
  idle behavior remains for ongoing user observation.
- Build 21 fixed promoted items staying visible when an already-open app
  window dismissed the native menu. Native menu and cancellation regressions
  passed, and the user confirmed the Macs Fan Control flow works.
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
  (`#ax:...audiovideo`) appearing and disappearing; three incomplete scans
  are tolerated before the fourth reveals the section, and the scan warning
  names the slow apps. A subsequent complete scan restores the saved layout.
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

## Interaction changes verified by the user (2026-10-28 evening)

- Settings opens at launch only when Accessibility is missing, nothing is
  hidden yet, or the launch restore fails; TrayNook joins Cmd-Tab and the
  Dock only while Settings is open.
- Apps that open a panel instead of a menu: the promoted item returns on its
  own once the panel's windows are gone; a tray click during an operation is
  queued; the dropdown opens at once and the item returns when it closes.
- Layout tab: locked system items fold into one row; stale system entries
  are forgotten; rows reorder live by their handle (gesture, one undo step);
  dropdown shows app icons, menu-bar glyphs behind a Permissions toggle;
  system menu extras use SF Symbols.

## Native harness status

Every harness needs `AXIsProcessTrusted()` in the launching process. Grant
Accessibility to Terminal.app and run each script through
`open -a Terminal x.command` with output redirected to a file (the Claude app
shell, its Terminal panel, and iTerm had no Accessibility). Quit Hidden Bar
and the real TrayNook first.

- `Scripts/test-native-menu.sh`: **passes**.
- `Scripts/test-native-cancellation.sh`: **passes** (all nine phases, idle
  machine, 2026-10-28). The `*-motion` phases compare the pointer with a
  fixed position, so any real input during the run fails them. One earlier
  run failed setup with an incomplete scan; it prints the setup scan now.
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
TRAYNOOK_DEV_SIGNING_IDENTITY='TrayNook Dev' TRAYNOOK_BUILD=26 Scripts/build-app.sh
Scripts/smoke-test.sh
Scripts/test-native-cancellation.sh --compile-only
"dist/TrayNook Dev.app/Contents/MacOS/TrayNook" --diagnose
```

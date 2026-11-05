# TrayNook: build 42, concealment resilience across app failures

Updated 2026-11-05. Build 18's measurements are in
[MVP_REPORT.md](MVP_REPORT.md); build 19's decisions are in
[ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md) and
[ADR 0010](adr/0010-geometry-follows-the-active-menu-bar-row.md).

## Current state

- **Concealment resilience audit (2026-11-05):** three Lazarus researchers audited
  discovery, native layout, and handoff, followed by independent correctness
  review. Build 42 keeps hiding independent of optional Menu Bar ordering,
  isolates a refusing source after fresh safety checks, and rechecks successful
  placements after boundary repair. New verified-visible apps do not reveal the
  hidden section; restarting/recreated hidden sources receive selected-only
  repair. Unrelated panels are excluded from source stability, and slow/stale AX
  scans retain hiding only after fresh full native-source verification. Native
  handoff retains long-menu observation, tracks real panel disappearance,
  retries transient selected returns without replaying activation, and handles
  moved/missing return anchors and owner termination. Actual unsafe identities,
  permission loss, unobservable UI, and confirmed OS refusal retain explicit
  safety/manual recovery. The standard suite passes 223 tests, four isolated
  AppKit suites pass 30, three native harnesses compile, and packaged smoke
  passes. The native-menu runtime fixture could not pass the invoking terminal's
  Accessibility preflight. Signed build 42 reopened; four readbacks over 30
  seconds found nine hidden-source owners and zero visible hidden-source
  windows. Live logs show automatic recovery after two temporary inventory failures
  and subsequent incomplete scans preserving concealment. See the
  [audit and verification limits](CONCEALMENT_RESILIENCE_AUDIT.md).
- **Idle recurrence (2026-11-05):** build 39 temporarily revealed after unknown
  boundary geometry, then stopped automatic recovery at 16:33:17. DockDoor's
  AX frame (`x=1108, width=24`) overlapped the compact separator
  (`x=1129, width=2`); the generic placement error discarded the pending retry.
  Build 41 treats unknown placement sides and missing control geometry as
  unavailable inventory: native movement remains blocked, and automatic recovery
  retries after three seconds and a complete scan. Confirmed unsafe placements
  still stop for review. Compact controls must have onscreen native windows;
  expanded separators can report offscreen, so they retain the existing native
  allocation, mirror-width, and recovery-edge checks. An initial visibility
  guard rejected valid expanded separators on device and was narrowed before
  final verification. Two captured regressions failed before the fix; expanded
  home/mirror/compact-allocation regressions, 184 standard tests, nine AppKit
  recovery tests, and packaged smoke pass. The smoke also drives the captured
  overlap through automatic layout recovery. Signed build 41 reopened with the
  existing saved layout; four native-window readbacks over 30 seconds found nine
  hidden-source owners and zero visible hidden-source windows. The initial
  cause of the unknown polling geometry and prolonged idle behavior remain
  unverified.
- **First Settings opening (2026-11-02):** controlled profiling did not reproduce
  the earlier multi-second redraw burst. Build 33 resolves the immutable
  localization resource bundle once while retaining per-call `NSLocalizedString`.
  Three-run release content-opening medians changed from 186 to 148 ms; fresh
  content with warm icons changed from 125 to 91 ms. These are content measurements,
  not complete production opening or display-frame guarantees. The opt-in opening
  benchmark separates construction, retained content, entry refresh, and scan
  transitions, with a 500 ms main-actor hang guard. Its final release run measured
  166 ms initial work and a 39 ms entry-refresh heartbeat gap. The standard suite
  reports 161 tests passing; the opening/scroll guards, three preview checks, and
  packaged smoke pass. Signed build 33 was restored on the 1728-point display;
  native readback found nine hidden-source owners and zero visible hidden-source
  windows on the menu-bar row. See the experiment and limits in
  [RESPONSIVENESS_RESEARCH.md](RESPONSIVENESS_RESEARCH.md#first-settings-opening-build-33-follow-up).
- **Responsiveness recommendations (2026-11-02):** implemented the four primary
  recommendations in [RESPONSIVENESS_RESEARCH.md](RESPONSIVENESS_RESEARCH.md).
  Login status refreshes at meaningful UI/lifecycle events; application URL/icons
  are cached and invalidated on app/path/volume or explicit refresh changes.
  Window metadata is queried by known IDs on a serial utility queue with at most
  one active and one replaceable pending request. Main-thread AppKit seeds and
  model revisions reject stale display/control/source ownership, edits, Reveal,
  permission changes, shutdown, and superseded results. Native input actions keep
  fresh synchronous validation, including build 31's visible-side overflow fix.
  The standard suite reports 160 tests passing; focused delayed-result/native
  inspection and existing recovery/placement/order/login checks pass. Native
  boundary/cancellation/movement harnesses compile with the new reader module.
  The revised 30-row benchmark runs actual background polling beside scrolling:
  synchronous median/p95 2.42/6.31 ms, warmed maximum 40.83 ms, warmed heartbeat
  gap 51.78 ms, poll latency 60.82 ms. Cold-inclusive heartbeat reached 101.82 ms;
  this is a measured improvement, not a guarantee of every 8/17 ms frame.
  Signed build 32 passed packaged smoke and reopened on the 1728/2560-point
  displays. Native readback found both expanded controls, nine observed hidden
  source owners, and zero visible hidden-source windows. Repeated incomplete AX
  scans briefly triggered the existing safe reveal; complete scans restored the
  layout automatically. A later idle profile shows metadata work on the worker
  queue, no login-status/icon-loading stack paths, and no sustained SwiftUI redraw
  loop. An earlier busy Settings-rendering burst remains unclassified; external
  app scan failures and cold UI work can still interrupt the ideal flow.
- **Concealment recurrence (2026-11-02):** display-change recovery at 11:29
  stopped because Control Center's unverified status window extended two points
  past the 1728-point display (`x=1595, width=135`). It was entirely right of
  the separator, but `canConceal` required full safe-area containment before
  checking its side. The resulting safety failure left every source revealed.
  Build 31 accepts trailing-edge overflow for concealment and polling when the
  source's leading edge lies inside the safe area and its vertical extent fits
  the active row. Hidden-side assignment, native interaction, and launcher
  checks remain strict. The captured-geometry regression failed before the fix;
  23 geometry checks, 139 standard tests, four AppKit recovery checks, and
  packaged smoke pass. The signed build was reopened with the existing saved
  layout; native-window readback confirmed all 10 observed hidden-source owners
  concealed, with zero hidden-source windows visible.
- **Item details (2026-11-01):** Forget, Retry, and pending-operation indicators
  precede the placement selector, keeping selectors aligned beside drag handles
  across running and closed apps. Existing visibility/enablement conditions are
  preserved. The minimum-width Settings snapshots, closed-app placement check,
  and packaged smoke pass.
- **Settings scrolling (2026-11-01):** live profiling found repeated WindowServer
  geometry queries in both inventory acceptance and Settings row rendering.
  Native inspection now reads one shared environment per complete inventory;
  Settings shows that inspection and native actions continue checking fresh
  geometry. Process rebinding precedes inspection, reveals clear presentation
  state, and incomplete scans retain the last complete inspection. Identical
  inventories no longer rebuild the live-item lookup. An isolated 30-row scroll
  benchmark reproduced a 403.39 ms warmed poll/render pause before the fix and
  87.93 ms afterward; median/p95 were 3.15/6.52 ms. Its 100 ms warmed-step guard
  passes twice. These are synchronous main-thread measurements, not display FPS;
  the first post-poll setup step still reached 110.52 ms. Standard tests and 12
  focused AppKit recovery/placement/order/drag checks and packaged smoke pass.
  Signed build 29 reopened with all 10 running hidden sources concealed. A second
  live profile shows native environment reads under the batch inspection, with
  none in Settings row rendering.
- **Layout preview (2026-11-01):** Always Hidden now uses the same 26-point
  icons, 36-point cells, and 8-point spacing as Dropdown. The native drag surface
  registers each item's name/placement tooltip; protected icons retain SwiftUI
  help. Preview snapshots, minimum-width Settings checks, the rendered RTL drag
  check, and packaged smoke pass.
- **Idle recurrence (2026-11-01):** at 10:53:59, two polls returned unknown
  boundary sides and revealed every source without scheduling recovery. Build 27
  reveals temporarily after two unverified polls and retries the saved layout
  after three seconds and a complete scan. Confirmed unassigned/protected sources
  behind the separator still stop for review, including mixed unknown/unsafe
  snapshots. Each source's side is sampled once per poll. The regression failed
  before the fix; four focused AppKit checks, 136 standard tests, and packaged
  smoke pass. The signed app was reopened at 13:58; native concealment recorded
  11 allowed identities and 10 running sources on the 1728-point built-in display.
  Three native-window readbacks over 30 seconds confirmed all 10 source windows
  remained entirely offscreen on the active menu-bar row.
  The original reason geometry became unavailable remains unconfirmed; prolonged
  idle behavior still needs observation.
- **Menu Bar ordering (2026-10-31):** preview drops and detail-row drops now
  apply the relative order of manageable Menu Bar sources, including Undo/Redo.
  Apply Saved Layout also enforces that order. Clipped sources are left untouched,
  protected sources are never dragged, and RTL keeps the physical icon strip
  left-to-right. Six caller tests, five native planning/eligibility tests, and
  three rendered drag tests pass. After rebuilding and reopening the signed app,
  WindowServer confirmed the real BroGlow source left of Tunnelblick, matching
  their saved order. The separate disposable `--reorder` check compiled but
  stopped before posting input because its harness lacks Accessibility permission.
- Development app: `dist/TrayNook Dev.app`, **1.0.0 (42)**, signed with the
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
TRAYNOOK_DEV_SIGNING_IDENTITY='TrayNook Dev' TRAYNOOK_BUILD=33 Scripts/build-app.sh
Scripts/smoke-test.sh
Scripts/test-native-cancellation.sh --compile-only
Scripts/test-native-movement.sh --compile-only
"dist/TrayNook Dev.app/Contents/MacOS/TrayNook" --diagnose
# Quit TrayNook first; isolated controls, synthetic inventory, no native input:
TRAYNOOK_SCROLL_BENCHMARK=1 Scripts/test.sh --filter ScrollPerformanceTests
TRAYNOOK_SETTINGS_OPEN_BENCHMARK=1 Scripts/test.sh -c release --filter SettingsOpeningTests
```

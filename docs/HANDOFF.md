# TrayNook: build 18, remaining cursor-free interaction work

Updated 2026-09-19. See [MVP_REPORT.md](MVP_REPORT.md) for measurements,
verification, and release blockers.

## Current state

- Development app: `dist/TrayNook Dev.app`, **1.0.0 (18)**,
  `io.github.mahenzon.TrayNook.dev`. Final packaged fixture opened in 638/603 ms,
  versus a measured build 17 baseline of 1,273 ms.
- Cursor interference is **reduced, not eliminated**. The final fixture saw
  25 ms sampled excursions, with a large 1,278 pt displacement. Strict
  zero-pointer acceptance still fails. Do not describe this as cursor-free.
- Opening the launcher keeps all sources hidden. Selecting a proxy promotes
  only that source beside TrayNook, verifies safe geometry, opens its native
  menu once, then restores its original neighbor/gap after observed dismissal.
- Final unit, packaged UI, native lifecycle, cancellation/motion-edge, no-space,
  and smoke checks passed. The report distinguishes simulated pointer races from
  real hardware motion. The opt-in renderer was not rerun for this controller change.
- Real menu samples: DockDoor 806–895 ms, MonitorControl 658 ms, ChatGPT 766 ms,
  Macs Fan Control 799 ms, Handy 796 ms. One earlier ChatGPT sample returned its
  source, then triggered inventory safety recovery at the next poll; exact
  changed window/source was not captured. Repeat passed after reapplying layout.
- Finder launch lost Accessibility approval after ad-hoc rebuild. The identical
  final executable is left running through the authorized development runner.
  Normal Finder launch needs renewed user approval; no TCC database was changed.
- The user authorized implementation, building, running, and testing autonomously.
  One desktop owner at a time; quit normal TrayNook before isolated fixtures.
- Work remains uncommitted, including substantial modified and untracked files
  from earlier sessions. Preserve them and unrelated `.vscode/` material.
- Disk had 28 GiB free at session start. Signing/notarization/publication remain
  pending; only a development preview is packaged.

## Read before changing interaction

- `Sources/TrayNook/NativeMenuBarController.swift`: `prepareActivation`,
  `activatePrepared`, `restoreActivation`, `moveTargeted`, `stableTarget`,
  `accessibilityTarget`, `releasePointer`, `TargetedMenuBarEventRelay`.
- `Sources/TrayNook/AppModel.swift`: `activate`, operation cancellation,
  pending-return recovery on `openDropdown`, inventory recovery.
- `Sources/TrayNook/NativeMenuInteraction.swift`: observer setup before action,
  matching native-menu lifecycle, uncertain-delivery handling.
- `Tests/Manual/DropdownUIRegression.swift`: packaged production test plus
  independent hidden-peer and cursor witnesses.
- `Tests/Manual/SelectiveCancellationCheck.swift`: input-edge and return races,
  oversized-source rejection. Its script instruments a temporary source copy.
- `docs/adr/0007-use-proxies-and-native-interaction-handoff.md`.

## What changed in build 18

One complete AX scan is bracketed by current WindowServer snapshots. A changed
window, PID/bundle, frame, visibility, or display invalidates the observation.
There is no cross-operation inventory cache. After promotion, fresh AX source
identity/geometry and all window bindings are rechecked, rather than scanning
all apps again. Return completion uses bounded neighbor/gap polling.

Movement retains a **50 ms down-processing dwell**: forwarding acknowledgment is
not proof of source-app processing, and removing the dwell lost a reorder in a
repeat test. The pointer now returns during that dwell, and immediately after
up. The old 150 ms post-up wait is gone. Queued down/up recheck pointer/input;
emergency session release uses the latest cursor position while the exact bound
source receives its recovery destination. A newer position must win over a
saved cursor position.

The profiled preparation fell from 1,148 ms to 486–536 ms; controller restoration
from 1,020 ms to 389 ms. The AX action still takes about 201 ms until response or
timeout, but the menu appears before that call returns. All timing probes were
removed before the final build. Do not retry uncertain actions to improve time.

## Failed experiments: do not assume these are untried fixes

1. Session event at current cursor, original targeted event to PID: delivered
   events but no WindowServer promotion.
2. Annotated-session delivery: preserved cursor but no promotion after down/up.
3. Tagged null-event substitution at session tap: relay timeout, no promotion.
4. No down dwell: intermittent missed reorder; reverted.

All failures retained the selected source hidden and sent no native menu action.
Public event delivery alone does not prove a usable reorder. Hiding/disconnecting
the cursor would not satisfy the physical-input requirement. No private APIs or
third-party source code were introduced.

## Next priority

Prove a pointer-free reorder with a disposable source and hidden peer, or find a
fundamentally different interaction consistent with the accepted native-menu
anchoring requirement. Run the strict check to keep the remaining defect visible.
Normal movement still requires 200 ms quiet input and can wait about ten seconds
while input continues. Validate actual hardware motion before claiming ownership
is solved; deterministic coordinate-race tests are narrower evidence.

Preserve pending return until verified; cancel the relay before emergency release;
arm recovery only when down posts and disarm synchronously when up is delivered.
WindowServer rewrites routing PID at the session tap: match tag/type/window fields
and forward the stored event to the bound PID. `.optionAll` is required to find
offscreen windows. Never reveal peers as a normal activation fallback.

Custom panels, secondary actions, and the broader OS/display matrix remain open.
Explicit reveal, Settings cancellation, and unsafe environment recovery are
intentionally global. One selected icon must fit safely to the right of the notch.

## Repeat checks

```sh
Scripts/test.sh
TRAYNOOK_BUILD=18 Scripts/build-app.sh
Scripts/test-dropdown-ui.sh --invalid-positions --layout "$HOME/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json" "dist/TrayNook Dev.app"
Scripts/test-native-cancellation.sh
Scripts/test-native-menu.sh
Scripts/smoke-test.sh
# Expected to expose the remaining brief cursor jumps:
Scripts/test-dropdown-ui.sh --require-still-pointer --layout "$HOME/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json" "dist/TrayNook Dev.app"
```

The fixture copies the saved layout read-only and verifies cleanup/order. Its
ordinary pointer budget is below 150 ms; the strict option requires zero sampled
movement. The nominal 120 Hz timer has lower actual sampling under system calls.

Disposable logs are `/private/tmp/traynook-build18-*.log`; method profiles are
`/private/tmp/traynook-profile-baseline.log` and
`/private/tmp/traynook-short-pointer-profile.log`. A real-app probe is in
`/private/tmp/traynook-build18-real-probe.swift`. These are diagnostic aids, not
repository dependencies. Real checks use actual launcher/proxy clicks and dismiss
menus without choosing commands. DockDoor also has an unrelated status-level
floating window: match its actual menu-bar row.

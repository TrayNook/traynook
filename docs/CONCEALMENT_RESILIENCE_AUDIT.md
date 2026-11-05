# Concealment resilience audit

Date: 2026-11-05. Baseline: `b7727e7`, signed development build 41.

## Requirement

Hiding the user's selected Source Items is the primary feature. An unrelated
application, optional Menu Bar ordering, image capture failure, or a failed
single-item interaction must not unnecessarily reveal every hidden Source Item.
Desired Layout remains authoritative even when macOS refuses one placement.

Three independent Lazarus researchers audited inventory/lifecycle handling,
native layout application, and native interaction return paths. These findings
are confirmed code paths and reproducible scenarios; they are not claims that
every named or installed application has exhibited each failure on device.

## Findings and fallbacks

| Trigger | Baseline behavior | Required fallback |
| --- | --- | --- |
| A new, confidently identified item is already verified visible | `inventoryRequiresReveal` reveals the hidden section because the key is new | Accept the new Menu Bar item without disturbing concealment |
| A saved hidden app restarts with its item on the visible side | Its PID is adopted, but nothing moves it back | Queue an identity-bound selected-item repair; preserve the other hidden items and expose an affected-item Retry if bounded attempts fail |
| A display-sized status-level preview changes during incomplete AX scans | Raw panel geometry invalidates the stable-source baseline | Reuse discovery's conservative source-candidate filter for the native-window baseline; genuine source changes still invalidate it |
| One item refuses placement, or optional visible ordering fails | Full-layout application exits before concealment and reveals all items | Revalidate the inventory and boundary after an isolated source failure; finish valid placements and concealment; report affected items separately; visible ordering is best effort |
| A native panel return fails, a menu outlives the foreground timeout, or its former return neighbor disappears | The selected item can remain promoted indefinitely | Retain dismissal observation, retry only the selected return, and use the freshly validated hidden boundary when the former anchor is confirmed gone |

The three-second discovery watchdog and expired AX results now verify a fresh,
complete native source-window enumeration on the existing bounded worker reader.
If that enumeration exactly matches the last verified baseline, concealment is
retained and editing pauses. Stale AX results are rejected before adopting
processes or updating inventory; they cannot undo that independent verification.

Related temporary failures include missing controls during protected-item
preparation, a menu bar that keeps changing across stability samples, and
separator expansion that has not settled. Unknown geometry must block native
input while retaining an automatic recovery opportunity. Confirmed unsafe
placement is a different outcome.

Boundary repair rechecks all nonfailed placements because moving the separator
can expose a previously hidden source. Each refused source is excluded from
further attempts within that application pass, bounding the replanning loop.
Lifecycle repair attempts are charged only when dispatched; temporary input or
inventory failures retain three-second pacing without consuming the refusal
budget. Explicit Retry remains available after a source refuses three attempts.

Handoff return also handles proven pre-delivery failure, a return neighbor moving
to the visible side, and termination of the original owner. An observed panel
must disappear from a complete owner-window enumeration to count as closed;
changing its shape or having unavailable geometry does not prove dismissal.

## Primary code evidence

- [AppModel](../Sources/TrayNook/AppModel.swift): `prepareInventory`,
  `applyInventory`, `inventoryRequiresReveal`, `acceptScanStatus`,
  `applyAndConceal`, `retryLayoutRecovery`, `activate`, and `watchPanel`.
- [Native menu-bar controller](../Sources/TrayNook/NativeMenuBarController.swift):
  `prepareLayout`, `conceal`, `stableTarget`, `reorderMenuBarItems`,
  `restoreActivation`, and the native status-window binding checks.
- [Inventory discovery](../Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore/AccessibilityInventory.swift):
  `statusWindowSourceCandidates` already distinguishes conclusive panels from
  possible Source Items, while the original stable-window snapshot used all raw
  status-level windows.
- [Native interaction observation](../Sources/TrayNook/NativeMenuInteraction.swift):
  `waitForDismissal` originally canceled observation at its timeout;
  `panelWindows` excluded every status-level window, including large panels.
- [Native handoff decision](adr/0007-use-proxies-and-native-interaction-handoff.md)
  and [explicit drag intent](adr/0006-explicit-user-drag-updates-desired-layout.md):
  repair only the affected item, and do not reinterpret an ordinary same-process
  user drag as an application restart.

## Safety constraints

Fallbacks must use fresh permission, source identity, process/window ownership,
and geometry validation. They must never replay a native activation whose
delivery is uncertain. A source's exact old binding cannot authorize input to a
replacement source or sibling.

Explicit Reveal, shutdown, and replacement interactions cancel background work.
The launcher remains accessible. The final concealment guard continues to reject
an actual unassigned/protected item behind the separator. Permission loss,
identity ambiguity, and physically unavailable menu-bar space remain real
platform limits; fallback must explain the affected capability instead of
claiming success.

Completely unobservable app interfaces are not proven dismissed by an elapsed
timeout. They retain an explicit manual-return path.

## Verification

- Baseline: 184 standard tests. Final `Scripts/test.sh`: **223 passed**.
- Isolated AppKit suites, run sequentially with TrayNook quit: concealment
  recovery **15**, background acceptance **7**, idle publication **2**, and
  Menu Bar ordering **6** tests passed, **30 total**.
- Native menu, selective placement, and cancellation harnesses passed
  `--compile-only`. The runtime native-menu check stopped at its Accessibility
  preflight because the invoking terminal is not trusted; it generated no native
  pointer input. Cross-application menu/drag acceptance therefore remains a
  separate device-verification limit.
- Signed development build **42** passed packaged smoke, including existing
  recovery, launcher, and Settings checks, and reopened with the existing saved
  layout. Four WindowServer readbacks over 30 seconds found **9 hidden-source
  owners and zero visible hidden-source windows**.
- The running build recovered from temporary unavailable inventories at
  **19:04:33** and **19:04:42**, concealed at **19:04:48**, and retained hiding
  through incomplete scans at **19:04:57**, **19:05:28**, **19:05:37**, and
  **19:05:44**. Times are Europe/Moscow on 2026-11-05. This is live recovery
  evidence, not a claim of testing every third-party application or prolonged
  idle stability.

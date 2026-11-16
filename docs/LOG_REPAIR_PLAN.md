# TrayNook log review and repair plan

Reviewed and implemented 2026-11-16. Build **44** contains the confirmed recovery
fixes, bounded diagnostics, and defensive display validation. The initial review
and proposed repair packages below preserve the evidence and acceptance goals;
[implementation results](#implementation-results) distinguish completed checks
from hardware scenarios that remain unverified.

## Evidence and coverage

The rolling seven-day process query returned **815 records on November 13–16**.
Of these, **466 belong to TrayNook's own subsystem**, all on November 16,
06:46:06–10:58:02 Moscow time (UTC+03:00). Earlier retained process records are
mostly LaunchServices notifications and SkyLight errors; they cannot establish
whether concealment or interaction worked on those days. No matching entries
were returned for November 9–12. Missing records do not establish inactivity or
health, and the reason for missing historical application logs is unknown.

The process executable UUID matches `dist/TrayNook Dev.app`, version **1.0.0
(43)**. This identifies the binary; it does not prove that every current source
file is identical to the source used to build it. The existing handoff document
describes build 42 and is historical context.

The [evidence snapshot](evidence/2026-11-16-log-review.json) contains the query,
daily coverage, event counts, binary UUID, selected timestamps, and system
errors. Counts below use this one process capture. The initial subsystem-only
capture ended earlier and is not added to it. Raw exports remain temporary
files under `/tmp`; the JSON preserves the selected evidence.

### What actually happened

1. **Sleep and eventual recovery, November 16.** At 09:10:54.812 the section was
   revealed; the model recorded `NSWorkspaceWillSleepNotification`. Six
   incomplete-scan error entries followed at 09:10:57–09:11:21, while the section
   was already revealed. A layout attempt failed at 09:11:14.716. The next logged
   attempt at 09:14:11.201 completed concealment at 09:14:12.436, with nine source
   owners. The approximately 3 minutes 18 seconds is the interval from the first
   reveal to concealment, **not measured wake-to-recovery latency**: no wake event
   is logged. These are one recovery episode, not six independent reveals.
2. **Interrupted interaction and return, November 16.** A tray click at
   10:54:46.372 was followed by an input-interrupted operation at 10:54:47.931.
   Return attempts began at 10:54:48.599, 10:54:54.780, and 10:54:58.607. Two
   failed with unavailable inventory; four internal return retries reported
   interrupted input. No final return success or failure is logged. The source
   identity and delivery stage are absent, so the capture cannot establish that
   the item stayed promoted or that activation was delivered.
3. **Display errors across days.** SkyLight reported `invalid display identifier`
   seven times on November 13 and twice on November 16. Today's two entries were
   at 10:28:28.474 and 10:28:28.498. Private fields and missing call-site context
   prevent assigning a root cause. There were also 78 display-parameter
   notifications and 54 active-menu-bar-row changes today. Row changes can be
   normal foreground-display behavior; their volume alone is not a bug.
4. **Concealment protection worked repeatedly.** There were 283 transitions into
   incomplete scans that retained concealment because native windows were
   unchanged. These are successful safety fallbacks, not 283 reveal incidents
   or a count of all scans. One unknown-geometry sample at 10:49:23 was tolerated
   without a subsequent logged unsafe-item reveal. Do not remove these guards.

Four `operation failed` entries and six incomplete-scan `revealed` entries make
up the ten application error records. They are log entries within the episodes
above, not ten independent user-visible failures.

## Repair packages in execution order

Estimates are engineering time, including focused tests. Device observation
adds elapsed time. Priorities reflect user impact and evidence; they do not
imply that an unconfirmed cause has already been reproduced.

### 1. P1 — Make scan and recovery outcomes diagnosable

**Effort: 4–8 hours.** This is the prerequisite for packages 2–4.

The scanner already collects aggregate timing and failure metrics, but the
retained application messages omit them. Successful selected returns have no
completion event. `DiagnosticsReport` holds current state and the last event;
it is not historical evidence. Repeated incomplete-scan logs name BroGlow,
Telemost, Alice, and once Tunnelblick, but do not identify the failed AX
operation or distinguish a timeout from a budget or geometry failure.

1. Extend existing events with fixed operation stages, result codes, scan age,
   duration, incomplete/cannot-complete counts, and retry cause. Record selected
   return completion, owner termination, cancellation, and manual-retry outcomes
   with an interaction identifier and affected bundle identifier. Use the
   existing scanner metrics and diagnostics structures.
2. Record a bounded first failure per affected process: AX operation category,
   AX error code, elapsed time, and whether the overall budget expired. Never
   record attribute values, item labels, window titles, images, or input events.
3. Add a small local rotating diagnostic history of these sanitized events,
   retained for seven days with a fixed size cap. OS unified logging alone did
   not provide the requested historical detail. Keep it local; add no telemetry,
   network upload, or background service. Preserve the existing diagnostics UI.
4. Add focused tests for event ordering, result-code distinctions, privacy,
   rotation limits, and non-destructive readback. Use injected storage/time.

**Affected code:** [AppModel](../Sources/TrayNook/AppModel.swift)
(`acceptScanStatus`, `runOperation`, `watchPanel`, `diagnosticsReport`),
[native controller](../Sources/TrayNook/NativeMenuBarController.swift)
(`freshInventory`, `restoreActivation`),
[scanner](../Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore/AccessibilityInventory.swift)
(`AccessibilityScanIssueTracker`, `scan`), and
[DiagnosticsReport](../Sources/TrayNook/DiagnosticsReport.swift).

**Done when:** an interrupted return and a wake recovery each have an attributable
start, blocker, and terminal result; fixture history remains readable after a
simulated seven-day run within its size/privacy limits. Classify expected input
interruption separately from permanent failure. Do not merely suppress errors.

### 2. P1 — Resume layout recovery from actual wake and session activation

**Effort: 4–8 hours, plus five device sleep/wake cycles.**

Both the app delegate and native controller observe sleep/session resignation.
The model reveals and schedules recovery ten seconds from that notification.
Neither observer set subscribes to wake/session activation. Recovery then
depends on periodic scanning and successful complete inventory. That lifecycle
gap is confirmed in code; its contribution to today's wall-clock interval is
unmeasured. The current reveal-on-sleep policy is intentional safety behavior.

1. Add explicit wake/session-active handling and a testable suspended/resuming
   state. Cancel or defer automatic scans and native layout work while suspended;
   retain safe cancellation and existing reveal behavior.
2. On resume, invalidate stale inventory/geometry and request a fresh scan.
   Recover once both inventory and physical input are safe. Pace retries from
   resume/fresh results, rather than assuming a pre-sleep timer proves readiness.
3. Coalesce duplicate lifecycle notifications without canceling an already
   completed recovery or overwriting explicit Reveal. Keep permission loss and
   identity review as reasons to stop automatic work.
4. Extend the existing recovery fixtures with sleep longer than ten seconds,
   duplicate resign/sleep events, incomplete initial wake scans, session unlock,
   and explicit Reveal during recovery. Confirm there is no native input while
   suspended and no duplicate layout dispatch after resume.

**Affected code:** observer wiring in
[TrayNookApp](../Sources/TrayNook/TrayNookApp.swift), native lifecycle handling in
[NativeMenuBarController](../Sources/TrayNook/NativeMenuBarController.swift), and
`environmentChanged`, `refresh`, `takeLayoutRecovery` in
[AppModel](../Sources/TrayNook/AppModel.swift). Extend
[ConcealmentRecoveryTests](../Tests/TrayNookTests/ConcealmentRecoveryTests.swift).

**Done when:** five device cycles recover automatically without manual Apply;
after the first complete, usable post-resume scan and idle input, layout work
starts within one three-second poll interval. Record actual wake timestamps and
any remaining blockers. Never claim the entire sleep interval as recovery delay.

### 3. P1 — Keep a selected return from depending unnecessarily on unrelated apps

**Effort: 1–2 engineering days, including native acceptance.**

`restoreActivation` calls `stableTarget`, which calls `freshInventory` and
requires a complete scan of every source app. Therefore an unrelated scan
failure can prevent returning the selected item. This dependency is confirmed;
today's two return errors could also be caused by stale results, changed
geometry, or bindings, so the exact branch needs package 1's diagnostics.
Paced retry already exists in `retrySelectedReturn`; adding another retry loop
would duplicate it.

1. Reproduce with a responsive selected source, an unrelated AX failure, and a
   dismissed observed interface. Exercise the real restore-validation path,
   rather than only a closure that throws `inventoryUnavailable`.
2. If unrelated AX failure is the blocker, introduce return-specific validation
   at the existing native controller seam. Require fresh permission, exact
   source PID/window/identity, freshly rebound selected AX identity, validated
   hidden boundary/anchor, stable native source-window observations, and idle
   input. Do not reuse stale inventory to authorize input. If equivalent safety
   cannot be established, retain the current refusal and expose its exact blocker.
3. Reuse the existing three-second return scheduler. Publish pending/success/
   manual-retry state for the selected source; clear it only after verification
   or confirmed original-owner termination. Never replay activation.
4. Add regressions for unrelated AX failure, selected-owner AX failure, reused
   window identity, vanished/moved anchor, pointer interruption, and explicit
   Reveal/cancellation. Run the existing native menu and cancellation harnesses
   with their required Accessibility permission and idle-input setup.

**Affected code:** `restoreActivation`, `stableTarget`, `freshInventory`,
`restorationBindings`, and `retrySelectedReturn` in the
[native controller](../Sources/TrayNook/NativeMenuBarController.swift),
`returnPromotedItem`/`watchPanel` in
[AppModel](../Sources/TrayNook/AppModel.swift), and
[HandoffRecoveryTests](../Tests/TrayNookTests/HandoffRecoveryTests.swift).
Preserve the [handoff contract](adr/0007-use-proxies-and-native-interaction-handoff.md).

**Done when:** the captured class of interruption reaches a verified selected
return or an actionable, attributed refusal; peers stay concealed, changed
identities receive no input, and every scenario delivers activation at most once.

### 4. P2 — Reproduce invalid display IDs and eliminate redundant invalidation

**Effort: 4–8 hours for instrumentation and reproduction; allow one further day
for a confirmed fix and two-display acceptance.**

Nine SkyLight errors justify investigation. The logs do not establish that
`CGDisplayBounds`, stale screen objects, mirroring, or a particular TrayNook call
caused them. Ordinary active-row switching is required behavior under
[ADR 0010](adr/0010-geometry-follows-the-active-menu-bar-row.md).

1. Correlate existing screen/row-change paths with sanitized display topology,
   generation, pending-operation state, and before/after API stages. Reproduce
   disconnect/reconnect, sleep with an external monitor, and foreground movement
   between displays. Capture the failing call before choosing its fix.
2. If the caller uses an invalidated display, reject that stale topology before
   querying geometry and require a current inventory. Reuse current generation
   checks and native metadata validation; do not guess a substitute display.
3. Coalesce only notifications whose validated topology and control bindings
   are unchanged. Preserve invalidation for genuine row, mirror, owner, or window
   changes. Do not add a timer that authorizes actions with old geometry.
4. Extend display recovery and metadata-reader tests for removed IDs, duplicate
   notifications, mirror replacement, stale results, and a pending selected
   return. Verify on the built-in display and external monitor.

**Affected code:** `noteInventory`, `environmentSeed`, `screenParametersChanged`
in [NativeMenuBarController](../Sources/TrayNook/NativeMenuBarController.swift),
`revalidateDisplayInventory` in [AppModel](../Sources/TrayNook/AppModel.swift),
and existing [metadata-reader](../Tests/TrayNookTests/WindowMetadataReaderTests.swift)
and [recovery tests](../Tests/TrayNookTests/ConcealmentRecoveryTests.swift).

**Done when:** the reproduced invalid-ID scenario has a passing regression,
unchanged notifications preserve valid work, real topology changes reject stale
work, and device verification shows accessible Launcher controls and concealed
peers throughout safe transitions. If the errors cannot be reproduced or assigned
to TrayNook, retain diagnostics and defer speculative display changes.

## Verification and boundaries

Current-source baseline:

```sh
Scripts/test.sh --filter 'HandoffRecoveryTests|AccessibilityErrorClassificationTests'
```

Build completed in 4.50 seconds; **29 tests in two suites passed**. These tests
cover error classification, retry policy, cancellation, and return-anchor rules.
They do not exercise today's complete cross-app failure path or physical input.

After each implementation, run its focused regression, the standard suite, and
packaged smoke. Run isolated AppKit recovery tests with the production app quit;
native checks also require a trusted launching process and an idle pointer.
Current live native interactions and sleep/display cycles were not disturbed
during this review. No TrayNook-named crash reports were found in the two standard
DiagnosticReports directories; archive subdirectories were not searched.

The four missing Mach-O-path errors and one LaunchServices-store error have no
identified user impact or actionable caller in this capture. Keep them as
evidence and correlate recurrence; do not start a separate repair based only on
these private OS messages. Likewise, do not increase AX timeouts globally, trust
partial inventory for movement, remove physical-input guards, or rewrite the
working concealment fallback.

## Implementation results

Signed development build **1.0.0 (44)** was rebuilt, passed packaged smoke, and
launched with the existing saved layout. The running executable UUID matches
the packaged binary. Four native readbacks spaced three seconds apart observed
nine hidden-source owners and zero visible hidden-source windows. The sampled
running-process log from 11:48:57 to 11:50:44 Moscow time contains 25 entries and
no Error/Fault entries. This is startup verification, not prolonged idle proof.
See the [machine-readable receipt](evidence/2026-11-16-build44-verification.json).

1. **Diagnostics implemented.** Fixed event/result enums, affected bundle/process
   IDs, first scan failure category/error/timing, scan age, retry results, and
   successful return/recovery outcomes are saved locally. History is limited to
   seven days and 1 MiB, with asynchronous writes and private permissions.
   Repeated identical background failures are rate-limited; size pressure may
   evict older records sooner. Corrupt/newer/oversized histories are preserved.
   User-facing privacy and development documentation disclose this bounded
   technical operation history. Copy Diagnostics does not include the history.
2. **Lifecycle recovery implemented.** Separate sleep/session flags gate scan
   acceptance, editing, and operation dispatch. Native suspension reaches the
   model before reveal. Wake resumes once both flags clear, with fresh inventory;
   explicit Reveal remains authoritative. Independent review caught cancellation
   before a task starts and lost queued layout intent; both were reproduced
   before fixing unconditional placement cleanup and queued-request recovery.
3. **Selected return implemented.** Selected AX identity is rebound between
   fresh permission/control/native-source observations, then revalidated after
   input settles. Unrelated apps' AX trees are not consulted. Exact source and
   anchor checks, cancellation, and paced move-only retry remain. Review also
   caught popup-menu traversal; the selector now shares discovery's policy to
   stop at a menu-bar item. Pure validation tests exercise the production read
   seam, not actual cross-app pointer delivery.
4. **Display validation implemented; historical cause remains unproven.** The
   scanner, controller, and native interaction observer share online-display
   validation and reject bounds if a disconnect races the read. Online mirrors
   remain eligible. Genuine topology/control changes still invalidate work;
   notification coalescing was not added without evidence of equivalence.
   The nine older SkyLight errors and private Mach-O/LaunchServices messages
   cannot be declared fixed from their retained payloads.

The final standard Swift run reports **281 tests passed**. Ten isolated AppKit
runs report **86 checks passed**, including 32 concealment-recovery tests. The
native menu observer passes all three checks in both notification variants,
and native boundary visibility passes on device. All native harnesses compile.
Movement stops at its unavailable visible-fixture precondition; placement and
cancellation stop on physical input. These stops were retained as verification
limits, not converted to passing tests or bypassed by relaxing safety checks.
Real sleep/power cycles and prolonged idle behavior remain unverified.

Trusted-Terminal diagnostics report Accessibility granted, complete inventory,
22 items, zero incomplete apps, and Screen Recording not granted; app-icon
fallback remains available. Direct diagnostics from the untrusted command runner
report denied access, while GUI launch and trusted Terminal use their existing
privacy grants. Packaged smoke creates no diagnostic history; the launched app
creates its history with mode `0600` and records successful layout completion.

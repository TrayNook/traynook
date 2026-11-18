# TrayNook log review and repair plan

## November 18 follow-up: build 48

Evidence was collected before quitting or rebuilding. The live process was
**1.0.0 (47)**, PID **35488**, launched November 17 at 17:35:01 Moscow. Its sample
and package share UUID `570C4AB9-0A2B-39F8-B0C3-6A8F3A4B9323`. Build 45 in the
request was historical. The comparison cutoff is the final idle-native check at
**November 17 17:35:51.331989 Moscow**, rather than the earlier build-47 launch.
Pre-quit native readback found seven hidden owners and 14 current-menu-row
windows, all concealed.

### Actual coverage and classification

- **Local history:** 772 events, **November 16 11:48:57–November 18 11:15:34
  Moscow**, 225,552 bytes. The **128** events after the cutoff span November 17
  **17:42:09** through November 18 **11:15:34**: 33 sampled incomplete inventories,
  36 complete inventories, 54 display events, one concealment transition, one
  suspend/resume pair, and one saved-layout start/completion pair. There are
  **zero terminal operation failures, activations, selected returns, or recorded
  input interruptions** in this interval. Sampled transitions do not count all
  scans, and thirty-day retention cannot backfill history before November 16.
- **Unified logs:** the eight-day process/subsystem query returned **9,473
  records**, November 16 **22:05:25** through November 18 **11:15:12**. Only **180**
  are log messages; **9,293** are TCC/CoreFoundation activity records. Daily
  message totals are 31, 30, and 119 for November 16–18. Application messages
  cover only November 18 **07:41:50–11:14:35** (94 records). The live PID has 124
  retained messages, 119 after the cutoff. There are no matching query records
  before November 16 22:05 within the requested eight-day window. Earlier sparse
  system messages and activity metadata do not fill the missing application
  coverage, including November 17 evening and earlier overnight details.
- **One recovered sleep episode:** the expected environment reveal at
  **09:15:10.199** precedes suspension. Resume at **10:11:08.051** is followed by
  seven already-revealed inventory waits, the first complete inventory at
  **10:11:29.756**, dispatch at **10:11:29.904**, native concealment at
  **10:11:30.734**, and completion at **10:11:31.275**. Resume-to-completion is
  **23.224 seconds**; complete-inventory-to-dispatch is **0.149 seconds**. These
  are one expected safety reveal and one successful recovery. Current lifecycle
  and fresh-inventory gates match the trace; incomplete wake scans cannot
  authorize movement. Six unchanged-native incomplete-scan transitions and one
  slow-discovery fallback retain concealment successfully. Two tolerated partial
  scans, 53 menu-bar-row messages, and 54 history display events are observations,
  not separate failures.
- **System messages and crashes:** three process-attributed Metal errors at
  **10:11:30.754**, **10:23:17.417**, and **10:54:01.720** report a private missing
  Mach-O path. Framework-only backtraces establish neither a TrayNook caller nor
  user impact. No application Error/Fault messages occur. Both standard crash
  directories, including archive subdirectories, contain **95 files** with no
  TrayNook filename/header matches and no read errors (first 8 KiB inspected).

### Verification and delivery

No new product defect or failing behavioral reproduction was established.
Product code, safety guards, timeouts, and logging policy remain unchanged;
no speculative fix or duplicate regression was added. Build **48** increments
the development bundle version while retaining the verified current code.

The standard suite passes **292 tests in 45 suites** with host access; its initial
sandbox run refused the unchanged loopback-server bind with `EPERM`. Ten
sequential isolated AppKit runs pass **87 checks**. Both native-menu notification
variants pass three checks each; native boundary passes three cycles. Selected
placement passes two show/hide cycles with **118 sentinel samples, zero reveals
or unavailable samples**, and all **35 original windows surviving cleanup**.
Movement stops before input because its 36-point fixture lacks visible space.
Cancellation stops during queued-down preparation because physical input is not
idle, posting **0 down / 0 up / 0 recovery events**; no phase completes. These
are blocked checks. Trusted-Terminal diagnostics report Accessibility granted,
complete inventory, 18 items, zero incomplete apps, and Screen Recording not
granted; app-icon fallback remains available.

Signed development build **1.0.0 (48)** passes packaged smoke and launches at
**11:23:17.706 Moscow**, PID **39745**. The existing **TrayNook Dev** certificate
and deep/strict signature verification pass. The live sample reports build 48
and the package's UUID; its unchanged executable UUID is expected because only
the bundle build number changed. Four native readbacks three seconds apart find
**seven hidden owners, 14 current-row windows, zero visible**, with no detected
owner/frame/presence/topology races. The startup capture spans
**11:23:17.745–11:23:28.586**, with 226 log messages and 33 activity records.
It contains **one private Metal Mach-O error** at **11:23:22.118** and **zero
application Error/Fault messages**. Saved layout completes at **11:23:22.539**,
followed by concealed native readbacks. This recurrence is not declared fixed.

The native witness brackets explicit onscreen-ID membership with `.optionAll`
reads and uses current online display rows. An initial omitted-onscreen-flag
capture was retained as inconclusive, then corrected with this explicit query.
Off-row secondary/stale windows and an oversized panel are excluded and reported
separately; all were offscreen. The witness covers observed owner/windows,
not AX sibling identities. Four saved hidden owners are closed, and running
Codex has no observed menu-row window; their absence does not prove concealment.

Layout contents, item order, placements, and row capacity are preserved. By the
pre-native checkpoint only JSON object key order differed from the original;
smoke and launch preserve those checkpoint bytes. Smoke leaves history bytes
unchanged; launch preserves the entire original history prefix and mode `0600`.
`ExtendedLocalDiagnosticHistory` stays enabled at **30 days/32 MiB** on this Mac;
public defaults remain **seven days/1 MiB**. No log upload or system-wide
retention change occurred. Raw captures remain local under
`/private/tmp/traynook-review-20261118`; the
[sanitized receipt](evidence/2026-11-18-build48-log-followup.json) records the
coverage, readback method, outcomes, and preservation checks.

Controlled five-cycle sleep/wake, monitor reconnect, remaining cancellation
phases, and prolonged build-48 idle acceptance remain unverified. The observed
organic wake recovery is useful evidence, not replacement hardware acceptance.

## November 17 afternoon follow-up: build 47

**Idle native recheck at 17:34 Moscow:** selected placement now passes two
show/hide cycles, with 142 sentinel samples, zero revealed/unavailable samples,
and all 17 original windows surviving cleanup. Cancellation passes queued-down,
delivered-down/up, queued-motion, queued-up-motion, and motion-down/up. It then
refuses `inventoryUnavailable` during return-motion-down preparation, with
zero tested return-sequence down/up/recovery posts; preceding source promotion
ran before those counters reset. Remaining return and terminal cases stay
unverified. Movement still refuses the unavailable visible fixture. No guards or
production code changed. Build 47 relaunched with its matching UUID; four native
readbacks again found seven hidden-source owners, nine windows, zero visible.
Saved layout bytes, history prefix and extended retention were preserved. This
recheck supersedes the physical-input blockers below; it does not add sleep,
display-cycle or prolonged-idle acceptance. Raw evidence is local under
`/private/tmp/traynook-idle-native-20261117`; the receipt includes
`native_idle_recheck`.

Evidence was collected before quitting. The live sample identified **1.0.0
(46)**, PID 25392, with UUID `9EED66E6-C204-31C5-909E-E713FBF70E0B` matching the
package. Build 45 in the request was historical. The previous receipt's final
verified check at **00:29:53 Moscow** is the comparison cutoff. Native readback
found seven hidden-source owners, nine source windows, and none visible.

### Actual coverage and classification

- **Local history:** 626 events, **November 16 11:48:57–November 17 17:09:50
  Moscow**, 166,644 bytes. The 96 events after the cutoff span **02:58:54–17:09:50**:
  50 complete-inventory events, 34 sampled incomplete-inventory events, and six
  layout attempts. Five attempts completed; one deferred at **13:06:46.620** for
  unavailable inventory, followed by a successful attempt at **13:06:54.468**.
  No terminal operation failure, activation, selected-return, or physical-input
  interruption event occurs in this interval. These are sampled transitions,
  not a record of every scan or every interruption on the Mac.
- **Unified logs:** the eight-day process/subsystem query returned **1,497
  records**, November 13 **15:05:00** through November 17 **17:17:26**. Daily
  totals are 15, 3, 4, 1,156, and 319 for November 13–17. Build 46 has 308
  process-attributed records from **00:25:18–17:17:26**; only 108 application
  subsystem records remain, **13:17:13–17:16:59**. No matches remain November
  9–12. Earlier sparse system records do not establish application health.
  Application details before 13:17, including the 13:06 recovery trigger, are
  missing. Extended local retention cannot backfill history before November 16.
- **Distinct recovered episodes:** unknown-geometry safety reveals at
  **14:33:05.113** and **16:19:31.941** reached native concealment at
  **14:33:09.119** and **16:19:35.853**, respectively. A new Zoom source at
  **16:57:27.538** was reconciled by **16:57:28.347**. The two error records are
  temporary safety reveals, not terminal failures. Repeated `unsafe once`
  messages are debounced observations, not separate reveals. There are also
  **27** incomplete-scan transitions and **two** slow-discovery messages retaining
  concealment through unchanged native-window verification: successful fallbacks.
- **System messages and crashes:** build 46 has two AppKit `Dock connection
  error: Connection interrupted` records at **13:49:43.744** and **13:50:39.417**,
  with no demonstrated TrayNook user impact or actionable caller. The broad
  query's 23 private invalid-display errors and one LaunchServices-store error
  belong to earlier processes. No cause was invented for these messages or for
  unavailable geometry. No TrayNook match was found among **98 files** in both
  standard crash-report directories, including archive subdirectories, using
  filenames and the first 8 KiB of report headers; no read errors occurred.

### Confirmed defect, fix, and verification

The two geometry-reveal causes were absent from JSONL: `recordReveal` only
updated the current in-memory snapshot. A focused AppKit regression reproduced
zero history events for geometry, identity-review, and user reveals before the
fix. Build 47 records `concealment / changed` with a fixed reason only when
`AppModel.reveal()` transitions from concealed. Debounce polls and repeated
revealed-state cleanup emit no transition; annotation-only `recordReveal` remains
in-memory to avoid inventing cleanup events. This covers model reveal calls,
not every native separator movement. No item labels, window titles, raw error
text, input contents, or extra preferences were added. Existing schema-v1 events
remain readable. Safety checks and recovery scheduling are unchanged; the
underlying unknown-geometry caller was not reproduced or assigned.

The standard suite passes **292 tests in 45 suites**; ten sequential isolated
AppKit runs pass **87 checks**, including 33 recovery tests. Both native-menu
observer variants pass three checks each, and native boundary passes three
cycles. Movement stops before input because its 36-point fixture lacks visible
space. Placement refuses physical input at setup; its sentinel witness is
unavailable. Cancellation refuses physical input in queued-down preparation,
posting **0 down / 0 up / 0 recovery events**. These are blocked checks, not
passes; guards remain intact. Independent review found no correctness/privacy
issues in the logging change. Trusted-Terminal diagnostics report Accessibility
granted, complete inventory, 20 items, zero incomplete apps, and Screen Recording
not granted. The app-icon fallback remains available.

Signed development build **1.0.0 (47)** passed packaged smoke and launched at
**17:28:00.440 Moscow**, PID **29051**. Live sample UUID
`570C4AB9-0A2B-39F8-B0C3-6A8F3A4B9323` matches its package; signing authority is
the existing **TrayNook Dev** certificate. Four native readbacks three seconds
apart find **seven hidden-source owners, nine windows, zero visible**. The startup
capture spans **17:28:00.472–17:28:53.394**, with 250 process records, 14 application
records, and no Error/Fault entries. Startup history records successful saved
layout completion at **17:28:02.127**. Smoke preserves layout/history hashes;
launch preserves layout bytes and the complete old history prefix, mode `0600`.
`ExtendedLocalDiagnosticHistory` remains enabled at **30 days/32 MiB**; public
defaults remain **seven days/1 MiB**. No upload or system-wide retention change
occurred. Raw captures remain in the private local directory
`/private/tmp/traynook-review-20261117-afternoon`.

Actual sleep/wake, monitor reconnect, and prolonged post-fix idle behavior remain
unverified. The observed earlier build-46 recoveries demonstrate bounded
successful episodes, not a guarantee that every geometry failure recovers.
See the [machine-readable receipt](evidence/2026-11-17-build47-log-followup.json).

## November 17 follow-up: build 46

The original running process was **1.0.0 (45)**, PID 96914, with UUID
`E7181DED-CA92-37A1-A978-A0611CDF288E` matching the packaged binary. Evidence was
captured before quitting: the local JSONL history, an eight-day process/subsystem
unified-log query, a live process sample, saved layout, native visibility, and
both standard crash-report directories including archive subdirectories.
Native readback reproduced **four visible saved hidden-source windows**.

### Coverage and failure classification

- **Local history:** 516 events on November 16, **11:48:57–23:50:59 Moscow**.
  Eleven operation groups in the old `layout` category contain seven completions,
  three inventory deferrals followed by successful attempts, and one terminal
  `unknown` failure at **18:21:55.198**. This category does not identify whether
  the operation was a full layout, a single placement, or Menu Bar ordering.
  Four complete scans during that operation reported 45 sources; the next
  complete scan reported 20. That change does not establish a cause.
- **Unified logs:** 94,926 broad-query records cover November 13–17, but only
  **370 application-subsystem records** remain, on November 16 **20:45:08** through
  November 17 **00:05:14**. Build 45 contributes 94,833 process records from
  November 16 **12:11:47** through November 17 **00:10:48**. No query matches
  November 9–12. The detailed 18:21 error and initial reveal are missing; sparse
  system records on earlier days do not establish application health. Thirty-day
  local retention cannot backfill events before history existed.
- **Repeated messages:** 184 native-window errors pair with 184 missing-window
  notices: Handy 111, Macs Fan Control 73. Optional proxy capture swallowed these
  errors and used its fallback; they are not 184 failed layout operations.
  Unchanged build 45 reproduced capture misses beside successful concealment on
  relaunch. The history's 72 incomplete-inventory events are sampled transitions,
  not reveal counts; 322 display events are not 322 failures. No activation,
  selected-return, or expected input-interruption history events occurred in this
  capture. Native interruption tests are separate evidence.
- **Unassigned OS messages and crashes:** build 45 has 12 private invalid-display
  errors. The broad query's other 11 and one LaunchServices-store error belong to
  older processes. No caller or user impact is established from private payloads.
  No TrayNook match was found among 91 crash-directory files, checking filenames
  recursively and report headers. Raw captures stay in the private local
  `/private/tmp/traynook-log-review-20261117` directory; only selected technical
  evidence is recorded in the [receipt](evidence/2026-11-17-log-review-and-build46.json).

The last successful operation was at **17:56:11**. After the terminal failure,
history records suspension at **19:17:43**, resume at **20:14:21**, and complete
inventory at **20:14:25**, with no subsequent operation dispatch. Current code
intentionally does not retry arbitrary native refusals. Relaunching unchanged
build 45 restored concealment; the original terminal trigger remains unproven.

### Confirmed fixes and acceptance

1. **Final concealment recovery:** the existing safety predicate rejected unknown
   boundary overlap with the same permanent error as a protected/unassigned
   hidden-side item. A regression failed with that terminal classification.
   Native concealment now defers only when every blocking item has unknown
   geometry. Fresh inventory and idle input are still required; no unknown
   geometry authorizes concealment. A confirmed unsafe blocker wins in either
   array order. The packaged model check also exercises this final-validation
   error through the actual three-second recovery scheduler. This is a reproduced
   code defect, not proof of the missing historical trigger.
2. **Optional image readback:** capture and native actions share the same pure
   owner/bundle/geometry/uniqueness matcher. An optional miss returns `nil` for
   app-icon fallback without constructing an action-failure log. Actual actions
   retain their refusal errors and onscreen guards. Four focused checks pass.
3. **Retained operation context:** schema-v1 records accept an optional fixed
   operation enum, distinguishing saved layout, placement, ordering, and
   activation. Control placement, unsafe control geometry/concealment, and
   unavailable source windows have fixed reason codes. Legacy-read, roundtrip,
   privacy, retention, and cap checks pass; local history retains its original
   byte prefix. No labels, titles, input contents, or raw error text were added
   to history. No logs were uploaded or system-wide retention changed.

The integrated standard suite passes **291 tests** with host access; its initial
sandbox run blocked the unchanged loopback-server test with `EPERM`. Ten
sequential isolated AppKit runs pass **86 checks**. Both native-menu variants
pass three checks each; boundary passes three cycles. Selected placement passes
two show/hide cycles with **185 sentinel samples, zero reveals**, and all 17
original windows surviving cleanup. Movement stops before input because the
36-point fixture lacks visible space. Cancellation passes seven phases, then
refuses `inventoryUnavailable` before posting any tested return-sequence
down/up/recovery event in the first return-motion phase. Its preceding source
promotion had run before those counters were reset. The remaining phases are unverified; guards were not
weakened to complete them.

Signed development build **1.0.0 (46)** passed packaged smoke and launched at
**November 17 00:25:18 Moscow**, PID 25392. The sampled live UUID
`9EED66E6-C204-31C5-909E-E713FBF70E0B` matches its package. Four native readbacks
three seconds apart observe **seven hidden-source owners, zero visible
hidden-source windows**. Its sampled startup process log has **238 records and
no Error/Fault entries**. Smoke left history unchanged; launch appended a
`savedLayout` start/completion with the original history bytes intact and mode
`0600`. Saved user placements/order survived; existing cleanup removed only the
absent transient Apple audio/video source. `ExtendedLocalDiagnosticHistory`
remains enabled: **30 days/32 MiB** locally, **seven days/1 MiB** public defaults.
Actual sleep/wake, display disconnect/reconnect, and prolonged idle behavior
remain unverified. See the [complete receipt](evidence/2026-11-17-log-review-and-build46.json).

## November 16 review and repair plan

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

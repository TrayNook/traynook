# TrayNook MVP status

Updated 2026-10-28. Last natively verified development build: **1.0.0 (18)**.
Build 19 (hidden pointer, captured proxies, sibling identity, calmer recovery;
see [ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md)
and [HANDOFF.md](HANDOFF.md)) passes the unit suite, smoke test, and harness
compilation but has **not** run the native checks below. Everything after this
paragraph describes build 18 unless marked otherwise.
Locally tested, ad-hoc signed development preview; not a public release.

**Menu opening is about twice as fast in the packaged fixture. Cursor
interference is substantially shorter, but has not been eliminated.** Unrelated
hidden sources remain concealed and the verified native menus stay clear of
the notch.

## Implemented changes

- A normal opening now takes one complete Accessibility inventory, bracketed by
  fresh WindowServer observations. Window identity, process, geometry, visibility,
  and display changes invalidate that observation. Unsettled observations retry;
  nothing is cached across activations.
- After moving the selected source, only its AX identity and geometry are read
  again. All native window bindings must still match, the source window must be
  onscreen, and its AX frame must fit the display's safe status area. The exact
  source and offered action are rebound immediately before delivery.
- Return completion polls the original neighbor and gap instead of scanning
  every app twice again. The pending return clears only after verified geometry.
- The pointer returns immediately after each forwarded down/up, including during
  the retained 50 ms source-processing dwell. The former 150 ms post-up wait is
  gone. A newer pointer position prevents restoration over it; queued down/up
  recheck input before posting. Emergency release uses the current session cursor
  position and the source's bound recovery destination.
- The source action still runs once. An AX timeout can mean the menu is already
  open; observation begins before the action, and uncertain actions are not retried.

The launcher keeps hidden sources hidden. Selection promotes only that source,
opens its genuine menu beside TrayNook, and returns it after observed dismissal.
Explicit Show/Reveal, Settings cancellation, and environment/inventory safety
recovery still intentionally reveal the section.

## Measurements

Host: **macOS 15.7.1 (24G231), Apple silicon, Swift 6.2.3**, notched display.
These are local samples, not a performance guarantee. Timing uses monotonic
system uptime. The independent source-process witness runs on a nominal 120 Hz
common-mode timer; WindowServer calls and scheduling reduce its actual sampling
rate, so it cannot prove absence of shorter excursions.

### Packaged production path

| Measurement | Build 17 baseline, this session | Final build 18 |
| --- | --- | --- |
| Proxy AXPress → native menu-open | 1,273 ms | **638 / 603 ms** |
| Menu-close → observed source concealed | 849 ms | **644 ms** |
| Displaced pointer samples, first activation including return | 29 / 412 | **4 / 372** |
| Displaced pointer samples, repeated opening | Not recorded | **2 / 55** |
| Longest sampled pointer excursion | Duration not recorded | **25 ms** for each activation |
| Maximum cursor displacement | 1,290 pt | **1,278 pt** |

The 638/603 ms openings are 50–53% faster than the measured baseline. Concealment
is observed with 150 ms harness polling; this is not the same as controller
completion. The excursion's **distance remains large** even though its duration
is much shorter. Both activations opened exactly one menu; the independent peer
witness saw no reveal or missing observation. Source and menu geometry passed.

### Where the time went

Temporary method probes profiled the baseline and the final interaction strategy;
all probes were removed before packaging build 18. Nested rows overlap and must
not be added together. Two candidate openings supplied ranges below.

| Stage | Baseline | Optimized profile |
| --- | --- | --- |
| Input readiness while idle | 0 ms | 0 ms |
| Initial stability check | 384 ms, two scans | 185–202 ms, one scan |
| Individual opening-path full scans | 133 / 90 / 67 / 105 ms | 118 / 132 ms, one per opening |
| Targeted movement, including event creation/routing | 329 ms | 150–161 ms |
| Individual down/up relay | 27 / 27 ms | 14–32 ms |
| Post-move full stability check | 331 ms | Removed; bound source AX/window checks |
| Total preparation | 1,148 ms | 486–536 ms |
| AX action call until response/timeout | 201 ms | 201 ms |
| Controller return after dismissal | 1,020 ms | 389 ms |

The AX call's timeout includes time **after the menu is visible**. Shortening that
timeout would not remove the main measured preparation cost, and delivery must
remain exactly once.

## Verified checks

| Check | Build 18 result |
| --- | --- |
| Unit suite | 57 active tests passed across 11 suites; one opt-in renderer test skipped |
| Invalid saved control positions | Automatic recovery and concealment passed |
| Launcher close/reopen twice; dropdown polling for 7 seconds | Hidden sources and control geometry retained |
| Two proxy activations | One native action each, safe source/menu geometry, peers hidden |
| Return after native dismissal | Concealment retained through the next inventory poll |
| Settings during active menu | Cancelled the operation; editing enabled; no late re-hide |
| Cancellation before down, after down, after up | Correct paired input; no duplicate release or source action |
| Motion while down/up queued and after delivery; motion during return | Nine total cancellation/motion cases passed; new pointer position retained and source order recovered |
| Strict zero-pointer acceptance | **Failed as expected:** 4 / 360 displaced samples, 17 ms longest sampled excursion; menu/peer/return checks passed |
| No safe slot | Oversized source rejected before posting input; no pending return; sentinel still offscreen |
| Native menu observer | Open/close, no-menu timeout, and cancellation passed |
| Packaged smoke | Plist, resources, strict ad-hoc signature, launcher, and Settings passed |
| Isolated cleanup | Saved layout unchanged byte-for-byte; all 17 comparable source windows retained order; fixtures removed |

Pointer-race tests inject deterministic cursor-position changes. They are not
proof of uninterrupted real hardware motion. The ordinary UI regression enforces
return to the original pointer and a sampled excursion below 150 ms. Its separate
`--require-still-pointer` mode enforces zero displaced samples and remains a
release acceptance criterion, not a claim that this build is cursor-free.

## Real source menus on the final executable

The runner-launched final binary was tested using synthetic mouse clicks on
observed launcher/proxy frames. Timing includes click-delivery overhead. Each
successful row verified a native menu, the selected source right of the notch,
menu bounds inside the display without notch intersection, hidden peers, return,
and concealment through another poll. Menus were dismissed without choosing commands.

| Source | Build 17 previous-session sample | Build 18 this session | Result |
| --- | --- | --- | --- |
| DockDoor | 1,350 ms | 895 / 806 ms | Passed; the repeat includes the explicit notch-intersection assertion |
| MonitorControl | 1,890 ms | 658 ms | Passed |
| ChatGPT | 1,360 ms | 827 / 766 ms | First menu/return passed, but next inventory poll revealed the section; repeat passed through the poll |
| Macs Fan Control | 1,400 ms | 799 ms | Passed |
| Handy | 1,460 ms | 796 ms | Passed |

**The initial ChatGPT result is not counted as a full pass.** TrayNook reported
“Menu-bar items changed. Review the layout before hiding again.” The source had
already returned correctly; inventory safety recovery then revealed the section.
After explicitly reapplying the existing placements, the repeat passed. The exact
changed window/source was not captured in the failing sample, so the cause remains
unresolved. This needs a reproducible inventory trace before changing recovery rules.

Some initial probe attempts found no proxy after a launcher click or lacked a
usable AX frame; they sent no source action. Keeping each complete mouse-driven
check in one uninterrupted interval produced the successful results above.

Finder launch of the rebuilt ad-hoc app showed **Accessibility: Not granted**.
The same executable inherited the authorized development runner's access and
completed the real-menu tests. It is left running that way with saved placements
concealed. Normal Finder launch needs renewed Accessibility approval; no permission
database was edited and no new approval was silently granted.

## Experiments rejected

All experiments used disposable sources and retained the source-binding and safe
geometry checks. No source command was chosen.

| Attempt | Observed result |
| --- | --- |
| Session event at current cursor, original targeted event to PID | Relay delivered; WindowServer did not promote the source. No action sent; peer stayed hidden. |
| Delivery at annotated session tap | Cursor stayed in place; the complete down/up pair did not promote the source. No action sent. |
| Tagged null event substituted at session tap | Session relay timed out; source remained hidden and no action was sent. |
| Remove down-processing dwell entirely | Faster samples, but one missed reorder in repeated cancellation testing. Reverted. |
| Return cursor during retained down dwell | Packaged opening/return passed; profiled excursions fell to 16–25 ms. Retained and revalidated in final package. |

Apple documents [event routing](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:))
and [tap insertion](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent(_:));
those APIs do not promise pointer-free status-item reordering. The findings above
are local observations, not a universal macOS capability claim. Disconnecting the
mouse through [CGAssociateMouseAndMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition(_:))
would change physical pointer behavior and was not adopted.

## Remaining limits and release blockers

1. **Cursor-free interaction is unresolved.** Brief large jumps still occur on
   the working public event route. Build 19 hides the pointer for the duration
   of the move (unverified on device) and waits at most one second for released
   buttons and keys instead of ten; the 200 ms quiet-input interval remains.
   The strict `--require-still-pointer` check measures displacement and will
   keep failing; it is no longer a release criterion.
   A successful menu-open check does not establish native-feeling interaction.
2. **Intermittent inventory recovery remains.** One ChatGPT run returned its
   source and then revealed peers on the next poll with an inventory-change
   message. Build 19 no longer reveals on window-ID churn or a restarted hidden
   source; whether that removes this case is unverified.
3. **Custom panels and secondary actions need broader acceptance.** NSMenu
   lifecycle is covered. A panel without those events can leave the selected
   source visible until the next launcher click. Unknown status-level windows
   can still trigger conservative global recovery.
4. **One source needs a safe slot.** A full visible section produces an error;
   there is no reveal-all fallback during normal interaction.
5. **Other environments remain unverified:** other macOS versions, Intel,
   multiple displays, Spaces/fullscreen, auto-hidden menu bars, and sleep/wake.
   The 50 ms down dwell needs validation on each supported configuration.
6. **Management remains conservative.** Apple/system and indistinguishable
   multi-item sources stay protected; build 19 manages siblings it can tell
   apart. Proxies are last-seen captures with Screen Recording and app icons
   without it; neither path is natively verified on build 19. Own-control positioning still uses undocumented AppKit preference
   keys; no private API or source-application preference writes were added.
7. **Local launch approval and distribution remain pending:** renewed
   Accessibility approval for normal Finder launch; Developer ID signing, notarization, public
   identity/destination, and a supported-environment acceptance matrix.

Release-policy update, 9 November 2026: the environment observations above remain
historical measurements. The full OS/hardware acceptance matrix is no longer a
launch gate. The target is stable macOS majors receiving current Apple security
updates; older installations are allowed down to the technical minimum of 13.0
without guarantees. Compatibility is best effort, and release notes record only
actual test coverage. Developer ID and notarization are also now optional: the
default public release uses free ad-hoc signing, while update signing remains
required. See [ADR 0002](adr/0002-support-current-stable-macos-releases.md) and
[the updated distribution decision](adr/0004-sign-releases-with-maintainer-developer-id.md).

Historical build observation: disk availability was 28 GiB at the start, so the
previous disk-space blocker did not prevent this build. That build added no
network client, analytics, helper daemon, third-party dependency, or updater.
The current target includes signed updates through Sparkle; see
[Networking and updates](DECISIONS.md#networking-and-updates). No login registration or permission database
was changed. Finder launch of this ad-hoc rebuild needs renewed Accessibility approval.

Executable: `dist/TrayNook Dev.app/Contents/MacOS/TrayNook`.
SHA-256: `15a8a89d190bfae23d7318c4a99bbca2ad4def36022593dedd2bc163e965106a`.

## Repeat the checks

Quit the normal TrayNook instance before GUI tests; one process owns the desktop.
Leave input idle. Tests copy placements read-only into an isolated app identity.

```sh
Scripts/test.sh
TRAYNOOK_BUILD=18 Scripts/build-app.sh
Scripts/test-dropdown-ui.sh --invalid-positions --layout "$HOME/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json" "dist/TrayNook Dev.app"
Scripts/test-native-cancellation.sh
Scripts/test-native-menu.sh
Scripts/smoke-test.sh
# Strict release criterion; brief pointer excursions remain a known failure:
Scripts/test-dropdown-ui.sh --require-still-pointer --layout "$HOME/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json" "dist/TrayNook Dev.app"
```

The cancellation harness instruments a temporary controller copy; production has
no test hooks. The unchanged preview renderer was verified in build 16; it was
not rerun for this controller-only change. The two-source regression still covers
build 14's reveal-all regression in addition to the pointer checks added here.

## Source comparisons

Hidden Bar's [separator-width engine](https://github.com/dwarvesf/hidden/blob/c801f8af2eb3a61e836e42715122f05b44fd0a83/hidden/Features/StatusBar/Engine/LegacyLengthEngine.swift)
confirmed the concealment mechanism already used by TrayNook. Revealing that
whole section does not solve overflow beside a notch.

Ice's [individual-item promotion and return flow](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift#L1259)
was examined as a conceptual reference. TrayNook's implementation uses public
NSEvent/CGEvent and Accessibility APIs and does not copy Ice's private-field or
private-API implementation. No source code was copied from either project.

# Decision record

Status: updated throughout the product review. Recorded decisions are normative for the design and do not authorize implementation yet.

## Resolved product decisions

### Three Placements

Every Managed Item is assigned to **Menu Bar Zone**, **Dropdown Zone**, or **Always Hidden Zone**. Always Hidden items appear in neither everyday access surface—the Menu Bar nor Dropdown—and receive no Proxy Item, but remain manageable in Settings. The TrayNook Launcher is permanently assigned to Menu Bar Zone but may be reordered anywhere within it.

### Layout organization and dragging

Settings contains three ordered Placement Lanes, with drag within a lane to reorder and across lanes to change Placement. Users can also reorder items in the physical menu bar and open Dropdown, including TrayNook's Launcher within Menu Bar. TrayNook must exhaust reasonable approaches to direct dragging from physical menu bar to Dropdown and back; if it remains unreliable, the accepted 1.0.0 fallback is Settings-lane dragging for cross-placement moves. Always Hidden is edited through Settings because it has no direct surface.

Primary click and secondary click activate Proxy Items. Drag is for layout manipulation, not forwarding an app-specific drag gesture. Proxy-level modifier clicks, scrolling, pressure, and long press are not required. Once the source application's native interface opens, interaction inside it remains native.

In 1.0.0, Placement and reordering require mouse or trackpad dragging. Keyboard and context-menu **Move to… / Move Earlier / Move Later** actions are deferred to 1.1.0. Version 1.0.0 still provides labels, focus, keyboard activation for ordinary controls, increased contrast, and Reduce Motion, but does not claim complete keyboard-only or VoiceOver layout editing.

A confidently detected user Command-drag within the physical Menu Bar is authoritative and immediately updates Desired Layout, including the Launcher's valid order. A deliberate valid crossing between Menu Bar and Dropdown also changes Placement immediately; invalid destinations for the Launcher or a Protected Item are rejected. TrayNook does not restore the previous Settings order. Ambiguous system- or source-app-driven reshuffles do not silently change Placement. See [ADR 0006](adr/0006-explicit-user-drag-updates-desired-layout.md).

The Launcher cannot be removed while TrayNook is running. If the user Command-drags it completely off the Menu Bar, TrayNook restores it automatically to the nearest valid position consistent with the user's Menu Bar order. Quit is the supported way to stop TrayNook.

Settings edits apply immediately with no Save or Apply button. Every in-process user-authored layout or identity mutation shares one Undo history: Settings and Dropdown drags, confidently detected physical Command-drags, ambiguity resolution, Leave Unmanaged, Forget Item, and Restore All. Undo/Redo is available through both `⌘Z` / `⇧⌘Z` and enabled **Edit → Undo/Redo** menu commands while Settings is active. Automatic reconciliation, launch-time offline-order adoption, Quit, Reset Layout, Reset TrayNook, and Erase Data and Quit are not Undoable.

Undo history belongs to the running TrayNook session: it survives closing and reopening Settings, resets on process termination or relaunch, and is never persisted to disk. Desired Layout itself persists after every accepted change.

Manual **Restore All Items to Menu Bar** applies immediately without confirmation and registers as one grouped Undo action. It keeps current Menu Bar identities first, then appends Dropdown identities, then Always Hidden identities, preserving each lane's semantic order. It changes every saved identity—including Not Running and App Missing—to Menu Bar so nothing later returns concealed. Automatic restoration during Quit uses the same physical merge for running items but preserves Desired Layout and is not undoable because the process is terminating.

### Dropdown Row Capacity

Row Capacity uses a whole-number slider from **1–30**, recommends **5–20**, and defaults to **10**. The fixed gear-icon Settings Button consumes one first-row slot, leaving room for at most nine Proxy Items at the default. Capacity is a logical maximum: TrayNook wraps earlier when physical display width requires it and never shrinks controls to force the configured count. The slider neutrally highlights the recommended band and shows **Short rows**, **Recommended**, or **Long rows** below it. Every value remains valid, with no warning colors or confirmation.

The Dropdown is capped to the active display's usable height. If its rows exceed that height, they remain in one continuous order inside a standard vertical scroll container; TrayNook does not impose an item or row limit. The gear is fixed only in order: it occupies the first slot and scrolls naturally with the first row rather than remaining sticky.

For pointer and keyboard opening alike, TrayNook activates and waits until active before showing the Dropdown. The visible Dropdown must own keyboard input; if it cannot become key, it closes safely. It consumes physical Escape key-down, repeats, and key-up locally, then closes on key-up so Escape cannot reach the previous application. It uses no global keyboard tap or synthesized foreign key events. Keyboard or VoiceOver opening places focus on the first control, the gear; pointer opening does not automatically focus it. Passive Escape or Launcher-toggle dismissal restores the previously active application and focus when macOS permits. Intentional focus transfers win: an outside click leaves focus with its target, Open Settings leaves Settings active, and a source action opening an ordinary window leaves its app active. This contract is checked in the recorded test environments rather than assumed from one AppKit panel configuration.

An outside click dismisses the Dropdown and still reaches its intended application or control. TrayNook observes that event non-destructively; it neither consumes the click nor replays a synthetic duplicate, so dismissal never requires a second click.

### Permissions and fidelity

Accessibility is the blocking operational permission for discovery, placement, and native handoff. Screen Recording is the preferred-fidelity permission for captured Proxy imagery, with an accepted app-icon fallback. TrayNook may request another relevant macOS privacy permission only if the prototype proves it necessary for a committed feature and onboarding explains why. Permission denial or revocation falls back safely and visibly; TrayNook never bypasses macOS privacy controls or SIP.

If Accessibility is unavailable, TrayNook stops movement and native handoff, removes active concealment, and leaves all real items in Menu Bar while keeping Launcher and Settings available. If Screen Recording alone is unavailable, placement and handoff continue through Accessibility while proxies use only the source app icon plus tooltip and VoiceOver identity. Full behavior resumes only after permission restoration and successful reconciliation.

While Accessibility is unavailable, primary-clicking the Launcher opens and focuses the Permissions tab instead of showing a nonfunctional Dropdown. Screen Recording loss alone does not change Launcher behavior; the normal Dropdown opens with fallback proxies.

Settings is one window with three real tabs: **Layout**, **Permissions**, and **General**. Layout is the normal default. Permissions shows each permission's current state, carries an attention badge for blocking or degraded permission state, and provides an action that opens the closest relevant macOS System Settings privacy pane. TrayNook refreshes status when Settings becomes active again and never claims a grant before the system reports it.

First launch opens Permissions, guides Accessibility and then Screen Recording one at a time, reconciles after grants, switches to Layout, and recommends Launch at Login once. Subsequent explicit launches normally open Layout. Missing Accessibility or incomplete required reconciliation opens Permissions; previously declined Screen Recording remains a degraded-fidelity badge and retry action without redirecting later launches.

Declining Screen Recording does not block onboarding. TrayNook continues into Layout with fallback proxies, stops automatic prompting, and leaves a Permissions badge plus explicit retry and System Settings actions.

Declining Accessibility leaves TrayNook in safe inactive mode and stops automatic prompting. Settings remains on Permissions, Launcher primary-click returns there, and Layout management begins only after an explicit retry or System Settings grant followed by successful reconciliation.

### Protected Items

TrayNook ships with an explicit Protected exception. If macOS prevents an item from being moved or activated reliably even with the required permissions, Settings marks it as Protected with a concise reason and keeps it in Menu Bar Zone. Capture failure alone uses the app-icon fallback and does not make an otherwise manageable item Protected. Protected Items do not block 1.0.0 or prevent manageable items from working.

### Ambiguous Items

If TrayNook cannot confidently match a Source Item to saved identity—when one app creates indistinguishable items without AXIdentifiers or status-window identity ([ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md))—it keeps the item visible in Menu Bar, marks it Ambiguous in Settings, and does not guess its previous Placement. **Resolve Ambiguous Item** offers three explicit choices: **Match to Saved Item…** lists only compatible retained identities and applies the user's authoritative mapping; **Treat as New Menu Bar Item** creates a fresh identity without deleting retained identities; and **Leave Unmanaged** persists an acknowledged Unmanaged state. Unmanaged keeps the item visible and outside automatic placement, clears its attention indicator, retains Resolve for later, and alerts again only after a materially new identity conflict. **Forget Item** remains available separately on stale saved identities. The UI states that TrayNook cannot independently verify visually identical instances and never presents a user-selected mapping as automatic recognition.

### Attention states

TrayNook does not request notification permission or send Notification Center alerts in 1.0.0. Ambiguous Items, permission loss, and Placement Mismatches use a subtle Launcher attention indicator, a concise Settings banner, and fail-visible affected items. The indicator clears when all attention states are resolved. An ordinary new item creates no alert because it already appears in Menu Bar.

A transient placement failure retains the user's requested Placement in Desired Layout while keeping the real item visible in Menu Bar and marking a Placement Mismatch. TrayNook retries only after explicit user action or a meaningful permission, capability, source-app, display, or geometry change, never in a continuous failure loop. A destination proven permanently unsupported makes the item Protected; that placement is rejected and its prior valid Desired Placement remains unchanged.

Settings Placement Lanes always display Desired Layout. A mismatched item remains in its intended lane with **Currently in Menu Bar** and **Retry Placement** instead of appearing to have changed Placement. When Accessibility is unavailable, the saved lanes remain visible but layout editing is read-only; Permissions and General remain usable.

### Private macOS APIs

TrayNook may use narrowly isolated private CGS/SkyLight APIs only after public and tested deprecated-public approaches are proven insufficient for a committed capability. Every such path is capability-gated and checked in the recorded test environments. An unavailable, unknown, or failing private path disables or degrades only the affected feature and keeps items visible; it must never crash the app or bypass SIP or privacy controls. See [ADR 0001](adr/0001-isolate-and-gate-private-macos-apis.md).

### Native-interaction continuity

TrayNook first attempts to keep the Dropdown visible while another application's native menu, popover, or window is active. If that fails, the prototype explores continuity-preserving workarounds. If none is reliable in the tested environments, the accepted fallback is to hide the Dropdown temporarily. A selected source command or a source menu/popover that closes itself may resume it unless the action opens/raises an ordinary window or intentionally transfers focus to the source app; that rule wins and leaves Dropdown closed. Escape, an outside click, Launcher toggle, Open Settings, Restore, or Quit explicitly ends the Dropdown session and suppresses reopening.

Foreign Source Items are never embedded in Dropdown. Activating a Proxy Item temporarily promotes the real item and lets its source application present the genuine interface. That interface anchors to the real temporary Menu Bar position, placed near the Launcher when macOS permits, not necessarily beneath the clicked proxy. This location trade-off is accepted in exchange for native behavior. See [ADR 0007](adr/0007-use-proxies-and-native-interaction-handoff.md).

Transient menus and popovers keep the Source Item promoted until dismissal. Opening or raising a normal app window, toggling state, launching an app, or producing no interface completes handoff after a short measured grace period, restores Desired Layout, and leaves the Dropdown closed. TrayNook never waits for a long-lived ordinary window to close. The exact grace period is a measured tuning constant rather than a product preference.

Only one Interaction Handoff is active at a time. Selecting another Proxy Item while a source interface is active makes that item the sole latest request; after the current native interface dismisses, TrayNook activates the latest request. It never maintains concurrent foreign promotions or a multi-click queue.

A confidently detected user Command-drag of the temporarily promoted Source Item is authoritative. TrayNook ends handoff, immediately adopts the resulting valid Placement and order, and does not restore the pre-handoff layout over that explicit action. Invalid Launcher or Protected destinations remain rejected.

Open Settings, Restore, Reset TrayNook, Erase Data and Quit, and Quit take precedence over handoff. Each clears pending Proxy activation, ends the Dropdown session, safely finishes and reconciles the current promotion, then performs the command under bounded fail-visible recovery rules. No lifecycle or recovery command may leave an item temporarily promoted or wait indefinitely for a foreign interface.

### Proxy refresh and tuning values

TrayNook captures Proxy Items whenever their Source Items are onscreen and refreshes visible proxies at most once per second while the Dropdown is open. Hidden items show their last-seen capture for the session ([ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md)); captures are purged on permission loss or when an item leaves the Dropdown. TrayNook does not promise frame-perfect animation. Refresh intervals, handoff timeouts, reconciliation cadence, and similar policy values live in one documented set of named tuning constants so they can be adjusted without hunting through the code.

Captured Proxy Items preserve the Source Item's native visual width and appearance and show no permanent text label. A standard hover tooltip and VoiceOver label expose the accessible item or application name.

When capture is unavailable, the fallback Proxy Item shows only the source application icon with the same tooltip and VoiceOver identity. It has no permanent text label. Candidates that cannot be distinguished safely remain Ambiguous in Menu Bar.

### Application lifecycle

TrayNook remains Dockless at all times. Spotlight, Finder, Launchpad, the Dropdown gear, and the Launcher's secondary-click command create or focus one singleton Settings window. Raising an existing window preserves its selected tab; Layout/blocking-Permissions routing occurs only when creating the window, continuing onboarding, or following an explicitly targeted action. Closing Settings leaves TrayNook running.

Launch at Login is included in 1.0.0 and defaults to off. Onboarding explicitly recommends enabling it once and asks for consent; declining or dismissing the recommendation does not cause repeated prompts.

Normal Quit returns all manageable Dropdown and Always Hidden items to native Menu Bar layout using the deterministic Menu Bar → Dropdown → Always Hidden merge and removes TrayNook's own status items and boundaries. Permission-loss recovery, Reset TrayNook, Prepare for Uninstall, and Erase Data and Quit use the same physical merge. Quit may terminate once every running item TrayNook managed has been returned to native layout and no TrayNook-created concealment remains, even when exact ordering is imperfect. If TrayNook-created concealment remains, it cancels Quit and presents recovery rather than terminating. After successful Quit, TrayNook exerts no active control or concealment: macOS lays out the real items exactly as it would if TrayNook were not installed, including ordinary notch clipping when the native bar itself is overcrowded. Native notch clipping does not count as TrayNook concealment. Desired Layout and the Launch at Login preference remain saved, and the layout is reconciled and reapplied on the next launch.

Quit acts immediately without confirmation. It is safe because restoration happens first and no Desired Layout or Launch at Login preference is discarded.

The following broader lifecycle flows are target designs, not implemented commands. The current app offers Reset Layout, which preserves updater preferences and cached downloads; uninstall instructions therefore require turning off Launch at Login and quitting manually.

Target General includes **Prepare for Uninstall**. It first presents manual and Homebrew removal instructions, then offers **Restore, Disable Login, and Quit**. That action uses the same native-layout threshold as Quit: it terminates only after every running item TrayNook managed has been returned to native layout and no TrayNook-created concealment remains; exact order is best-effort and native notch clipping is outside TrayNook's control. It unregisters Launch at Login, removes TrayNook's active controls, and quits, but does not delete the application itself.

The removal instructions also include an optional final cleanup step for manually removing TrayNook from Accessibility and Screen Recording in System Settings. This is informational rather than a warning, confirmation, or prerequisite: macOS owns those grants and TrayNook cannot revoke them itself.

Prepare for Uninstall's ordinary **Restore, Disable Login, and Quit** path and ordinary Homebrew uninstall preserve Desired Layout and preferences so a reinstall can restore them. Durable local removal is explicit through **Erase Data and Quit** or Homebrew `zap`.

**Reset TrayNook** is a confirmed factory reset: return all managed items to native Menu Bar layout using the same mandatory-native-layout/best-effort-order threshold, disable Launch at Login, clear Desired Layout, onboarding state, preferences, saved identities, and Undo history, then remain running on first-launch Permissions. It does not reset state if TrayNook-created concealment cannot first be removed. Permissions displays any authorization that macOS still reports as Granted and never requests it again unnecessarily. The user chooses **Continue** before reconciliation and layout management resume; Layout then opens and the deliberately reset one-time Launch at Login recommendation appears again. Because the app remains running and may create fresh identity data as use resumes, the action is not called Erase. It cannot revoke Accessibility or Screen Recording grants; macOS owns those settings.

**Erase Data and Quit**, available from the uninstall flow after confirmation, uses the same native-layout-first threshold, disables Launch at Login, clears all TrayNook-owned local state, removes TrayNook controls, and terminates. It leaves no TrayNook-owned local data until the app runs again and does not delete the application bundle itself.

TrayNook advertises `brew uninstall --cask --zap traynook/tap/traynook` as a self-contained removal path only after integration testing proves that it safely stops TrayNook, restores native layout, unregisters Launch at Login, removes the application, and deletes TrayNook-owned local data. If the cask lifecycle cannot perform equivalent supported cleanup, documentation requires **Erase Data and Quit** before the Homebrew command. The cask `zap` stanza describes data cleanup; the full `brew uninstall --zap` command also removes the app. Neither path revokes macOS-managed privacy grants.

After a crash or force-kill, TrayNook cannot run exact restoration. Its own boundaries disappear with the process so active concealment ends, but macOS may retain the last managed ordering of real items. The next launch reconciles Observed Layout before concealing anything, leaves ambiguous items visible, and then reapplies Desired Layout.

After a clean Quit, TrayNook records the final native Menu Bar order only when that order was observed confidently. If the next launch observes a different order, it treats that delta as offline user intent: adopt the new relative order, retain known Placements, assign new items to Menu Bar, and then reapply. This inference is not used after a crash or an uncertain Quit. See [ADR 0006](adr/0006-explicit-user-drag-updates-desired-layout.md).

### Defaults and displays

Every newly discovered or ambiguous Source Item defaults to Menu Bar Zone. A new item keeps its observed relative position when TrayNook can determine that order confidently; otherwise it appends after existing Menu Bar items in semantic lane order without reshuffling known items. The user can rearrange it later.

One global Desired Layout applies to every display. The Dropdown opens on the display containing the clicked Launcher and adapts its wrapping and bounds to that display. Per-display layouts remain out of scope.

Layout shows a non-blocking warning when Menu Bar items are unlikely to fit the active display's safe region because of a notch or screen edge. It suggests moving items to Dropdown but never rejects the arrangement. Text and an accessible warning symbol carry the meaning; color alone does not.

### Compatibility policy

TrayNook targets all stable macOS major versions receiving current Apple security updates, as identified by [Apple security releases](https://support.apple.com/en-us/100100) at release time, and ships Universal 2 binaries for Intel and Apple silicon. Its technical minimum is macOS 13.0; older systems outside the support target may install and run without compatibility guarantees. Compatibility is best effort. Every public prerelease and stable release lists the exact OS builds, architectures, hardware, display configurations, results, and known limitations actually tested. The minimum OS and Universal 2 packaging do not certify untested systems. See [ADR 0002](adr/0002-support-current-stable-macos-releases.md).

The former full maintained-macOS acceptance matrix is no longer a release gate. Untested OS/hardware combinations do not block 1.0.0; compatibility bugs are investigated from user reports. Beta macOS versions may be tested opportunistically but carry no compatibility guarantee.

Checks on available environments cover discovery, all three Settings Placement Lanes, usable proxies with an app-icon fallback, primary and secondary native handoff, and safe restoration. Runtime capability checks and visible recovery remain required.

### Product name

**TrayNook** is selected, pending final trademark, repository, App Store, GitHub, Homebrew, bundle-identifier, and signing-identity clearance.

The canonical GitHub organization is **TrayNook**, and the intended repository is `github.com/TrayNook/traynook`. This records the release identity but does not claim that the repository name or trademark has been reserved or legally cleared yet.

The permanent public bundle identifier is **`io.github.mahenzon.TrayNook`**. Public preview and stable builds that users authorize use this same identifier to keep one installation/data lane and consistent Launch at Login identity. Ad-hoc signature changes can still require renewed macOS privacy approval after updates. Local development instead uses `io.github.mahenzon.TrayNook.dev`. See [ADR 0008](adr/0008-lock-the-release-identity.md).

The Menu Bar Launcher uses a simple monochrome template mark: an open tray or pocket containing three dots. It adapts to light/dark Menu Bar appearance and contains no text. The Finder/Settings app icon later reuses the same mark with color. Attention state adds an accessible badge/label rather than relying on color alone.

### Open-source license

TrayNook is copyright © 2026 Suren Khorenyan and licensed under MIT. Redistributions and substantial copies must retain its copyright and permission notice; the packaged app includes the complete `LICENSE` in `Contents/Resources/LICENSE`, but no permanent in-app attribution is required. GPL implementation code is not copied into the project. See [ADR 0003](adr/0003-license-traynook-under-mit.md).

### Prerelease versioning

Before stable 1.0.0, GitHub prereleases use `v1.0.0-alpha.N`, then `v1.0.0-beta.N`, then `v1.0.0-rc.N`. The macOS marketing version remains `1.0.0`, every artifact receives a monotonically increasing numeric build number, and the stable Homebrew cask begins with final `v1.0.0`. Public prereleases and stable releases default to free ad-hoc signing and use the same permanent bundle identifier; previews and stable are one installation/data lane and do not install side by side. Optional notarized releases use the explicitly configured Developer ID identity.

All public release notes enumerate the exact environments tested and known limitations under the best-effort compatibility policy. Full maintained-version coverage is not required for release candidates or stable 1.0.0. Unverified private behavior still fails visible rather than being invoked.

Local development builds use display name **TrayNook Dev**, bundle identifier `io.github.mahenzon.TrayNook.dev`, and separate preferences and privacy grants. Pull-request CI may remain unsigned but never publishes a downloadable `.app`. Only trusted signed tags create user-installable artifacts.

Every public prerelease supports an in-place forward upgrade to each later public prerelease and stable 1.0.0 while preserving Desired Layout and settings through versioned migration. Downgrades are unsupported. If a build encounters stored state that it cannot safely read, it returns managed Source Items to native Menu Bar layout, removes TrayNook-created concealment, and shows a recovery banner instead of guessing, partially applying, or silently discarding the state. The unreadable data remains available for diagnosis until the user explicitly chooses **Reset Layout**. One concise confirmation, with no typed phrase, explains that saved item identities, Placements, and order will be deleted and cannot be undone; privacy grants, Launch at Login, and unrelated preferences remain unchanged.

### Signing identity

Public prereleases and stable releases use `TRAYNOOK_DISTRIBUTION=adhoc` by default, requiring no paid Apple membership. `TRAYNOOK_DISTRIBUTION=notarized` explicitly enables the optional Developer ID and notarization path. The app records the actual mode as `TrayNookDistribution`. Both modes verify app integrity and use independent Ed25519 update keys, GitHub-verified signed release tags, protected release secrets, and manual draft review. Apple secrets are needed only in notarized mode; no credentials are committed. Ad-hoc releases may require manual macOS Open Anyway approval and renewed Accessibility permission after updates. Changing the Apple signing team or distribution mode requires migration verification. See [ADR 0004](adr/0004-sign-releases-with-maintainer-developer-id.md).

The public author identity used in About, the MIT notice, and repository metadata is **Suren Khorenyan**. It does not expose Apple certificate identifiers or credentials.

### Homebrew distribution

TrayNook initially ships through `github.com/TrayNook/homebrew-tap` using the cask token `traynook`. Users install it with `brew install --cask traynook/tap/traynook`. Submission to the official Homebrew Cask repository happens only after stable releases meet its acceptance requirements and does not block 1.0.0. The planned tap identity is locked, but this document does not claim that the repository has already been created.

Each direct release contains one `TrayNook.app` ZIP and its SHA-256 checksum, ad-hoc signed by default or optionally Developer ID signed and notarized. A stable release also publishes `appcast.xml` with an Ed25519 signature for that final ZIP. The Homebrew cask consumes that exact ZIP. Version 1.0.0 does not publish a DMG or installer package.

### Networking and updates

General and the Launcher context menu include **Check for Updates…**. General shows the changelog, **Check automatically** (default on: launch and daily), and the separate **Automatically download updates** preference (default off). Background checks and optional archive downloads use a pinned GitHub HTTPS appcast. Downloaded release archives remain in a local cache; Ed25519 payload signatures are verified against the embedded public key. Sparkle 2.10 provides the trusted installer, which starts only after explicit **Install & Relaunch** approval. TrayNook then exposes the cached, verified archive through a temporary local loopback feed and proceeds with that approved installation and relaunch without a second Sparkle confirmation. macOS authorization may still be required. Background discovery and downloading never start Sparkle. Before explicit approval, ordinary Quit or crash cannot install a downloaded update.

Preferences and Desired Layout remain local. Update requests reveal the usual network metadata, IP address, and app update request to GitHub; TrayNook sends no analytics, crash uploads, system profile, application inventory, screenshots, or saved layout. Turning off **Check automatically** stops background update checks and downloads; manual checks remain available. Turning off **Automatically download updates** prevents future automatic archive downloads while allowing checks. Development, smoke-test, and diagnose modes never start automatic network or production-update activity. User-clicked source, release, and issue links open the browser deliberately. Manual GitHub and Homebrew upgrades remain available. See [Releasing](RELEASING.md) for the appcast and key setup.

General includes **Copy Diagnostics**. Before copying, the UI explains that the local support summary includes TrayNook version/build, macOS version, permission and recovery state, failure details, and bundle identifiers for affected applications or pending placement/return/repair work. These identifiers can reveal which affected applications are installed or running. It excludes captured pixels, item/window titles, a complete application inventory, Desired Layout, saved item identities, and interaction history. Copying requires explicit user action, and TrayNook never uploads the summary automatically; the user's system clipboard or Universal Clipboard may sync copied text under the user's macOS/iCloud settings.

General also includes **Report a Problem…**. It opens `https://github.com/TrayNook/traynook/issues/new` in the user's browser only after an explicit click. GitHub Issues must be enabled for the source repository. It never attaches diagnostics or prepopulates private state; the user reviews and pastes any copied diagnostics deliberately.

### Persisted data

The updater stores its preferences and disposable downloaded release archives locally. The implemented Reset Layout preserves both; the current app has no full-data erase command. Layout management persists only the minimum local state required to operate: source bundle identity, a non-content stable discriminator where needed, Placement, order, explicit preferences such as Row Capacity and Launch at Login consent, onboarding acknowledgements, state-schema version, and the clean-Quit baseline. It never persists dynamic Accessibility titles or labels, geometry, process/window IDs, hashes of content-bearing strings, captured pixels, menu or popover contents, interaction history, usage frequency, or analytics identifiers. The discriminators are an identifier-shaped AXIdentifier or a status-window creation rank ([ADR 0009](adr/0009-hidden-pointer-sibling-keys-and-session-image-cache.md)); when neither is available, the item becomes Ambiguous rather than expanding the persisted privacy footprint.

If a configured Source Item is absent, its saved Placement and order remain indefinitely so they can be restored if it returns. TrayNook never expires that state automatically. Settings provides an explicit **Forget Item** action.

Forget Item is available only for Not Running, App Missing, or unresolved saved identities. It removes saved identity, Placement, and order. A later reappearance is treated as a new Menu Bar item. Running items cannot be forgotten because discovery would immediately add them again.

Settings distinguishes **Running** with a normal icon, **Not Running** with a desaturated icon and label, **App Missing** with stronger dimming plus a missing badge and “App not found,” **Protected** with a lock and explanation, **Ambiguous** with a question badge and resolution action, and acknowledged **Unmanaged** with a neutral label plus a later Resolve action. Filters and colors only reinforce state; text, badges, and accessible labels carry the meaning.

The everyday Dropdown contains only Running Proxy Items. Not Running and App Missing placeholders remain in Settings to preserve saved order but consume no Dropdown slot. When a Source Item returns, its Proxy Item appears automatically at its saved position.

### Localization and RTL

TrayNook 1.0.0 bundles US English only. All user-facing text uses localization resources, and UI structure supports text expansion, bidirectional content, and right-to-left mirroring from the beginning. Pseudolocalization and RTL pseudolanguage checks are part of release testing. Community instructions live in [`TRANSLATING.md`](../TRANSLATING.md). See [ADR 0005](adr/0005-design-for-localization-and-rtl-from-start.md).

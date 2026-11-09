# Product design

This document describes the complete target product. The implemented local
preview has a narrower scope; see [MVP report](MVP_REPORT.md) for current behavior
and remaining release gates.

Status: research draft for discussion  
Target first public version: **1.0.0**  
Product name: **TrayNook** (selected, pending final clearance)

Canonical GitHub organization is **TrayNook**.
Intended repository: `github.com/TrayNook/traynook`
Permanent bundle identifier: `io.github.mahenzon.TrayNook`
Initial Homebrew tap: `github.com/TrayNook/homebrew-tap`, cask token `traynook`

Preview artifacts use GitHub prerelease tags `v1.0.0-alpha.N`, `v1.0.0-beta.N`, and `v1.0.0-rc.N`, while the macOS marketing version stays `1.0.0` and numeric build numbers increase monotonically. Stable Homebrew distribution begins with final `v1.0.0`.

Every public prerelease and stable release lists the exact environments tested and known limitations. The support target is every stable macOS major receiving current Apple security updates; compatibility is best effort and macOS 13.0 remains the technical minimum for older installations without guarantees; a full maintained-macOS acceptance matrix is not a release gate. Unverified private behavior still uses fail-visible capability gates.

Public previews and stable releases default to free ad-hoc signing with the same permanent bundle identifier; no paid Apple membership is required. Explicit `notarized` mode adds Developer ID signing and notarization. Ad-hoc releases can require manual Open Anyway approval and renewed Accessibility permission after updates. Public previews and stable builds form one installation/data lane rather than side-by-side apps. Local development uses the separate display name **TrayNook Dev** and bundle identifier `io.github.mahenzon.TrayNook.dev`, with separate preferences and privacy grants. Pull-request CI may remain unsigned and never publishes a downloadable `.app`; only trusted signed tags produce user-installable builds.

Upgrading from any public prerelease to a later prerelease or stable 1.0.0 preserves Desired Layout and settings through versioned forward migrations. Downgrades are unsupported. A build that cannot safely read stored state returns managed items to native Menu Bar layout, removes TrayNook-created concealment, and offers recovery instead of guessing or applying a partial layout. It preserves the unreadable data for diagnosis until the user explicitly chooses **Reset Layout**. One concise confirmation states that saved item identities, Placements, and order will be deleted and cannot be undone; it requires no typed phrase. Permissions, Launch at Login, and unrelated preferences remain unchanged. Persisted identity is limited to bundle identity and non-content stable discriminators—never dynamic Accessibility titles or labels, geometry, process/window IDs, or hashes of content-bearing strings.

## Product promise

Give every manageable macOS menu-bar item a reachable home, even when the physical menu bar is constrained by a MacBook notch.

The app has one job: organize items among three explicit homes—visible in the real macOS Menu Bar, available in a small Dropdown, or Always Hidden. The Dropdown opens from one Launcher whose Placement is permanently Menu Bar Zone, although the user controls its order among other visible items. TrayNook does not add automation, profiles, search, styling, or widgets.

## Design principles

1. **Nothing gets lost.** The policy is to keep new, unknown, or uncertain items in the real menu bar and prefer visible recovery over a perfectly restored layout. Because macOS can initially insert a new item on either side of an internal boundary, the prototype must prove how quickly the app can detect and correct a concealed insertion.
2. **The source app stays in control.** Menus, popovers, windows, and accessibility semantics come from the app that owns the Source Item whenever macOS permits it.
3. **Explicit placement.** Every Managed Item has exactly one Placement: Menu Bar Zone, Dropdown Zone, or Always Hidden Zone. The Launcher is the sole exception whose Placement is permanently Menu Bar Zone while its order remains user-controlled.
4. **Quiet while idle.** No continuous background capture, analytics, accounts, or cloud state. Optional update checks run at launch and daily; archive downloads require their separate preference.
5. **Minimal persistence.** Store only the item identity, Placement, and order needed for Desired Layout plus explicit app preferences, onboarding acknowledgements, state-schema version, and the clean-Quit baseline. The updater may also keep disposable downloaded release archives locally. Never persist captured pixels, native-interface contents, interaction history, usage frequency, or analytics identifiers.
6. **Mac-native, not customizable.** Use current system materials, spacing, motion, focus, and accessibility behavior. There are no themes.
7. **Permission use is explicit.** The app explains each permission before macOS asks for it and requests only permissions needed by the chosen technical mechanism.
8. **Unsupported behavior fails safely.** A private API is used only after public approaches fail, behind capability checks. Missing or changed behavior disables the affected path, preserves visible recovery, and never crashes TrayNook.

## The user model

The Settings editor shows three ordered Placement Lanes:

```text
Menu Bar       [Calendar] [TrayNook Launcher · Menu Bar only] [Battery] [VPN]

Dropdown       [GitHub] [Cloud sync] [Audio] [Display]

Always Hidden  [Updater] [Rarely used helper]

Dropdown preview  [⚙ Settings fixed] [GitHub] [Cloud sync] [Audio] [Display]
```

Dragging an item changes its Desired Layout. The words “move to Dropdown” describe the user's intent; technically, the real Source Item remains in the macOS menu bar and a Proxy Item appears in the Dropdown.

An Always Hidden Source Item remains owned by its source application but receives no Proxy Item and appears in neither everyday access surface—the Menu Bar nor Dropdown. It remains visible for management in Settings and can always be returned through Settings or **Restore all items to Menu Bar**.

Protected Items remain visible with a lock and a short explanation. The Launcher may be reordered anywhere within Menu Bar Zone, but cannot be assigned to Dropdown Zone or Always Hidden Zone.

TrayNook does not override the user's chosen Menu Bar order to keep its Launcher first or rightmost. If that order or physical crowding puts the Launcher behind a notch, Spotlight/Finder launch remains the guaranteed route to Settings. The Layout editor warns when the selected Menu Bar Zone exceeds the detected safe width.

### Placement model

Barbee's editor validates the selected interaction: drag within a Placement Lane to reorder and across Placement Lanes to change Placement. TrayNook has exactly three Placement Lanes: **Menu Bar**, **Dropdown**, and **Always Hidden**. Placement Lanes in Settings are distinct from the wrapped Dropdown Rows shown when the Launcher is clicked.

## Primary experiences

### First launch

1. The app opens Settings on Permissions and introduces the placement model briefly.
2. It explains and guides Accessibility first, then Screen Recording, requesting one permission at a time. Any additional privacy permission is requested only if the prototype proves it necessary for a committed feature.
3. Until Accessibility is granted, the app does not move or conceal any Source Item. Without Screen Recording, it can continue later with app-icon-only proxies identified by tooltip and VoiceOver.
4. After permission status refreshes and reconciliation succeeds, Settings switches to Layout with every newly discovered Source Item initially in Menu Bar Zone.
5. Onboarding then recommends Launch at Login once. It defaults to off and is enabled only with consent; declining or dismissing the recommendation does not cause repeated prompts, and the setting remains available in General.
6. Subsequent explicit launches open Layout regardless of permission or reconciliation state. Missing Accessibility leaves layout editing read-only with recovery guidance. Screen Recording is optional; its loss uses fallback proxies and retains the badge/retry UI.
7. If Screen Recording is declined, onboarding still proceeds with fallback proxies and never prompts for it again automatically; Permissions retains a badge and explicit retry/System Settings actions.
8. If Accessibility is declined during onboarding, native management remains safely inactive and does not prompt again automatically. The onboarding flow keeps Permissions selected until an explicit retry or System Settings grant is followed by successful reconciliation; ordinary Settings opens still select Layout.

### Everyday use

1. The app runs as a Dockless menu-bar utility at all times, including while Settings is open.
2. The Launcher remains in the real menu bar, in the position chosen by the user. Its monochrome template mark is an open tray/pocket containing three dots, adapts to the current Menu Bar appearance, and contains no text.
3. A primary click on the Launcher toggles the Dropdown on the display containing the Launcher regardless of permission state. Without Accessibility, the gear remains usable while native Proxy Item actions and layout editing are disabled. Without Screen Recording, the Dropdown uses fallback proxies.
4. The Dropdown opens directly below the menu bar, stays within that display's usable bounds, and starts with a fixed gear-icon Settings Button followed by Running Proxy Items. Not Running and App Missing placeholders exist only in Settings. Items flow in semantic leading-to-trailing order before wrapping downward, mirroring in right-to-left interfaces.
   Background status and recovery actions live in Settings. A failed Proxy Item action opens Settings with its error, while ordinary scan notices leave the Dropdown compact.
5. The Dropdown consumes physical Escape down, repeats, and up locally and closes on key-up. Clicking the Launcher again or clicking outside also closes the Dropdown. An outside click continues to its intended application or control; TrayNook observes dismissal without consuming the click or replaying a synthetic duplicate. Clicking a Proxy Item begins the separately defined Interaction Handoff: TrayNook first tries to keep the Dropdown visible and uses the accepted temporary-hide fallback only when no reliable workaround exists.
6. Clicking the Settings Button closes the transient Dropdown and opens or raises Settings on Layout. Neither the Dropdown nor its Settings Button requires Accessibility or Screen Recording; native source management remains gated by Accessibility.
7. For pointer and keyboard opening alike, TrayNook activates and waits until active before showing the Dropdown. The Dropdown must own keyboard input or close safely. It uses no global keyboard tap or synthesized foreign key events. Keyboard or VoiceOver opening focuses the first control, the gear; pointer opening does not automatically focus it. Passive Escape or Launcher-toggle dismissal restores the previously active application and focus when macOS permits. An outside-click target, Settings command, or source app intentionally receiving focus wins instead. The prototype checks this contract in the recorded test environments.

### Explicit application launch

- Launching the app from Spotlight, Finder, Launchpad, or a second `open` request opens or raises Settings.
- The fixed gear-icon Settings Button and **Open Settings** in the Launcher's secondary-click menu use the same behavior.
- If the app was not running, it starts and opens Settings.
- TrayNook creates Settings if absent; otherwise it unminimizes, activates, and raises the existing singleton window, including from another Space.
- Every ordinary open or raise selects Layout, including when the window already exists or permissions are unavailable. First-launch onboarding and explicitly targeted Permissions actions remain separate flows.
- A login-item launch starts silently and does not open Settings.
- Closing Settings leaves the app running in the menu bar.
- Ordinary Quit preserves the user's Launch at Login preference. Removal instructions first disable Launch at Login, restore all items, and then quit so no stale login registration remains.

### Editing the layout

- Settings contains three toolbar tabs: **Layout**, **Permissions**, and **General**.
- Layout uses three Barbee-like horizontal Placement Lanes—Menu Bar Zone, Dropdown Zone, and Always Hidden Zone—as ordered, draggable collections.
- The user can drag a Managed Item within a zone to reorder it or across zones to change Placement.
- The Launcher participates in Menu Bar ordering and may be dragged anywhere within that Placement Lane or within the physical menu bar. It cannot be dropped into Dropdown Zone or Always Hidden Zone and never receives a Proxy Item.
- If an external Command-drag crosses TrayNook's internal boundary with the Launcher, the app reconciles it to the nearest valid Menu Bar position while preserving as much of the user's requested order as possible.
- If the Launcher is Command-dragged completely off the Menu Bar, TrayNook restores it automatically to the nearest valid position consistent with the user's order. Quit, not Launcher removal, stops the app.
- A confidently detected user Command-drag that leaves an item in a valid Menu Bar position is authoritative and immediately updates Desired Layout. TrayNook does not restore the old Settings order; ambiguous system- or source-app-driven reshuffles are reconciled without silently changing Placement.
- A confidently detected deliberate crossing between Menu Bar and Dropdown changes Placement immediately. Invalid destinations for the Launcher or a Protected Item are rejected without changing Desired Layout.
- The open Dropdown supports drag reordering. The prototype must exhaust reasonable approaches to direct drag between the physical menu bar and Dropdown in both directions. If that remains unreliable, Settings-lane dragging is the accepted cross-placement fallback for 1.0.0 because macOS does not provide native cross-process dragging.
- Moving an item into or out of Always Hidden is performed through its Settings Placement Lane because Always Hidden deliberately has no direct surface.
- Protected Items cannot be placed where macOS cannot support them.
- If a valid user-requested Placement fails transiently, retain it in Desired Layout, keep the real item visible in Menu Bar, and show a Placement Mismatch. Retry only after explicit user action or a meaningful permission, capability, source-app, display, or geometry change—not on a continuous failure loop. If testing proves the destination permanently unsupported, classify the item as Protected, reject that placement, and preserve its prior valid Desired Placement.
- Settings Placement Lanes always show Desired Layout rather than moving cards to physical fallback positions. A Placement Mismatch stays in its intended lane with **Currently in Menu Bar** and **Retry Placement**. Missing Accessibility preserves all lanes but makes layout editing read-only; Permissions and General remain usable.
- Changes apply immediately with no Save or Apply button. Every in-process user-authored layout or identity mutation participates in one Undo history: Settings and Dropdown drags, confidently detected physical Command-drags, ambiguity resolution, Leave Unmanaged, Forget Item, and Restore All. Undo/Redo is available through `⌘Z` / `⇧⌘Z` and enabled **Edit → Undo/Redo** menu commands while Settings is active. Automatic reconciliation, launch-time offline-order adoption, Quit, Reset Layout, Reset TrayNook, and Erase Data and Quit are not Undoable.
- Undo history survives closing and reopening Settings during one TrayNook process lifetime, resets on termination or relaunch, and is never written to disk. Desired Layout persists after every accepted change.
- Manual **Restore all items to Menu Bar** applies without confirmation and registers as one grouped Undo action. It keeps current Menu Bar items first, then appends Dropdown items, then Always Hidden items, preserving each lane's semantic order. Every saved identity—including Not Running and App Missing—changes to Menu Bar so nothing later returns concealed. Quit uses the same physical merge for running items but does not change saved Desired Layout and is not undoable.
- The app remembers a best-effort identity for items across source-app restarts. If it cannot confidently match an item, it keeps that Ambiguous Item in Menu Bar, marks it in Settings, and waits for explicit user resolution rather than guessing or silently swapping duplicates. **Resolve Ambiguous Item** offers **Match to Saved Item…**, **Treat as New Menu Bar Item**, and **Leave Unmanaged**. Matching lists only compatible retained identities and treats the user's choice as authoritative without claiming TrayNook verified identical instances. Treat as New creates a fresh identity without deleting retained ones. Leave Unmanaged persists the acknowledgement, keeps the item visible and outside automatic placement, clears its attention indicator, retains Resolve for later, and alerts again only for a materially new identity conflict. Forget Item remains a separate action on stale saved identities.
- An absent configured item retains its saved Placement and order indefinitely so it can return without losing layout. TrayNook never expires it automatically; Settings provides an explicit **Forget Item** action.
- Not Running and App Missing placeholders appear only in Settings and consume no everyday Dropdown slot. A returning Source Item inserts its Running Proxy Item at the saved position.
- Forget Item is available only for Not Running, App Missing, or unresolved saved identities. It removes identity, Placement, and order; a later reappearance defaults to Menu Bar. Running items cannot be forgotten because they would be rediscovered immediately.
- One global Desired Layout applies to every display. The Dropdown opens and adapts its wrapping to the display containing the clicked Launcher; per-display layouts are not created.
- A newly discovered item defaults to Menu Bar and adopts its observed relative position when that evidence is trustworthy. Otherwise it appends after existing Menu Bar items in semantic lane order without reshuffling known items.
- The Settings Button is previewed as a fixed first Dropdown control but never appears as a draggable Source Item.

### Opening a Source Item

The intended interaction is an Interaction Handoff:

1. The user clicks a Proxy Item.
2. The app temporarily puts the corresponding Source Item in a usable position in the real menu bar.
3. It synthesizes an equivalent click at that Source Item; the original event cannot be transferred between processes.
4. The source application presents its own menu, popover, or window.
5. That interface anchors to the real item's temporary Menu Bar position, placed near the Launcher when macOS permits, rather than necessarily beneath the clicked Proxy Item.
6. For a transient menu or popover, the Source Item remains promoted for the duration of that interface.
7. When the menu or popover closes, the app restores Desired Layout. Opening or raising an ordinary window, toggling state, launching an app, or producing no interface completes handoff after a short measured grace period, restores Desired Layout, and leaves the Dropdown closed rather than tracking a long-lived window indefinitely.

TrayNook first attempts to keep the Dropdown visibly open throughout step 4. If the initial mechanism fails, the prototype must explore reliable focus, window-level, and interaction-tracking workarounds. If none succeeds in the tested environments, the accepted fallback is **yield and resume**: temporarily hide the Dropdown while the source application's native menu or popover is active. A selected source command or a source interface that closes itself may resume the Dropdown unless that action opens/raises an ordinary window or intentionally transfers focus to the source app; the ordinary-window rule wins and leaves Dropdown closed. Escape, an outside click, Launcher toggle, Open Settings, Restore, or Quit ends the Dropdown session and suppresses reopening.

TrayNook does not reimplement or imitate a foreign app's menu or popover to change that anchor. See [ADR 0007](adr/0007-use-proxies-and-native-interaction-handoff.md).

Only one Interaction Handoff may be active. If another Proxy Item is selected, it replaces any pending request; TrayNook waits for the current native interface to dismiss and then activates that latest request. Concurrent promotions and multi-click queues are not supported.

A confidently detected user Command-drag of the temporarily promoted Source Item is authoritative. It ends handoff, adopts the resulting valid Placement and order immediately, and suppresses restoration of the pre-handoff layout. Invalid destinations for the Launcher or a Protected Item remain rejected.

Open Settings, Restore, Reset TrayNook, Erase Data and Quit, and Quit preempt Interaction Handoff. They clear any pending Proxy request, end the Dropdown session, safely finish and reconcile the current promotion, then perform the requested command. They never leave a foreign item temporarily promoted or wait indefinitely; the same bounded, fail-visible recovery rules apply.

### Quitting and recovery

- A normal Quit returns every Managed Item to native Menu Bar layout using the deterministic Menu Bar → Dropdown → Always Hidden merge, removes TrayNook's own status items and boundaries, and terminates. Exact ordering is best-effort: termination may proceed once every running item TrayNook managed has been returned to native layout and no TrayNook-created concealment remains. If TrayNook-created concealment remains, Quit is cancelled and recovery UI stays available. From a successful Quit onward, macOS lays out items as if TrayNook were absent, including ordinary native notch clipping if the bar is overcrowded. Permission-loss recovery, Reset TrayNook, Prepare for Uninstall, and Erase Data and Quit use the same physical merge.
- Quit requires no confirmation because native-layout restoration runs first and saved Desired Layout plus Launch at Login remain intact. An imperfect native order does not trap the user in TrayNook; TrayNook does not claim that an overcrowded native bar makes every item physically visible around a notch.
- A **Restore all items to Menu Bar** action is available from Settings and the Launcher's secondary-click menu.
- If permissions are denied or revoked, the app stops applying affected Placements and explains the recovery path. If identity no longer matches confidently, the Ambiguous Item stays visible in Menu Bar until the user resolves it in Settings.
- Ambiguous Items, permission loss, and Placement Mismatches produce a subtle Launcher attention indicator and a concise Settings banner; the indicator clears after every attention state is resolved. TrayNook requests no notification permission and sends no Notification Center alerts in 1.0.0. Ordinary new items create no alert.
- A small metadata-only reconciliation loop may run while the manager is active so a newly created item can be moved to the safe default. It never captures screen pixels while Dropdown and Settings are closed; its cadence and idle-resource budget must be proven by the prototype.
- After a crash or force-kill, TrayNook's own boundaries disappear with its process but macOS may retain the last managed ordering of real items. The next launch reconciles Observed Layout before concealing anything, leaves ambiguous items visible, and then reapplies Desired Layout.
- Desired Layout remains saved across a normal Quit and is reconciled and reapplied on the next launch. The Launch at Login preference is unchanged.
- A clean Quit records the final native Menu Bar order only when it was observed confidently. If the next launch observes a different order, TrayNook adopts the new relative order as offline user intent, retains known Placements, defaults new items to Menu Bar, and then reapplies. It does not make this inference after a crash or an uncertain Quit.
- Uninstall documentation starts with restoration and Quit; Homebrew removal should also quit the process cleanly.

## Dropdown layout

The setting is **Row Capacity**: the maximum number of controls in each Dropdown Row.

- Default: **10 controls per row**.
- Control: a whole-number slider from 1–30 with a live Dropdown preview. It neutrally highlights the 5–20 recommended band and shows **Short rows**, **Recommended**, or **Long rows** below the control. Every value remains valid, with no warning colors or confirmation.
- First element: the gear-icon Settings Button is first in both visual and keyboard order and consumes one of the 10 default slots. The first row therefore contains the gear plus at most nine Proxy Items. It is excluded from Desired Layout, persistence, and drag operations, and scrolls naturally with the first row rather than remaining sticky.
- Packing: preserve user order; place complete controls in semantic leading-to-trailing order and wrap after Row Capacity is reached. Never split or scale an item to make it fit.
- Proxy appearance: preserve each captured Source Item's native visual width and appearance with no permanent text label. Provide its accessible item/app name through a standard hover tooltip and VoiceOver label.
- Fallback appearance: when capture is unavailable, show only the source app icon with the same tooltip and VoiceOver identity. If candidates cannot be distinguished safely, keep them Ambiguous in Menu Bar.
- Physical safety: Source Items can be wider than ordinary icons. Row Capacity is a logical maximum, so TrayNook wraps earlier when the packed row would exceed the active display. It never shrinks controls merely to reach the configured count.
- Screen edge: clamp the panel to the active display.
- Vertical overflow: cap the panel to the active display's usable height and place excess rows in one continuous vertical scroll container. Do not impose an item or row limit.
- Dynamic changes: recompute when the screen, scale, menu-bar geometry, or item width changes.
- Proxy refresh: capture immediately when the Dropdown or proxy-bearing Layout tab becomes visible, then refresh visible proxies at most once per second while either remains visible. Stop capture and purge image buffers when neither proxy-bearing surface is visible; frame-perfect animation is not promised.

All timing, polling, timeout, and similar policy values are named tuning constants kept in one documented location so they can be changed without searching through unrelated code.

## Settings surface

Settings is one small window with three toolbar tabs: **Layout**, **Permissions**, and **General**. Every ordinary open or raise selects Layout, regardless of permission or reconciliation state. First-launch onboarding and explicitly targeted Permissions actions may select Permissions. Permissions carries an attention badge for blocking Accessibility or degraded Screen Recording state. Attention banners are window-level or context-local to the relevant Layout/Permissions state, never hidden only inside General.

**Layout**

- Placement editor using three horizontal drag lanes: Menu Bar Zone, Dropdown Zone, and Always Hidden Zone
- Lanes represent Desired Layout even during physical fallback; mismatch status shows **Currently in Menu Bar** and a per-item **Retry Placement** action. Missing Accessibility makes layout editing read-only without erasing the saved arrangement
- A non-blocking, text-and-symbol Menu Bar capacity warning when active-display geometry predicts notch or screen-edge overflow; never prevent the arrangement or rely on color alone
- Row Capacity slider from 1–30 with live preview, recommended range 5–20, default 10, and the fixed gear counted
- Per-item state: Running, Not Running, App Missing, Protected, Ambiguous, or acknowledged Unmanaged. Normal/desaturated/dimmed filters reinforce state, while text, badges, and accessible labels carry the meaning
- Restore all items to Menu Bar

**General**

The full reset and uninstall flows below remain target designs. The current app
implements Reset Layout and preserves update preferences and downloaded archives;
it has no full-data erase command.

- Launch at Login
- Version, licenses, source-code link, and Quit
- Public author credit: Suren Khorenyan
- Copy Diagnostics: before copying, explain that the local summary includes permission/recovery state and affected, pending, or repair application bundle identifiers; copy only after explicit user action
- Report a Problem…: after explicit user action, open `https://github.com/TrayNook/traynook/issues/new` in the browser. The source repository must have GitHub Issues enabled. Never attach or transmit diagnostics automatically; the user reviews and pastes them deliberately
- Prepare for Uninstall: show removal instructions, then Restore, Disable Login, and Quit; never claim to delete the app itself. Explain the optional final cleanup of removing TrayNook from Accessibility and Screen Recording in System Settings because TrayNook cannot revoke those grants itself
- Reset TrayNook: after confirmation, restore all items, disable Launch at Login, clear every TrayNook-owned setting, identity, onboarding acknowledgement, and Undo history, remain running, and return to first-launch Permissions. Permissions reads and displays any still-granted macOS authorization without requesting it again. An explicit Continue precedes reconciliation and layout management; afterward Layout opens and the reset one-time Launch at Login recommendation appears again. Running again may create fresh identity data, so this is accurately named Reset rather than Erase
- Erase Data and Quit: after confirmation in the uninstall flow, restore native Menu Bar layout, disable Launch at Login, remove TrayNook controls, clear TrayNook-owned local data, and terminate. Advertise `brew uninstall --cask --zap traynook/tap/traynook` as self-contained only after testing proves equivalent safe stop, restoration, login unregistration, app removal, and data cleanup; otherwise require Erase Data and Quit first. Neither path can revoke system-owned privacy grants

**Permissions**

- Accessibility and Screen Recording status read from current system state
- Plain-language explanation of what each permission enables
- An **Open System Settings** action targeting the closest relevant Privacy & Security pane available on that macOS version
- Status refresh whenever Settings becomes active again; never display a permission as granted before macOS reports it
- Accessibility unavailable: restore all real items to Menu Bar and disable movement/handoff while keeping Launcher and Settings usable
- Screen Recording unavailable: retain placement/handoff through Accessibility and use app-icon-only proxies with tooltip and VoiceOver identity
- A declined Screen Recording request does not repeat automatically; recovery remains explicit in Permissions
- Launcher primary-click opens the Dropdown regardless of permission state; its gear remains usable without Accessibility, while native Proxy Item actions remain disabled. Screen Recording is optional and its loss uses fallback proxies

The Launcher secondary-click menu contains only **Open Settings**, **Restore All Items**, **About**, and **Quit**.

## Version 1.0.0 feature set

### Core features

- A Dockless menu-bar utility with one Launcher whose Placement is fixed to Menu Bar while its order is user-controlled
- A distinctive monochrome open-tray/pocket Launcher mark containing three dots, with no text and automatic Menu Bar appearance adaptation
- A native-looking Dropdown anchored to the menu bar
- A fixed gear-icon Settings Button first in the Dropdown's visual and keyboard order
- Wrapped Dropdown Rows with configurable Row Capacity, defaulting to 10 controls and counting the fixed gear
- Vertical scrolling when Dropdown Rows exceed the active display's usable height
- Discovery and visual representation of Managed Items
- Three explicit Placements: Menu Bar, Dropdown, and Always Hidden
- Complete three-lane Placement editing and drag reordering in Settings
- Immediate layout application with standard Edit-menu and keyboard Undo/Redo
- Direct drag reordering inside the Dropdown; attempt direct physical-menu-bar-to-Dropdown dragging in both directions, with Settings-lane dragging as the accepted cross-placement fallback after workarounds are exhausted
- Persistent Desired Layout across app and source-app relaunches
- Interaction Handoff for primary and secondary click, attempting simultaneous Dropdown visibility first and using the accepted yield-and-resume fallback only after workarounds are exhausted
- Settings that open from an explicit application launch, including while already running
- One Settings window with Layout, Permissions, and General tabs; every ordinary open or raise selects Layout and Permissions badges actionable permission states
- Outside-click, Escape, and Launcher-toggle dismissal
- Safe defaults, restoration controls, and permission-revocation handling
- Versioned forward migration from every public 1.0 prerelease; unreadable or newer state fails visible and offers recovery rather than moving items
- Explicit Reset Layout for unreadable state, limited to item identities, Placements, and order rather than a factory reset
- Prepare for Uninstall flow shared by manual and Homebrew removal documentation
- Dedicated permission status and recovery UI with direct System Settings actions
- Runtime capability gates and visible fallbacks for every deprecated or private macOS dependency
- Notch and non-notch geometry, multiple displays, full-screen Spaces, and auto-hidden-menu-bar handling
- VoiceOver labels, focus indication, keyboard activation for ordinary controls, Reduce Motion, and increased-contrast support; complete keyboard-only layout editing is not claimed in 1.0.0
- Activation before showing the Dropdown for pointer and keyboard entry, required keyboard ownership with safe close on failure, local Escape consumption through key-up, gear-first keyboard/VoiceOver focus without pointer autofocus, and best-effort prior-focus restoration only for passive dismissal; intentional outside-click, Settings, and source-app focus transfers win
- US English in 1.0.0, with all strings localization-ready and layouts tested for expansion, bidirectional text, and right-to-left mirroring
- Launch at Login using the system service, default off, with one explicit onboarding recommendation
- Local-only preferences and Desired Layout; no telemetry; core layout management works offline
- Persist only bundle identity, non-content stable discriminators, Placement, and order plus explicit app preferences, onboarding acknowledgements, state-schema version, and the clean-Quit baseline. Never persist dynamic Accessibility titles or labels, geometry, process/window IDs, hashes of content-bearing strings, captured pixels, or behavioral history. Copy Diagnostics includes TrayNook/macOS versions, permission and recovery state, failure details, and affected/pending/repair application bundle identifiers, disclosed before copying. It excludes item/window titles, a complete application inventory, Desired Layout, saved item identities, pixels, and interaction history; users review it before posting
- Check for Updates in General and the Launcher context menu, changelog in General, automatic checks at launch and daily (default on), and separate automatic downloads (default off). Signed archives stay in a local cache; Sparkle 2.10 installation and relaunch start only after explicit Install & Relaunch approval, without a second Sparkle confirmation; macOS authorization may still be required. Before that approval, Quit or crash cannot install a downloaded update. GitHub receives ordinary HTTPS request metadata; no system profile, application inventory, screenshots, layout, telemetry, or crash report is uploaded. Disabling automatic checks stops background update activity; development and diagnostic modes do not start it
- Free use with no subscription, purchase, account, or entitlement; complete public source under the MIT License
- Universal application for Intel and Apple silicon
- GitHub Release containing one `TrayNook.app` ZIP and its SHA-256 checksum, ad-hoc signed by default with an optional paid notarized mode, with no DMG or installer package. Stable releases also publish `appcast.xml` with an Ed25519 payload signature for the final ZIP. The same ZIP feeds the `traynook` cask in `github.com/TrayNook/homebrew-tap`; official Homebrew Cask submission is optional, requires meeting its acceptance rules, and does not block 1.0.0

### Conditional features

These belong to 1.0.0 only if the feasibility prototype proves them reliable in the recorded test environments:

- Real-time Proxy Item animation or changing text while the Dropdown is open
- Stable restoration of multiple indistinguishable Source Items from one application

### Explicit non-goals

- Automatic rules, timers, focus-mode profiles, per-display profiles, or triggers
- Search, groups, folders, favorites, recent items, or usage analytics
- Global hotkeys, hover reveal, scroll reveal, gestures, or menu-bar scrubbing
- Proxy-level modifier clicks, scrolling, pressure, and long press; primary click, secondary click, and layout dragging are the committed Proxy Item interactions
- Keyboard and context-menu Move to/Move Earlier/Move Later layout actions; deferred to 1.1.0
- Menu-bar spacing controls, app-menu hiding, notch shaping, or display resolution changes
- Themes, tinting, custom icons, sounds, or animation settings
- Scripts, plugins, widgets, shortcuts actions, or URL schemes
- Cloud sync, accounts, collaboration, backups, or import/export in 1.0.0
- Mac App Store distribution
- Full Disk Access, an administrator helper, or root privileges
- Notification Center alerts or notification permission
- Support for beta macOS releases as production targets

## Planned for 1.1.0

- Keyboard and context-menu **Move to Menu Bar / Dropdown / Always Hidden** actions
- Keyboard and context-menu **Move Earlier / Move Later** ordering actions
- Complete keyboard-only and VoiceOver-accessible layout editing

## Compatibility promise

TrayNook targets every stable macOS major receiving current Apple security updates, using [Apple security releases](https://support.apple.com/en-us/100100) at release time. It ships a Universal 2 app for Intel and Apple silicon with a technical minimum of macOS 13.0. Older systems outside the support target may install and run without compatibility guarantees. Compatibility is best effort. Release notes list exact OS builds, architectures, hardware, display configurations, results, and known limitations actually tested. A deployment target and bundled architecture do not certify untested environments. See [ADR 0002](adr/0002-support-current-stable-macos-releases.md).

The former full maintained-macOS acceptance matrix is no longer a release gate. Untested OS/hardware combinations do not block 1.0.0. Compatibility bugs are investigated from user reports through GitHub Issues; beta macOS versions carry no compatibility guarantee.

Checks on available environments cover discovery of Managed Items, all three Settings Placement Lanes, usable Dropdown proxies with an app-icon fallback, primary and secondary native handoff, and safe restoration. Runtime capability checks and visible recovery remain required. Some system items are protected by macOS and third-party implementations vary, so TrayNook cannot promise that every Source Item is manageable.

## Release criteria for 1.0.0

The 1.0.0 tag is appropriate only after:

1. Every feasibility gate in [Technical feasibility](FEASIBILITY.md) passes or its fallback is explicitly accepted.
2. No tested failure can assign the Launcher to Dropdown Zone or Always Hidden Zone; its user-selected Menu Bar order survives reconciliation, and explicit application launch still recovers Settings if macOS physically conceals it.
3. Quit, crash recovery, permission revocation, reset, and uninstall paths are documented and manually verified.
4. The critical interaction suite passes on the available test environments, with exact coverage and known limitations recorded in release notes.
5. The Universal 2 app passes strict signature-integrity checks and records its actual distribution mode. Ad-hoc signing is the default; only explicit notarized mode requires Developer ID, Hardened Runtime, notarization, stapling, and Gatekeeper acceptance. Release instructions explain manual macOS approval for ad-hoc artifacts.
6. Accessibility and Screen Recording explanations match actual behavior and no captured pixels are written to disk.
7. The name, permanent bundle identifier `io.github.mahenzon.TrayNook`, GitHub repository, owner-tap cask token, and license have been locked.
8. The public repository contains the complete corresponding source under the MIT License, with no paid feature gate and no copied GPL implementation code.
9. Explicit launch and every ordinary Settings open or raise select Layout without requiring Accessibility or Screen Recording. Launcher primary-click still opens the Dropdown without either permission; its Settings Button remains usable while native source actions require Accessibility. Silent login launch plus every supported `SMAppService` state has been verified.
10. Any private-API-dependent path is checked in the recorded test environments; missing, changed, and deliberately disabled capabilities have also been tested for crash-free visible fallback.
11. Release notes describe compatibility as best effort and do not claim untested OS/hardware combinations are certified.
12. Stable update signing uses protected Ed25519 secrets in trusted GitHub-verified signed-tag workflows, with manual draft review before publication. Apple credentials are required only for optional notarized releases; no signing credential is present in the repository or untrusted contribution workflow.
13. Update signing is configured before public 1.0.0, signed-archive rejection and explicit install consent are verified, and disabling background checks prevents background update activity.
14. US English, pseudolocalized, and RTL-pseudolanguage builds pass the critical UI suite; translation contribution instructions are current.

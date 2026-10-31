# TrayNook

A native macOS menu-bar organizer. This repository builds a **development
preview** with Settings, a dropdown, saved placements, and guarded native
interaction. MVP acceptance and public release verification are incomplete.

[Implementation report and release blockers](docs/MVP_REPORT.md)

Build 17 replaces whole-section reveal with a single-item handoff. Clicking a
proxy moves only that source beside TrayNook, opens its native menu, and returns
it after dismissal. The hidden section stays collapsed, so the total number of
hidden icons no longer has to fit beside the notch. The dropdown also fits its
actual controls instead of reserving empty columns.

## Build and run

Requires macOS 14 or newer and Xcode with Swift 6. No third-party dependencies.

```sh
Scripts/test.sh
Scripts/build-app.sh
open "dist/TrayNook Dev.app"
```

The app runs without a Dock icon. Launch it again from Finder to reopen Settings;
closing Settings leaves the menu-bar launcher running. Right-click the launcher
for reveal, Settings, and Quit commands.

1. In Permissions, grant Accessibility to the **whole app**, then Refresh.
2. In Layout, choose Menu Bar, Dropdown, or Always Hidden. You can also drag a
   row onto a lane. TrayNook positions its controls, applies the saved placements,
   and collapses the selected items automatically. Failures keep items revealed
   and retain your requested placement for Retry.
3. **Show Items** temporarily reveals the section; **Hide Items** or
   **Apply Saved Layout** arranges and collapses it again. **Reveal All Items**
   also cancels an operation in progress.
4. Click the tray icon for the proxies: captured menu-bar icons with Screen
   Recording, application icons without it. If the section is revealed, TrayNook
   first applies the requested placements and hides it. Preparation errors appear
   in the dropdown. Right-click a proxy and choose
   **Open Secondary Menu** for the source item's secondary action.

Launching restores saved placements after the first complete inventory. During
normal interaction, only the selected source temporarily appears in the menu bar.
Its original neighboring position is retained for restoration. A failed move
preserves the hidden section and reports the problem; it does not silently reveal
all icons. Dismissal uses native menu events or the lifetime of newly opened
windows; an already-open app window does not keep the selected source visible.
An interrupted return waits for idle input and retries only the move. Without
confirmed dismissal, the source stays visible until the next launcher click.
Unrecognized windows, changed
inventory, or display changes can still trigger conservative recovery.
Repeated Accessibility scan failures temporarily reveal items; the saved layout
resumes after a complete scan unless identities changed or you chose Show Items.
Inventory traversal stops at each status icon; the contents of an app's popup
menu do not block discovery. The internal concealment boundary reserves no
menu-bar slot while items are revealed. It returns only for placement and
concealment operations.

Screen Recording is optional: with it, each proxy shows the item's real menu-bar
icon as last seen while visible (public capture cannot read offscreen windows);
without it, proxies are application icons. Several items from one app are
managed individually when they can be told apart; indistinguishable siblings and
Apple system controls stay protected. An offscreen item
is moved through verified PID/window-targeted public events, and must reach a
safe visible position before activation. The total hidden section may exceed the
screen width, but there must still be room for one selected source. Dropdown
arrows reorder proxies; full native order management uses Command-drag.

## Settings preview and native flow

Layout contains the interactive **Saved layout preview**: a Menu Bar
strip with the launcher, the same icon grid used by the dropdown, and a separate
Always Hidden area. Drag an application icon to reorder it or move it between
zones. A floating icon follows the pointer while neighboring icons animate
out of the way, leaving an empty insertion slot, and the destination lights up. Dropping saves once with one Undo
step; Escape or dropping outside the preview cancels. Protected items, the
launcher, and the gear stay fixed. Menu Bar order in the preview is editor order;
use Command-drag for the physical menu bar.
Changing row capacity updates the preview immediately; the gear
occupies the first slot. Missing apps consume no dropdown slots, protected apps
are marked as kept visible, ambiguous siblings are not listed, and unavailable
inventory is identified. Application
icons illustrate saved placements; native order and spacing can differ.

Layout also contains collapsible **Item details** with names, placement controls,
drag handles, status, Retry, and Forget, plus the layout reset action.
Placement controls remain available for closed or missing apps; their saved
choice applies when the source returns. Detail-row dragging saves once on release
and registers one Undo action.
General contains Launch at Login, dropdown icon appearance, diagnostics, and version and
privacy information. Permissions shows only access status and grant actions;
all three tabs scroll at the minimum window size. The glyph preference in General
links to Permissions when Screen Recording is missing.

Settings uses native segmented navigation. Retry appears only for a placement mismatch.
Unavailable launcher-menu commands are disabled. Opening Settings cancels an
active operation without changing saved placements.

Native activation prefers advertised Accessibility actions. Only the selected
source is moved and returned; the full saved layout is not reapplied on a proxy
click. See the [verified flows and remaining limits](docs/MVP_REPORT.md#verified-user-flows).

## Verification

```sh
Scripts/test.sh
Scripts/smoke-test.sh
"dist/TrayNook Dev.app/Contents/MacOS/TrayNook" --diagnose
```

Native acceptance checks (GUI session and Accessibility required):

```sh
Scripts/test-native-menu.sh
# Quit TrayNook first; this toggles only disposable TrayNook status items.
Scripts/test-native-boundary.sh
# Quit TrayNook first; this moves only a disposable fixture.
Scripts/test-native-movement.sh --clipped
Scripts/test-native-movement.sh --pointer-motion
# Owned fixtures: cancellation before down, after down, and after up delivery.
Scripts/test-native-cancellation.sh
# Full packaged app -> actual dropdown -> fixture menu -> automatic re-hide:
Scripts/test-dropdown-ui.sh --layout "$HOME/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json" --invalid-positions "dist/TrayNook Dev.app"
```

The optional `--clipped` case requires macOS to actually clip the fixture. Its
checks fail explicitly if the environment cannot establish that condition.

The dropdown test requires TrayNook to be quit and input left idle. `--layout`
reads the original file, copies its placements into an isolated test identity,
and adds two disposable sources. An independent 60Hz witness checks that the
Always Hidden source never appears during either native-menu handoff. The test
also verifies notch-safe icon/menu geometry, exactly one action, restoration,
repeated launcher toggles, Settings cancellation, and original-state cleanup.
The old build fails this test because it reveals the second source. The default
fixture-only test can fail on a crowded bar; use the read-only layout copy in
that case. Smoke and backend checks alone do not establish the native flow.

Smoke mode opens Settings, verifies launcher/window creation, then exits without
requesting permissions, changing layout, or writing app preferences. `--diagnose`
is read-only and prints permission state, aggregate scan metrics, and how many
status windows Screen Recording can capture; no image is kept.

### Development signing and permissions

Development builds use `io.github.mahenzon.TrayNook.dev`. Sign them with a
self-signed certificate so macOS keeps Accessibility and Screen Recording grants
across rebuilds; an ad-hoc signature changes with every build, and macOS then
shows the old toggles as on while trusting nothing.

One-time certificate setup:

1. Keychain Access → Certificate Assistant → Create a Certificate. Name
   `TrayNook Dev`, identity type Self Signed Root, certificate type **Code Signing**.
2. If it landed in the System keychain, double-click it there → Trust → Code
   Signing: **Always Trust**. `security find-identity -v -p codesigning` must
   list it as valid.

Every build:

```sh
TRAYNOOK_DEV_SIGNING_IDENTITY='TrayNook Dev' TRAYNOOK_BUILD=25 Scripts/build-app.sh
```

First grant after switching signatures (also the recovery when the app says
**Not granted** while System Settings shows the toggle on):

1. Quit TrayNook. Purge the stale rows, which still point at the old signature:
   ```sh
   tccutil reset Accessibility io.github.mahenzon.TrayNook.dev
   tccutil reset ScreenCapture io.github.mahenzon.TrayNook.dev
   ```
2. Open `dist/TrayNook Dev.app`. Permissions → **Grant Accessibility…**, then in
   System Settings click **+** and pick the app (toggling an existing row does
   nothing).
3. **Grant Screen Recording…** and allow the prompt. The app appears in that
   list only after this button's one-pixel capture attempt.
4. Quit and reopen TrayNook once; macOS applies Screen Recording to a fresh
   process. Both now read Granted and survive later builds with the same identity. The saved layout is local, at
`~/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json`.
Unreadable or newer state is preserved and disables management until Reset Layout.

## Public release preparation

Public builds use `io.github.mahenzon.TrayNook`, Universal 2, Developer ID signing,
Hardened Runtime, and notarization. After the live acceptance blockers in the
report are resolved, use a locally installed signing identity and an existing
notarytool Keychain profile:

```sh
TRAYNOOK_BUILD=2 Scripts/release.sh 'Developer ID Application: …' notary-profile
```

The script tests, builds, signs, smoke checks, notarizes, staples, verifies with
Gatekeeper, and produces `dist/TrayNook-1.0.0.zip` plus its SHA-256 checksum. It does
not publish. Never commit signing keys or notarization credentials. Increment
`TRAYNOOK_BUILD` for every distributed build. Public release and Homebrew
publication remain pending; the planned cask is not advertised as available.

To uninstall, disable Launch at Login in Settings, quit TrayNook, and delete the
app. Quit removes TrayNook's separator and its concealment. Preferences are kept;
delete the app-specific Application Support folder for local layout erasure.
Accessibility approval is managed separately in System Settings.

## Project map

- `Sources/TrayNook` — app lifecycle, native UI, layout store, menu-bar control
- `Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore` — shared
  public Accessibility inventory and conservative identity assessment
- `Tests/TrayNookTests` — app state and geometry checks
- `Scripts` — test, app packaging, smoke, and signed release commands
- [Product design](docs/PRODUCT_DESIGN.md), [feasibility](docs/FEASIBILITY.md), and
  [decisions](docs/DECISIONS.md) — full target vision, broader than this preview
- [Domain language](CONTEXT.md) · [Translation guide](TRANSLATING.md)

The app makes no network requests and includes no analytics, private API calls,
or updater. Optional Screen Recording permission enables in-memory captures of
menu-bar icons; those images are never written to disk. Automatic placement of TrayNook’s own controls
uses AppKit’s undocumented saved-position preference keys; source-app preference
keys are never changed. Copyright © 2026 Suren Khorenyan.
[MIT License](LICENSE).

The repair was compared with Hidden Bar's
[separator-width engine](https://github.com/dwarvesf/hidden/blob/c801f8af2eb3a61e836e42715122f05b44fd0a83/hidden/Features/StatusBar/Engine/LegacyLengthEngine.swift)
and [controller](https://github.com/dwarvesf/hidden/blob/c801f8af2eb3a61e836e42715122f05b44fd0a83/hidden/Features/StatusBar/StatusBarController.swift).
TrayNook already used the same width mechanism; this repair fixes its surrounding
inventory, control ordering, and dropdown lifecycle. Hidden Bar is
[MIT licensed](https://github.com/dwarvesf/hidden/blob/c801f8af2eb3a61e836e42715122f05b44fd0a83/LICENSE);
no code was copied.

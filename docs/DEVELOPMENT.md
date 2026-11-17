# Developing TrayNook

For a quick introduction and first launch, see the [README](../README.md).
This guide covers local development builds, permission recovery, and checks.

## Build and run

The app has a technical minimum of macOS 13.0. Building requires Xcode with Swift 6 and a macOS version supported by that Xcode release. From the project folder:

```sh
Scripts/test.sh
Scripts/build-app.sh
open "dist/TrayNook Dev.app"
```

Development builds use the bundle identifier `io.github.mahenzon.TrayNook.dev`.
For free ad-hoc public builds and the optional notarized mode, see
[Releasing TrayNook](RELEASING.md).
Development builds, smoke tests, and `--diagnose` do not start automatic network
requests or update the production app. Update discovery and installation require
a configured public release identity and update-signing key.

## Development signing and permissions

A stable code-signing identity keeps Accessibility and Screen Recording grants
working across rebuilds. Without one, the first build uses an ad-hoc signature;
later builds refuse to replace an existing app when no development signing
identity is available.

One-time setup:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
   Use the name `TrayNook Dev`, identity type **Self Signed Root**, and
   certificate type **Code Signing**.
2. If the certificate landed in the System keychain, double-click it and set
   **Trust → Code Signing → Always Trust**.
3. Run `security find-identity -v -p codesigning` and confirm that
   `TrayNook Dev` is listed as valid.

The build script automatically uses a valid `TrayNook Dev` certificate. To use
another identity, set `TRAYNOOK_DEV_SIGNING_IDENTITY` when building.
To set a build number:

```sh
TRAYNOOK_BUILD=25 Scripts/build-app.sh
```

### Recover permissions after changing signatures

Use these steps if TrayNook reports **Not granted** while System Settings shows
the permission enabled:

1. Quit TrayNook and reset its development permission entries:

   ```sh
   tccutil reset Accessibility io.github.mahenzon.TrayNook.dev
   tccutil reset ScreenCapture io.github.mahenzon.TrayNook.dev
   ```

2. Open `dist/TrayNook Dev.app`. In Permissions, click **Grant Accessibility…**.
   In System Settings, click **+** and select the whole app. Toggling a stale
   entry does not update its signature.
3. If you want menu-bar icons in the dropdown, click **Grant Screen Recording…**
   and approve access. This button makes the capture attempt needed for macOS
   to list the app.
4. Quit and reopen TrayNook so macOS applies Screen Recording to the new process.

## Verification

```sh
Scripts/test.sh
Scripts/test-homebrew-cask.sh
Scripts/smoke-test.sh
"dist/TrayNook Dev.app/Contents/MacOS/TrayNook" --diagnose
```

Build the app before running the smoke test. Smoke mode checks the app bundle,
signature, launcher, and Settings without requesting permissions, changing the
layout, or saving preferences. `--diagnose` reports permission state and
aggregate inventory/capture metrics without saving images.

Native checks require a logged-in GUI session and Accessibility. Quit TrayNook
first and leave keyboard and pointer input idle. The scripts use disposable
TrayNook fixtures:

```sh
Scripts/test-native-menu.sh
Scripts/test-native-boundary.sh
Scripts/test-native-movement.sh --clipped
Scripts/test-native-movement.sh --pointer-motion
Scripts/test-native-cancellation.sh
```

The `--clipped` check requires macOS to actually clip the fixture; it fails if
the environment cannot establish that condition.

To check the packaged dropdown and native-menu flow using a read-only copy of
your saved layout:

```sh
Scripts/test-dropdown-ui.sh \
  --layout "$HOME/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json" \
  --invalid-positions "dist/TrayNook Dev.app"
```

This check copies placements into an isolated test identity and adds disposable
sources. It checks menu opening, restoration, hidden-item visibility, launcher
toggles, Settings cancellation, and cleanup. Unit and smoke tests alone do not
verify the native interaction. See the [MVP report](MVP_REPORT.md) for acceptance
results and remaining limitations.

## Local settings

Development layouts are stored at:

```text
~/Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json
```

Public builds use `io.github.mahenzon.TrayNook` instead. Unreadable or newer
layout data is preserved and disables management until **Reset Layout**.

Packaged builds keep `diagnostic-history.jsonl` beside `layout.json`. The local
history records fixed operation/scan result codes, timestamps, retry outcomes,
affected bundle/process identifiers, and aggregate timing/count metrics. It is
also updated when the model changes from concealed to revealed, with a fixed
reason code; debounce polls and repeated revealed-state cleanup add no such event.
It is capped at 1 MiB and expires entries after seven days; the size cap can evict
older entries sooner. Writes run on a serial utility queue, and the file is
private to the current user. Malformed, newer-schema, oversized, or inaccessible
existing histories are preserved and recording stops with a fixed log message.
Saved layout management continues independently of history storage failure.

For longer local investigations, the development app alone supports the
machine-local preference `ExtendedLocalDiagnosticHistory`. When enabled in
`io.github.mahenzon.TrayNook.dev`, it retains up to 30 days within 32 MiB after
relaunch. Public builds ignore that preference and retain the seven-day/1 MiB
defaults. This changes only the local file's limits; no upload is added.

The history contains no item labels, window titles, captured pixels, pointer/key
contents, or complete application inventory. Copy Diagnostics still copies only
the current state report. Smoke tests, `--diagnose`, unit tests, and disposable
native harnesses do not write the user's diagnostic history.

To uninstall, disable Launch at Login, quit TrayNook, and delete the app.
To erase saved preferences too, remove only the app-specific Application Support
folder after quitting. Accessibility and Screen Recording approvals are managed
separately in System Settings.

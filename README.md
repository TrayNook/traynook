# TrayNook

Keep your Mac’s menu bar tidy. Leave frequently used icons visible, move others
to a dropdown, or hide them. Universal app for Intel and Apple silicon.

## Install

Homebrew installation will be available after the first stable release.

```sh
brew tap traynook/tap
brew install traynook
```

Public releases are ad-hoc signed by default and distributed free through GitHub
and this custom tap. If macOS blocks opening, use **System Settings → Privacy &
Security → Open Anyway** after trying to open the app; see
[Apple's instructions](https://support.apple.com/en-us/102445). Ad-hoc updates may
require Accessibility approval again. Optional notarized builds are identified
in release notes.

## Use

1. Open TrayNook and grant **Accessibility** in Settings → Permissions.
2. In **Layout**, drag icons into **Menu Bar**, **Dropdown**, or **Always Hidden**.
3. Click the tray icon to open the dropdown. Right-click it for Settings or **Show Items**.

Your layout is saved automatically. Screen Recording is optional and enables
menu-bar icon previews. Your layout and preferences stay on your Mac; TrayNook
sends no analytics, application inventory, or screenshots.

TrayNook targets all stable macOS major versions receiving current Apple
security updates. Older systems may run it down to the technical minimum of
macOS 13.0, without compatibility guarantees. Release notes list the exact
environments tested; untested versions and hardware are not certified.

## Updates

Use **Check for Updates…** in Settings → General or the tray icon's context menu.
General shows the changelog. **Check automatically** is on by default and checks
at launch and daily; **Automatically download updates** is off by default.
Downloads stay in a local cache. **Install & Relaunch** approves installation
and relaunch without another Sparkle confirmation; macOS may request authorization.
Before that approval, quitting or crashing does not install a downloaded update.

Update checks and downloads contact GitHub over HTTPS, exposing the usual request
metadata and IP address. Turn off **Check automatically** to stop background
update activity; manual checks remain available. See [releasing](docs/RELEASING.md)
for update-signing setup.

## Report a problem

Open **Settings → General → Report a Problem…**, or
[create a GitHub issue](https://github.com/TrayNook/traynook/issues/new).
Diagnostics are never attached automatically. Review any copied diagnostics
before posting: they can include affected applications' bundle identifiers.

## Build from source

Requires Xcode with Swift 6.

```sh
Scripts/build-app.sh
open "dist/TrayNook Dev.app"
```

[Development](docs/DEVELOPMENT.md) · [Releasing](docs/RELEASING.md) · [MIT license](LICENSE)

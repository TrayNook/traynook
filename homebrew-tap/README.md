# TrayNook Homebrew tap

Prepared for `TrayNook/homebrew-tap`. The first stable TrayNook release will
create the cask automatically from its verified app ZIP and SHA-256 checksum.
Public releases default to free ad-hoc signing; notarization is optional. This is
an owner-maintained custom tap, separate from the official Homebrew Cask repository.

## Install

After the first stable release is published, run

```sh
brew tap traynook/tap
brew install traynook/tap/traynook
```

If macOS blocks opening an ad-hoc build, use **System Settings → Privacy &
Security → Open Anyway** after trying to open it; see
[Apple's instructions](https://support.apple.com/en-us/102445). Updates may require
Accessibility approval again.

TrayNook targets stable macOS majors receiving current Apple security updates.
Its technical minimum is macOS 13.0; older installations have no compatibility
guarantee. Release notes list exact tested environments.

## Update

```sh
brew update
brew upgrade --cask --greedy traynook/tap/traynook
```

The app also offers **Check for Updates…** in General and the tray context menu.
Automatic checks default on; automatic downloads default off. Only an explicit
**Install & Relaunch** starts installation. You can keep using Homebrew upgrades.

## Uninstall

Turn off **Launch at Login** in TrayNook Settings and quit TrayNook before running

```sh
brew uninstall --cask traynook/tap/traynook
```

To also erase saved layout and preferences, use

```sh
brew uninstall --cask --zap traynook/tap/traynook
```

The optional cleanup removes the saved layout and preferences belonging to
`io.github.mahenzon.TrayNook`. It currently leaves downloaded update caches in
`~/Library/Caches/io.github.mahenzon.TrayNook/Updates`.

## Maintenance

The source repository's Homebrew workflow generates `Casks/traynook.rb` for the
latest stable release and preserves every stable version as
`Casks/traynook@VERSION.rb`, following
[BroGlow's tap](https://github.com/BroGlow/homebrew-tap). App ZIPs and checksums
remain attached to their versioned releases in the source repository; the tap
stores installation definitions and their Git history.

To switch to a historical version, quit TrayNook, uninstall the currently
installed cask without `--zap`, and install the desired version, for example:

```sh
brew uninstall --cask traynook/tap/traynook
brew install --cask traynook/tap/traynook@1.0.0
```

Only one version can be installed at a time because every cask installs
`TrayNook.app`. To stay on an older version, turn off **Check automatically**
and **Automatically download updates** in TrayNook. Saved layout and preferences
are retained when uninstalling without `--zap`.

The first stable release creates the first versioned cask. Changes to generation
belong in the
[TrayNook source repository](https://github.com/TrayNook/traynook).

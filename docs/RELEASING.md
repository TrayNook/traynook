# Releasing TrayNook

Push a Git-signed version tag to prepare a **draft** GitHub Release containing the
Universal 2 app ZIP and its SHA-256 checksum. The default release is ad-hoc
signed and requires no paid Apple membership; notarization is an optional mode.
Stable releases also contain `appcast.xml`, whose enclosure signs that final ZIP
with Ed25519 for in-app updates. Review the draft and acceptance results before
publishing it.

## Repositories

The prepared layout uses the GitHub organization `TrayNook`, source repository
`TrayNook/traynook`, and tap repository `TrayNook/homebrew-tap`. The macOS bundle
identifier is `io.github.mahenzon.TrayNook`.

1. Create the organization and both public repositories. Use `master` as the
   default branch in both repositories.
2. Push this project to `TrayNook/traynook`. Enable GitHub Actions and GitHub
   Issues. Verify `https://github.com/TrayNook/traynook/issues/new` opens the
   issue composer used by **Settings → General → Report a Problem…**. The app
   opens the browser without attaching diagnostics; users review and paste them
   deliberately.
3. Copy the local tap seed into a clone of `TrayNook/homebrew-tap` and push it.
   Run these commands from this project's root.

   ```sh
   tap_dir=$(mktemp -d)
   git clone git@github.com:TrayNook/homebrew-tap.git "$tap_dir"
   cp -R homebrew-tap/. "$tap_dir/"
   git -C "$tap_dir" add .github README.md LICENSE
   git -C "$tap_dir" commit -m "Prepare TrayNook Homebrew tap"
   git -C "$tap_dir" push origin HEAD:master
   ```

The seed contains the tap README, license, and CI. The Homebrew workflow creates
`Casks/traynook.rb` and `Casks/traynook@VERSION.rb` from each stable release's
verified ZIP and checksum. The current cask follows the latest stable version;
versioned casks are retained permanently, as in
[BroGlow's tap](https://github.com/BroGlow/homebrew-tap). App archives and checksums
stay in the source repository's GitHub Releases; the tap stores cask definitions
and their Git history.

## Distribution modes

Public prereleases and stable releases default to **free ad-hoc distribution**
through GitHub Releases and the owner-maintained `TrayNook/homebrew-tap`. No paid
Apple Developer Program membership, Developer ID certificate, or notarization
credential is required for that mode. The app and its nested code retain ad-hoc
signatures; update archives retain their independent Ed25519 signatures.

| `TRAYNOOK_DISTRIBUTION` | App verification | Apple credentials |
| --- | --- | --- |
| `adhoc` (default) | Universal 2 packaging, strict code-signature integrity, SHA-256, and Ed25519 update signature | None |
| `notarized` | Developer ID, Hardened Runtime, notarization, stapled ticket, and Gatekeeper acceptance, plus the same integrity checks | Paid Apple Developer Program identity and notarization credentials |

Packaging records the actual mode in the app's `TrayNookDistribution` Info.plist
key. Release notes identify the mode and exact environments tested. Ad-hoc
releases must not claim notarization or automatic Gatekeeper acceptance.
If macOS blocks the app, the user can approve it manually using **System Settings
→ Privacy & Security → Open Anyway** after attempting to open it; see
[Apple's opening instructions](https://support.apple.com/en-us/102445).
Ad-hoc signature changes can require Accessibility approval again after an update.
Do not disable Gatekeeper or SIP, or remove quarantine attributes.

The custom tap is distinct from the official `homebrew/cask` repository.
[Official Cask acceptance](https://docs.brew.sh/Acceptable-Casks) requires passing
its Gatekeeper checks; the free custom-tap lane does not claim official acceptance.
Developer ID and notarization remain an optional paid route for standard
Gatekeeper acceptance; see [Apple's Developer ID guide](https://developer.apple.com/developer-id/).

## GitHub setup

1. Enable GitHub Actions in `TrayNook/traynook`. Merge the workflows and release
   scripts into the default branch. Register your Git signing public key with
   your GitHub account so GitHub can verify signed annotated tags. Git tag
   signatures are separate from app signing and Ed25519 update signatures.
2. Add a repository tag ruleset for `v*`. Restrict tag creation to release
   maintainers and prevent tag updates and deletion. The workflow also requires
   a GitHub-verified tag signature pointing directly to a commit in the default
   branch's history.
3. Create a GitHub environment named **`release`**. Allow deployments only from
   tags matching `v*`, add a required maintainer reviewer, and prevent self-review
   where available. Keep update-signing secrets here; Apple secrets, when used,
   belong here too, never in scopes available to pull requests.
4. Optionally set the repository or `release` environment **variable**
   `TRAYNOOK_DISTRIBUTION` to `adhoc` or `notarized`. An unset variable selects
   `adhoc`. Configure the update keys below in both modes. Configure Apple
   credentials only when deliberately choosing `notarized`.

The built-in `GITHUB_TOKEN` creates the draft and uploads assets; no personal
access token is needed for this source repository. Publishing the reviewed draft
is a separate manual action, including the first public release.

## Optional Apple setup for notarized releases

Skip this section for the default `adhoc` mode.

1. Export your **Developer ID Application** certificate together with its private
   key from Keychain Access as a password-protected `.p12`. Create a **team** App
   Store Connect API key for notarization and download its `.p8` file. This
   workflow uses the team key's issuer ID; individual API keys are not supported
   by this configuration.
2. Add the following environment secrets in GitHub Settings → Environments →
   `release`. Copy base64 file contents directly to the secret field, for example
   with `base64 -i /path/to/export.p12 | pbcopy`; use the same command for `.p8`.
   Base64 is only an encoding: keep both source files and encoded values private.

| Environment secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64 of the `.p12` containing exactly one valid Developer ID Application identity and its private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Base64 of the team API key's `.p8` file |
| `APP_STORE_CONNECT_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Team API key issuer ID |

Only the `notarized` job path imports Apple signing credentials into a disposable
keychain on a GitHub-hosted runner. Cleanup removes that keychain and decoded
credential files on success or failure. The `adhoc` path does not import Apple
credentials or create a signing keychain. Never commit certificates, private
keys, passwords, or certificate identifiers.

## Update-signing setup

Configure update trust before public 1.0.0. Sparkle's Ed25519 archive-signing key
is required in both distribution modes and is independent of optional Apple
Developer ID and notarization credentials. Use the tools from the pinned Sparkle
2.10.0 artifact after resolving the Swift package. See
[Sparkle's setup guide](https://sparkle-project.org/documentation/).

Run the following locally as the release maintainer. `generate_keys` creates a
key in the login Keychain on first use and otherwise reuses the existing key for
this account. Its output is the public key, not the private key.

```sh
sparkle_tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_keys" --account io.github.mahenzon.TrayNook
```

Copy the printed public key into the repository or `release` environment
**variable** `TRAYNOOK_UPDATE_PUBLIC_KEY`. Packaging embeds it as `SUPublicEDKey`.
Back up the private key securely. To give the protected GitHub release job the
same private key without printing it, export it into a restricted file outside
the repository and upload the file directly:

```sh
umask 077
update_key_dir="$HOME/Library/Application Support/TrayNook Release"
mkdir -p "$update_key_dir"
"$sparkle_tools/generate_keys" --account io.github.mahenzon.TrayNook \
  -x "$update_key_dir/ed25519-private-key"
gh secret set TRAYNOOK_UPDATE_PRIVATE_KEY --repo TrayNook/traynook \
  --env release < "$update_key_dir/ed25519-private-key"
```

`TRAYNOOK_UPDATE_PRIVATE_KEY` is a protected `release` environment **secret**.
Use the exported base64 text file contents as-is: neither decode them to binary
nor add another base64 layer. `sign_update --ed-key-file` expects that text. Never echo,
log, paste into a command argument, or commit the private key. Keep its backup
outside the repository. The release job writes a temporary restricted key file,
signs the exact final ZIP, and removes the temporary file during cleanup.

For manual archive signing, Sparkle can use the Keychain directly or the
private file. Keep both output streams private: malformed-key diagnostics can
contain secret material. These commands save output in the restricted directory:

```sh
"$sparkle_tools/sign_update" --account io.github.mahenzon.TrayNook \
  dist/TrayNook-1.0.0.zip > "$update_key_dir/keychain-signature.out" 2> "$update_key_dir/keychain-signature.err"
"$sparkle_tools/sign_update" --ed-key-file "$update_key_dir/ed25519-private-key" \
  dist/TrayNook-1.0.0.zip > "$update_key_dir/file-signature.out" 2> "$update_key_dir/file-signature.err"
```

Do not share these captured files. The release pipeline invokes `sign_update`
with both streams captured, validates the signature, and independently verifies
it against `TRAYNOOK_UPDATE_PUBLIC_KEY`; failures expose a generic message.

The workflow publishes `appcast.xml` alongside the stable ZIP and checksum. The
app uses the pinned HTTPS feed at
`https://github.com/TrayNook/traynook/releases/latest/download/appcast.xml`.
Prereleases do not advance this stable feed. Before publishing, confirm the
appcast references that release's immutable versioned ZIP URL, numeric build,
minimum OS `13.0`, Ed25519 signature, and exact length. Its description comes from
`CHANGELOG.md`; update that file before tagging. The appcast is served over
pinned HTTPS; the signature covers the archive payload. Never replace a published
ZIP or reuse a build number; issue a new version. The SHA-256 checksum serves manual and
Homebrew verification; it does not replace the updater's Ed25519 signature.

## Prepare a release

1. Update `CHANGELOG.md` and merge the intended changes into the default branch.
   Complete the applicable native acceptance checks from [MVP_REPORT.md](MVP_REPORT.md). Follow the
   best-effort compatibility policy in
   [ADR 0002](adr/0002-support-current-stable-macos-releases.md): target all stable
   macOS majors receiving current Apple security updates, retain the technical
   minimum of macOS 13.0 and Universal 2 packaging, record the environments
   actually tested, and do not certify untested systems. Older installations
   outside the support target carry no compatibility guarantee. A full
   maintained-macOS matrix is not a release gate. Start with an alpha while other
   public-release acceptance remains incomplete.
2. Create a signed annotated tag on the intended commit and push it. For example,
   after checking out and updating the default branch:

   ```sh
   git tag -s v1.0.0-alpha.1 -m "TrayNook 1.0.0 alpha 1"
   git push origin v1.0.0-alpha.1
   ```

   Accepted forms are `vMAJOR.MINOR.PATCH`, `vMAJOR.MINOR.PATCH-alpha.N`,
   `-beta.N`, and `-rc.N`. Numeric components have no leading zeros and `N` is
   positive. Lightweight tags and tags whose signatures GitHub cannot verify
   are rejected before the signing job starts.
3. Open GitHub Actions → **Release**, check tag validation, and approve the
   `release` environment deployment. The signing job tests, cross-compiles
   `arm64` and `x86_64`, combines them into a Universal 2 app, ad-hoc signs and
   verifies it by default, smoke tests, signs the final stable ZIP with the
   update key, and creates the draft release, including an appcast for stable
   versions. Explicit `notarized` mode instead uses Developer ID with Hardened
   Runtime, notarizes, staples, and checks Gatekeeper before ZIP signing.
4. Open the draft linked in the run summary. Review the stable appcast when
   present. Download the ZIP and checksum; run
   `shasum -a 256 -c TrayNook-1.0.0-alpha.1.zip.sha256` in their directory. Test
   the downloaded app on available systems and record exact macOS builds,
   architectures, hardware, display configurations, acceptance results, and known
   limitations in the release notes. State the actual `TrayNookDistribution`
   mode and that compatibility is best effort. For ad-hoc releases, explain
   manual Open Anyway approval and possible Accessibility reapproval after updates.
   Verify manual check, changelog, background-check opt-out, signature failure,
   cached download, and explicit Install & Relaunch consent. Before that approval,
   quitting or crashing must not install a downloaded update. After approval, the
   selected installation and relaunch proceed without a second Sparkle confirmation;
   macOS authorization may still be required.
5. Publish the reviewed draft from GitHub Releases. Alpha, beta, and RC tags are
   marked as prereleases automatically. All release types list only actual test
   coverage; untested OS/hardware combinations do not block publication.
   Publishing a stable release starts the Homebrew workflow described below.

For `v1.0.0-alpha.1`, the assets are `TrayNook-1.0.0-alpha.1.zip` and
`TrayNook-1.0.0-alpha.1.zip.sha256`. The app's marketing version is `1.0.0`;
its numeric build is the **Release workflow's run number**. Preserve this workflow
and its run sequence. Before distributing from a replacement workflow or a
repository with previous public builds, ensure its run number exceeds the last
distributed build. Local development builds use a separate bundle identity.

## CI coverage and reruns

- [ci.yaml](../.github/workflows/ci.yaml) runs packaging regression checks, Swift
  tests, a development build, and the packaged app smoke test on `macos-15` for
  branch pushes, pull requests, and manual runs. It uploads no app artifacts and
  needs no Apple or update-signing secrets.
- [release.yaml](../.github/workflows/release.yaml) runs only on version-tag
  pushes. It validates the tag without Apple credentials, then builds the exact
  validated commit in the protected release environment with the update-signing
  credentials. Apple credentials are required only in `notarized` mode.
  Hosted-runner success does not establish native Accessibility, Screen Recording, Intel execution, or
  compatibility on untested OS/hardware combinations.
- Rerun a failed **Release** run from Actions after fixing credentials or a
  transient service problem. Reruns retain the same build number. An
  existing draft receives replacement ZIP/checksum and stable appcast assets
  and retains edited notes. A published release's assets are never replaced; release changed code
  under a new version tag, with a new workflow run and build number.

## Homebrew setup

1. Create a fine-grained personal access token owned by your GitHub account,
   with `TrayNook` as resource owner. Select only `homebrew-tap` and grant
   **Contents → Read and write**. Complete organization approval if required.
2. In `TrayNook/traynook`, create an environment named **`homebrew`**. Add the
   token there as the secret **`HOMEBREW_TAP_TOKEN`**. Allow this environment
   from the default branch and protected `v*` release tags. Add a maintainer
   reviewer if tap publication should require approval.
3. Ensure the token's account can push to the tap's `master` branch. If a tap
   ruleset requires pull requests, allow this automation account to bypass it
   for generated cask updates.

The [Homebrew workflow](../.github/workflows/homebrew-tap.yaml) runs when a
stable GitHub release is published. It checks that the source repository is
public, the release is published, and its signed annotated tag is verified by
GitHub and points into the default branch history. It downloads the ZIP and
checksum, verifies their SHA-256, and generates both the latest cask and a
versioned `traynook@VERSION` cask.

A macOS runner creates a temporary tap, trusts it with
`brew trust --tap traynook/ci`, and runs the custom cask checks. Both modes verify
the SHA-256, Universal 2 app, and strict code-signature integrity. The app's
actual `TrayNookDistribution` value selects additional checks: only a `notarized`
artifact must pass stapler and Gatekeeper checks. Ad-hoc artifacts retain the
normal macOS approval flow; the workflow does not remove quarantine or disable
security protections. After the applicable checks pass, the publish job updates
`TrayNook/homebrew-tap`. The token is available only to the publish job.

The formula-name conflict check uses Homebrew's official API. The remaining
strict audit runs with `--except token_conflicts` to avoid downloading the full
`homebrew/core` Git history for that same lookup. API failures stop the check.

Published alpha, beta, and RC releases stay on GitHub. The stable cask advances
by numeric version. Each stable version also remains installable through its
own versioned cask. Existing versioned files are never removed or replaced with
different content. An older version or a changed checksum for the same version
fails publication. Identical cask content finishes without a new commit.
Concurrent tap updates cause a rejected push that can be retried with a fresh run.

### Preview or retry an existing release

Open Actions → **Homebrew tap → Run workflow** on the default branch. Enter a
published stable tag such as `v1.0.0`. Leave **publish** off to run the checks
and download the generated cask artifact. Enable **publish** to update the tap.
Use a new dispatch after changing the workflow so the new run uses the fix.

After the first successful stable publication, users can install and upgrade.

```sh
brew tap traynook/tap
brew install traynook
brew upgrade --greedy traynook
```

To switch to a historical version, quit TrayNook and uninstall the installed
cask without `--zap` before installing, for example,
`brew install traynook@1.0.0`. Both casks install the same
`TrayNook.app`, so they cannot coexist. Turn off the app's automatic update checks
and downloads when intentionally remaining on an older version. Homebrew
uninstallation without `--zap` preserves saved layout and preferences.

Before uninstalling, turn off Launch at Login in TrayNook Settings and quit the
app. Then run `brew uninstall traynook`. Adding `--zap`
erases the production layout and preferences; it currently leaves downloaded
update caches in `~/Library/Caches/io.github.mahenzon.TrayNook/Updates`. Reset
Layout also preserves updater preferences and caches; the app has no full-data
erase command. macOS privacy approvals are managed in System Settings.

### Generate a cask locally

Given a signed stable ZIP and its checksum from `Scripts/release.sh`, run

```sh
python3 Scripts/homebrew-cask.py --version 1.0.0 \
  --archive dist/TrayNook-1.0.0.zip \
  --checksum dist/TrayNook-1.0.0.zip.sha256 \
  --output homebrew-tap/Casks/traynook.rb \
  --current-cask homebrew-tap/Casks/traynook.rb
python3 Scripts/homebrew-cask.py --version 1.0.0 --versioned \
  --archive dist/TrayNook-1.0.0.zip \
  --checksum dist/TrayNook-1.0.0.zip.sha256 \
  --output homebrew-tap/Casks/traynook@1.0.0.rb \
  --current-cask homebrew-tap/Casks/traynook@1.0.0.rb
Scripts/test-homebrew-cask.sh
```

This verifies the archive and writes an exact SHA-256 into both installable casks.
The current-cask checks protect existing versions during generation. Keep all
previous `traynook@VERSION.rb` files when committing the new pair.

## Local release equivalent

With the update keys configured above, the default local release is free and
ad-hoc signed:

```sh
export TRAYNOOK_UPDATE_PUBLIC_KEY="$("$sparkle_tools/generate_keys" --account io.github.mahenzon.TrayNook -p)"
export TRAYNOOK_UPDATE_PRIVATE_KEY_FILE="$update_key_dir/ed25519-private-key"
TRAYNOOK_VERSION=1.0.0 TRAYNOOK_BUILD=2 Scripts/release.sh
```

Set `TRAYNOOK_DISTRIBUTION=adhoc` explicitly if desired. For the optional paid
mode, set `TRAYNOOK_DISTRIBUTION=notarized` and provide
`TRAYNOOK_SIGNING_IDENTITY` plus `TRAYNOOK_NOTARY_PROFILE`, or use the existing
positional form:

```sh
TRAYNOOK_DISTRIBUTION=notarized Scripts/release.sh 'Developer ID Application: …' notary-profile
```

When `TRAYNOOK_DISTRIBUTION` is unset, supplying the legacy identity/profile
arguments selects `notarized`; no arguments selects `adhoc`. An explicitly set
mode takes precedence.

For a prerelease, also set `TRAYNOOK_RELEASE_VERSION=1.0.0-alpha.1`.
`TRAYNOOK_VERSION` stays numeric and must match the prerelease's base version.
`TRAYNOOK_NOTARY_KEYCHAIN` optionally selects the keychain containing the stored
notarytool profile in `notarized` mode. `TRAYNOOK_UPDATE_PRIVATE_KEY_FILE` selects
the restricted Sparkle-exported Ed25519 private-key text file, without base64 decoding.
Every production build requires the public key; local stable releases also
require the private-key file, while local prereleases do not publish an appcast.
The GitHub workflow requires the protected private-key secret for all release
runs. Local stable packaging produces the final ZIP, checksum,
and appcast in `dist/` without publishing. A configured public key is required;
never substitute the private key into `TRAYNOOK_UPDATE_PUBLIC_KEY`.

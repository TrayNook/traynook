# Releasing TrayNook with GitHub Actions

Push a signed version tag to prepare a **draft** GitHub Release containing the
Developer ID signed, notarized, stapled Universal 2 app ZIP and its SHA-256
checksum. Review the draft and acceptance results before publishing it.

## One-time GitHub and Apple setup

1. Enable GitHub Actions in `mahenzon/TrayNook`. Merge the workflows and release
   scripts into the default branch. Register your Git signing public key with
   your GitHub account so GitHub can verify signed annotated tags.
2. Add a repository tag ruleset for `v*`. Restrict tag creation to release
   maintainers and prevent tag updates and deletion. The workflow also requires
   a GitHub-verified tag signature pointing directly to a commit in the default
   branch's history.
3. Create a GitHub environment named **`release`**. Allow deployments only from
   tags matching `v*`, add a required maintainer reviewer, and prevent self-review
   where available. Keep the Apple secrets in this environment, never in
   repository-wide or organization-wide secrets available to pull requests.
4. Export your **Developer ID Application** certificate together with its private
   key from Keychain Access as a password-protected `.p12`. Create a **team** App
   Store Connect API key for notarization and download its `.p8` file. This
   workflow uses the team key's issuer ID; individual API keys are not supported
   by this configuration.
5. Add the following environment secrets in GitHub Settings → Environments →
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

The built-in `GITHUB_TOKEN` creates the draft and uploads assets; no personal
access token is needed. Signing credentials are imported into a disposable
keychain on a GitHub-hosted runner. The cleanup step removes that keychain and
the decoded credential files on success or failure. Do not commit certificates,
private keys, passwords, or certificate identifiers to this repository.

## Prepare a release

1. Merge the intended changes into the default branch. Complete the applicable
   native acceptance checks from [MVP_REPORT.md](MVP_REPORT.md) and
   [ADR 0002](adr/0002-support-current-stable-macos-releases.md). Start with an
   alpha while public-release acceptance remains incomplete.
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
   `arm64` and `x86_64`, combines them into a Universal 2 app, signs with Hardened
   Runtime, smoke tests, notarizes with Apple, staples the ticket, verifies
   Gatekeeper acceptance, and creates the draft release.
4. Open the draft linked in the run summary. Download the ZIP and checksum; run
   `shasum -a 256 -c TrayNook-1.0.0-alpha.1.zip.sha256` in their directory. Test
   the downloaded app on the claimed systems and record exact macOS builds,
   hardware, acceptance results, and known limitations in the release notes.
5. Publish the reviewed draft from GitHub Releases. Alpha, beta, and RC tags are
   marked as prereleases automatically. RC and stable releases require the full
   currently maintained macOS matrix; alpha/beta notes list their exact tested
   subset. Homebrew publication remains a separate task.

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
  needs no Apple secrets.
- [release.yaml](../.github/workflows/release.yaml) runs only on version-tag
  pushes. It validates the tag without Apple credentials, then builds the exact
  validated commit in the protected release environment. Hosted-runner success
  does not establish native Accessibility, Screen Recording, Intel execution, or
  the supported OS/hardware acceptance matrix.
- Rerun a failed **Release** run from Actions after fixing credentials or a
  transient Apple service problem. Reruns retain the same build number. An
  existing draft receives replacement ZIP/checksum assets and retains edited
  notes. A published release's assets are never replaced; release changed code
  under a new version tag, with a new workflow run and build number.

## Local release equivalent

The existing local release command remains available:

```sh
TRAYNOOK_VERSION=1.0.0 TRAYNOOK_BUILD=2 \
  Scripts/release.sh 'Developer ID Application: …' notary-profile
```

For a prerelease, also set `TRAYNOOK_RELEASE_VERSION=1.0.0-alpha.1`.
`TRAYNOOK_VERSION` stays numeric and must match the prerelease's base version.
`TRAYNOOK_NOTARY_KEYCHAIN` optionally selects the keychain containing the stored
notarytool profile. Local packaging produces files in `dist/` without publishing.

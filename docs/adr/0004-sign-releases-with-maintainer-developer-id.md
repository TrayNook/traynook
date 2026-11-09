---
status: accepted
---

# Distribute free ad-hoc releases; offer notarization as an optional mode

Updated decision, 9 November 2026: public TrayNook prereleases and stable releases default to **ad-hoc signing** for GitHub Releases and the owner-maintained Homebrew tap. This free distribution mode requires no paid Apple Developer Program membership or Apple signing credentials. It supersedes the earlier intent to require the maintainer's Developer ID and notarization for every public release; that approach remains available as an explicit optional mode.

`TRAYNOOK_DISTRIBUTION=adhoc|notarized` selects the mode and defaults to `adhoc`. Packaging embeds the actual mode in `TrayNookDistribution`. The `notarized` option requires the maintainer's paid Apple Developer Program identity, Developer ID signing, Hardened Runtime, notarization, a stapled ticket, and Gatekeeper verification. Local development retains its separate bundle identity.

Both modes preserve the permanent public bundle identifier, strict code-signature integrity, SHA-256 checksums, GitHub-verified signed release tags, protected release secrets, manual draft review, and independent Ed25519 update signing. The Ed25519 private key is required for stable appcast signing and never becomes optional merely because Apple credentials are absent. The public maintainer and copyright name remains Suren Khorenyan. Secrets and Apple certificate identifiers are never committed.

Ad-hoc releases do not claim notarization or automatic Gatekeeper acceptance. If blocked, the user may manually approve the app through macOS **Open Anyway** as described by [Apple](https://support.apple.com/en-us/102445). Accessibility approval may need renewal after ad-hoc updates; keeping the bundle identifier and update key does not guarantee continuity of privacy grants. Never disable Gatekeeper or SIP or remove quarantine attributes.

The custom tap does not imply acceptance in the official Homebrew Cask repository, whose [security requirements](https://docs.brew.sh/Acceptable-Casks) still apply. A later distribution-mode or Apple signing-team change must be tested for update trust and privacy-grant migration rather than made silently. See [Releasing](../RELEASING.md) for mode selection and [update-signing setup](../RELEASING.md#update-signing-setup).

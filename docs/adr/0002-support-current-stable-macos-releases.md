---
status: accepted
---

# Target stable macOS versions receiving current Apple security updates

TrayNook's support target is all stable macOS major versions receiving current security updates from Apple, using [Apple security releases](https://support.apple.com/en-us/100100) as the primary source at release time. This is a rolling policy, not a permanently fixed list of OS names. The technical deployment minimum is macOS 13.0; older versions outside that support target may install and run, but carry no compatibility guarantee. TrayNook ships a Universal 2 build for Intel and Apple silicon. Compatibility is best effort: the deployment target and bundled architectures do not certify every macOS version or hardware combination. Every public prerelease and stable release records the exact macOS builds, architectures, hardware, and relevant display configurations actually tested, together with results and known limitations.

The 9 November 2026 release decision replaces the former requirement to test every maintained stable macOS major before shipping. Untested OS/hardware combinations do not block 1.0.0 and must not be described as certified. Compatibility issues are investigated when users report them through [GitHub Issues](https://github.com/TrayNook/traynook/issues). Beta macOS versions may be tested opportunistically but carry no compatibility guarantee.

Release checks on available environments cover discovery of manageable items, all three Settings Placement Lanes, usable Dropdown proxies with an app-icon fallback, primary and secondary native handoff, and safe restoration. Runtime capability checks and visible recovery remain required; removing the full environment matrix does not authorize unknown private behavior or bypassing macOS privacy controls.

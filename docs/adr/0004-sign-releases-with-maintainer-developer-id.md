---
status: accepted
---

# Sign releases with the maintainer's personal Developer ID

Every public TrayNook prerelease and stable release is signed and notarized with the maintainer's personal Apple Developer Program identity and permanent bundle identifier. Local development and pull-request CI builds may remain unsigned, but they are not public release assets. The public maintainer and copyright name is Suren Khorenyan; certificate identifiers and credentials are not recorded in project documentation, and release secrets remain protected and available only to trusted tag workflows. Because changing the signing team later can affect update trust and macOS privacy grants, any future transfer to an organization requires an explicit migration plan rather than an unannounced certificate swap.

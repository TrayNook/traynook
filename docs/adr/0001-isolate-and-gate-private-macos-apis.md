---
status: accepted
---

# Isolate and gate private macOS APIs

TrayNook may use undocumented CGS/SkyLight APIs only after a prototype proves that public and tested deprecated-public APIs cannot provide a committed capability. Every private call lives behind one compatibility boundary and is enabled only after runtime capability checks and testing on the supported macOS matrix. If a symbol or verified behavior is unavailable, unknown, or fails, TrayNook does not call that path: it disables or degrades only the affected feature, keeps items in a safe visible state, and explains the limitation instead of crashing. Private APIs never justify bypassing SIP or macOS privacy controls.

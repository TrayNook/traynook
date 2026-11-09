---
status: accepted
---

# Lock the TrayNook release identity

TrayNook's canonical GitHub organization is `TrayNook`, its intended public repository is `github.com/TrayNook/traynook`, and its permanent public bundle identifier is `io.github.mahenzon.TrayNook`. Every permission-bearing public preview and stable build uses this same bundle identifier and forms one installation/data lane. Local development uses display name `TrayNook Dev` and bundle identifier `io.github.mahenzon.TrayNook.dev`, isolating preferences and privacy grants. Pull-request CI tests local builds. The GitHub organization hosts the source repository and `TrayNook/homebrew-tap`. The existing macOS bundle identifier preserves one installation/data lane through this hosting change. Ad-hoc signature changes can still require renewed Accessibility approval after updates; the bundle identifier alone does not guarantee privacy-grant continuity.

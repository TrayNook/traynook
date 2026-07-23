---
status: accepted
---

# Lock the TrayNook release identity

TrayNook's canonical GitHub owner is `mahenzon`, its intended public repository is `github.com/mahenzon/TrayNook`, and its permanent public bundle identifier is `io.github.mahenzon.TrayNook`. Every permission-bearing public preview and stable build uses this same bundle identifier and forms one installation/data lane. Local development uses display name `TrayNook Dev` and bundle identifier `io.github.mahenzon.TrayNook.dev`, isolating preferences and privacy grants; pull-request CI never publishes a downloadable unsigned app. This avoids fragmenting public macOS privacy grants, Launch at Login registration, signing continuity, and upgrades while preventing development builds from replacing production. Changing either identity after distribution begins requires an explicit migration rather than an ordinary rename.

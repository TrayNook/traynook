---
status: accepted
---

# Use Proxy Items and native Interaction Handoff

TrayNook never claims to embed or take ownership of another application's Source Item. Dropdown displays a visual Proxy Item; activation temporarily promotes the real Source Item into usable Menu Bar space, reproduces the requested primary or secondary click, and lets the source application present its genuine interface. That menu, popover, or window anchors to the real temporary Menu Bar position—placed near the Launcher when macOS permits—not necessarily beneath the clicked proxy. This location trade-off is accepted because preserving native source-app behavior is more important than imitating the interface inside TrayNook.

The hidden section stays collapsed during normal handoff. Revealing all sources
would recreate the overflow behind the notch that Dropdown exists to solve.
Verify room for the selected Source Item before moving it, verify its visible
position before activating it, and return only that item after observed native
menu dismissal. An unavailable safe position must produce an explanation rather
than silently switching to whole-section reveal. Explicit Show Items and recovery
from an unsafe inventory or changed display remain separate actions.

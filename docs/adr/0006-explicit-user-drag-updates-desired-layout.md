---
status: accepted
---

# Treat explicit user dragging as authoritative

When TrayNook can confidently identify an explicit user Command-drag within the physical Menu Bar, the resulting valid order immediately updates Desired Layout instead of being reverted to the previous Settings order. A deliberate valid crossing between Menu Bar and Dropdown also updates Placement immediately. This includes reordering TrayNook's Launcher while it remains in Menu Bar Zone and dragging a Source Item temporarily promoted for Interaction Handoff; the latter ends handoff and suppresses restoration of the pre-handoff layout. Invalid placement destinations for the Launcher or a Protected Item are rejected. Ambiguous app- or system-driven reshuffles do not silently change Placement, so TrayNook reconciles them conservatively and fails visible when intent cannot be determined.

After a clean Quit, TrayNook records the final native Menu Bar order only when it was observed confidently; native notch clipping does not invalidate an otherwise trustworthy native order. If the next launch observes a different order, it treats the delta as offline user intent: it adopts the new relative order, retains each known item's saved Placement, defaults new items to Menu Bar, and then reapplies the three Placements. This inference is not made after an unclean or uncertain termination because that baseline is not trustworthy.

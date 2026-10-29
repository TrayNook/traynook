---
status: accepted
---

# Geometry follows the active menu-bar row

Decided 2026-10-28 after the first native run on two displays.

## Observation

With more than one display, each `NSStatusItem` owns one `NSStatusBarWindow` per
display; `button.window` stays on the home display. The Accessibility extras
row (`AXExtrasMenuBar` item frames) is reported for the display that holds the
active application's key window and jumps whenever the user activates a window
on another display. TrayNook computed all geometry from its launcher's own
window and compared it with AX frames from whichever display was active, so a
click on the other display made every decision fail ("native window cannot be
identified safely").

## Decision

`NativeMenuBarController.noteInventory` records the display containing the
latest inventory's onscreen AX frames. `environment()` computes the safe area,
notch occlusion, display frame, and TrayNook's own launcher and separator
rects for that display; on a non-home display the rects come from TrayNook's
mirrored status windows (same width, button rect centered vertically). Every
operation still re-reads the environment before and after acting, so a display
switch mid-operation fails safely and reveals.

The environment retains these control windows' identifiers alongside their
rectangles. Single-item promotion and return use those same windows as anchors,
so validated geometry on another display cannot target the home display.

Status windows are matched to items only on the same menu-bar row, which drops
the other display's duplicates and status-level panels taller than twice the
item (DockDoor's preview). The concealing separator grows to the widest display
so hidden items leave every menu bar.

## Consequences

Drags happen on whichever display the user last worked on. On the user's notch
display the hidden side is under the notch, so a drag to the hidden side may
end clipped; that is accepted as success. Clipped Menu Bar items cannot be
dragged out there, but on a wider display the same items are visible and
draggable. A later option is to steer the row deliberately (a key window on
the widest display during Apply); not done.

# Hidden Bar source and Barbee behavior analysis

Research date: 22 July 2026.

## Scope and confidence

- **Hidden Bar** is open source. This analysis inspected `develop` commit [`0dde4b6`](https://github.com/dwarvesf/hidden/tree/0dde4b6882144309263ac465375971a5c39b492d), so its internal mechanism can be stated directly.
- **Barbee** is proprietary. Its internal implementation cannot be source-audited. The Barbee section separates current official screenshots and release notes, third-party observation, a historical developer explanation, and our inference.

## Hidden Bar: what the source actually does

### It owns boundaries, not other apps' items

Hidden Bar creates only two required status items and one optional status item:

| Hidden Bar item | Purpose |
| --- | --- |
| Expand/collapse item | The arrow the user clicks |
| Main separator item | A normal `NSStatusItem` displaying a line; its width creates the visible/hidden boundary |
| Optional always-hidden separator | A second width-controlled boundary for a third zone |

The objects and their initial lengths are visible in [`StatusBarController.swift` lines 18–26](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L18-L26). Images, actions, and stable autosave names are assigned at [lines 184–203](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L184-L203); the optional boundary is created at [lines 394–413](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L394-L413).

There is no API call that changes a foreign item's visibility. Hidden Bar does not enumerate, identify, capture, click, resize, reparent, or set properties on another app's status item.

### The exact hiding trick

For a left-to-right menu bar, the conceptual order from right toward left is:

```text
shown items | Hidden Bar arrow | main boundary | ordinarily hidden items
                                              | optional boundary | always-hidden items
```

The main boundary is normally about 20 points wide. To collapse, Hidden Bar changes only that status item's `length` to a large value: twice the widest attached screen, bounded between 500 and 10,000 points. AppKit then lays out the same ordered status items around that oversized item, pushing everything on its left outside usable screen space. The calculation and display-change handling are at [lines 150–173](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L150-L173).

Collapse sets the large length; expand restores the short length. Neither operation changes foreign order or ownership. See [collapse at lines 265–280](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L265-L280) and [expand at lines 281–294](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L281-L294).

Users create the zones themselves by holding Command and dragging real items around Hidden Bar's boundaries. Hidden Bar validates only the relative order of its own controls. It does not know which third-party items are in a zone. Its manual also notes that macOS normally inserts new items at the far left, which puts them into the hidden side by default; see [`MANUAL.md` lines 72–81](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/docs/MANUAL.md#L72-L81).

### Why this is elegant and crash-safe

Hidden Bar never moves foreign items to fabricated coordinates. When it quits or crashes, its process and oversized boundary disappear, and macOS can reflow the remaining real items. The source has no foreign-item restoration routine: Quit invokes normal application termination at [controller lines 345–360](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L345-L360).

It explicitly restores only its own controls after a user Command-drags them off the bar, by forcing their `isVisible` state; see the two required controls at [lines 176–182](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L176-L182) and the optional separator at [lines 397–407](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Features/StatusBar/StatusBarController.swift#L397-L407).

Because it controls only its own ordinary AppKit objects, the app remains sandboxed and needs neither Accessibility nor Screen Recording. See its [sandbox entitlement](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/hidden/Hidden.entitlements#L5-L6).

### Why it still fails at a notch

Expanding merely asks macOS to fit all real items back into the same single-row menu bar. Hidden Bar has no secondary window and no notch-safe relocation. When the right-hand segment cannot hold the items, some remain clipped or behind the notch. The project documents that limitation and identifies a separate spillover bar as the real solution in its [architecture notes](https://github.com/dwarvesf/hidden/blob/0dde4b6882144309263ac465375971a5c39b492d/docs/ARCHITECTURE.md#known-architectural-limits).

### What we can reuse

The large app-owned boundary is a strong candidate for our parking mechanism:

1. Keep Source Items assigned to Dropdown on one side of the boundary.
2. Inflate the boundary while idle, so the real items remain owned by their apps but outside usable menu-bar space.
3. Show representations of those items in our separate Dropdown.
4. If our app exits, its boundary disappears and macOS can reflow the real items.

This gives us group concealment and useful crash behavior from removal of our boundary. It does not guarantee restoration of foreign ordering or visibility after our own synthesized rearrangements, especially on an overcrowded notched bar. It also does **not** give us:

- an inventory or stable identity for parked items;
- images for the Dropdown;
- drag lanes in Settings;
- selective reveal of one item;
- click forwarding or native menu tracking;
- protection against a new item initially landing on the concealed side;
- a way to keep a source app's native interface anchored to a Proxy Item.

The conclusion is precise: Hidden Bar supplies a boundary primitive, not the Dropdown feature.

## Barbee: what public evidence shows

### The three-lane editor is real

Barbee's [current official App Store layout screenshot](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/64/5a/81/645a8160-7465-c981-2205-732bf49e2616/2.png/1286x804bb.webp) shows horizontal lanes named:

- **Shown Items**
- **Hidden Items**
- **Always Hidden Items**
- plus a separate **Special Item Library**

The same screen says items can be dragged to arrange them and teaches Command-drag in the physical menu bar. Barbee's [App Store release history](https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12) records repeated work on drag/drop sorting, icon discovery, unstable ordering, screenshot issues, image matching, multi-display behavior, and its helper. That history is useful evidence that the polished lane UI sits on top of a nontrivial compatibility engine.

Public reviews describe the semantics as expected:

- Shown Items ordinarily remain in the real menu bar.
- Hidden Items are available through normal reveal or Barbee's Enhanced secondary bar.
- Always Hidden Items are excluded from ordinary reveal and exist for apps that must keep running although the user rarely or never wants their item.

[Mac Fan's Barbee overview](https://macfan.book.mynavi.jp/article/49778/) independently describes classification into shown, hidden, and always-hidden items and shows the separate bar on a notched Mac.

### Its enhanced items are proxies

The strongest public implementation clue is a [2024 discussion posted by Barbee's developer](https://www.reddit.com/r/macapps/comments/1cku4ai). The developer explained that Enhanced mode needs Accessibility and Screen Recording, that the items in its extra menu bar are screen-captured rather than real, and confirmed that Enhanced mode rearranges menu-bar icons when one is used.

That explanation matches the platform constraint and our proposed model:

```text
real Source Item parked in system menu bar
        ↓ captured image
Proxy Item in separate panel
        ↓ click
real Source Item rearranged into usable system-menu-bar space
```

This is historical public evidence, not a source audit of Barbee 4.3. The current listing still mentions screenshot, icon-management, sorting, cursor, helper, and compatibility fixes, which is consistent with the same family of techniques but does not prove every current internal step.

### What Barbee proves—and does not prove

Barbee's current public UI demonstrates that users understand the lane editor. The developer's historical explanation and the public behavior reports support—but do not source-verify for the current release—the remaining mechanism:

- a visual lane editor for real menu-bar placement;
- a separate notch-safe bar made from captured representations;
- Accessibility and Screen Recording onboarding;
- temporary rearrangement for interaction;
- Launch at Login as part of a menu-bar manager.

It does not prove:

- that foreign Source Items are embedded in its panel;
- that all source-app menus and popovers behave identically;
- that the enhanced bar deliberately remains visible without overlap during every native interaction;
- that all current behavior uses public APIs;
- that its implementation can be copied—the product is proprietary.

Current and historical reviews report version-specific ordering, click, overlap, and permission issues. Those are evidence for our prototype matrix, not a reason to duplicate Barbee's much broader feature set.

## Implication for our design

Yes, Hidden Bar's trick can be part of a Dropdown implementation, and Barbee publicly demonstrates the missing proxy layer. The smallest credible combined mechanism is:

1. Use an app-owned boundary to define and park the Dropdown group.
2. Discover and identify the real Source Items around that boundary.
3. Capture their appearance into in-memory Proxy Items.
4. Render those proxies in a wrapped, transient Dropdown.
5. When a proxy is activated, create space in the real menu bar and temporarily promote the corresponding Source Item.
6. Let its owning app handle the native interaction.
7. Restore the Source Item after the interaction ends.

Steps 2–7 are precisely the complexity Hidden Bar avoids. Barbee historically demonstrated that this model can be shipped and that its described Enhanced bar used captured stand-ins, not foreign native status items; its current proprietary implementation remains unverified.

## Settings adaptation

We should copy Barbee's **lane interaction**, not its settings suite:

- horizontal ordered lanes;
- drag inside a lane to reorder;
- drag across lanes to change Placement;
- drag within the open Dropdown, plus a best-effort direct path between the physical menu bar and Dropdown; after workarounds are exhausted, Settings-lane dragging is the accepted cross-placement fallback;
- real item imagery and clear locked/error states;
- Command-drag remains compatible in the physical menu bar;
- contextual and keyboard “Move to…” actions as accessibility equivalents to the primary drag interaction, explicitly deferred to TrayNook 1.1.0;
- the Launcher's Placement is fixed to Menu Bar and it never receives a Proxy Item, while its order among Menu Bar items remains user-controlled.

Use product-specific labels rather than Barbee's collapse vocabulary:

- **Menu Bar** instead of Shown Items;
- **Dropdown** instead of Hidden Items;
- **Always Hidden** for items that appear in neither everyday access surface, while remaining manageable in Settings.

Always Hidden is now a committed third Placement. It must be included in identity, movement, restoration, onboarding, recovery, and testing—not treated as a cosmetic extra row. Its Source Items remain parked while TrayNook runs but receive no Proxy Item; safe Quit or recovery may reveal them in the Menu Bar.

The Dropdown itself begins with a fixed gear-icon Settings Button, first in visual and keyboard order. It is neither a Source Item nor a Proxy Item, never appears in a Placement Lane, and works without cross-app permissions. Launch at Login is a required 1.0.0 setting: default off, explicitly recommended once during onboarding, and never enabled without consent.

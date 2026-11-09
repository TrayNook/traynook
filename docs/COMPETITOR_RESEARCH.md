# Competitor research

Research date: 22 July 2026.

## Market conclusion

The second-bar category already exists. The opportunity is not a never-before-seen mechanism; it is a deliberately smaller product:

> Three explicit homes for menu-bar items—Menu Bar, Dropdown, and Always Hidden—with no automation, styling, or subscription.

Free/open source is not by itself unique: Ice, Thaw, and SaneBar are open source. The differentiator is the strict scope, understandable interaction model, recovery behavior, and small auditable codebase.

## Comparison

| Product | Model relevant to this project | Useful lesson | What this project omits |
| --- | --- | --- | --- |
| [Hidden Bar](https://github.com/dwarvesf/hidden) | App-owned separators use menu-bar geometry to push other items outside the visible area; it never controls a foreign item directly | Excellent small-product discipline; familiar Command-drag organization; removing the boundary offers a natural reveal path | Its collapse/off-screen-only surface is inaccessible behind a notch; no inventory, proxies, or Dropdown |
| [Ice](https://github.com/jordanbaird/Ice) | Separate Ice Bar with captured proxies and temporary native-item reveal, plus three visibility zones | Strong evidence for feasibility and a direct-manipulation layout editor | Search, profiles, hotkeys, styling, spacing, and other expansion |
| [Thaw](https://github.com/stonerl/Thaw) | Ice-derived second bar targeting recent macOS changes | Shows how rapidly OS-specific ownership and capture work can grow | GPL-derived implementation and broad compatibility machinery unless explicitly chosen |
| [SaneBar](https://github.com/sane-apps/SaneBar) | MIT open-source Icon Panel and Second Menu Bar with virtual click behavior | Evidence that a free/open second surface is useful; keyboard and accessibility considerations | Search, categories, profiles, modes, utilities, and launcher-like scope |
| [Barbee](https://apps.apple.com/us/app/barbee-hide-menu-bar-items/id1548711022?mt=12) | Proprietary product with current Shown/Hidden/Always Hidden drag lanes; its developer historically described the Enhanced secondary bar as screen-captured proxies | Current evidence for the horizontal lane editor and historical evidence for the proxy-plus-rearrangement mechanism | Long scrolling/customized bar, third state, feature suite, cloud features, and commercial purchase model. The current listing offers annual and lifetime in-app purchases, so it is not subscription-only today |
| [iBar Pro](https://apps.apple.com/id/app/ibar-pro-menubar-control-tool/id6737150304?mt=12) | Aggregated panel; its listing describes temporarily restoring an item to the real menu bar for native interaction | Confirms Interaction Handoff as a practical fallback | Visible promotion delays and feature growth beyond TrayNook's narrow placement model |
| [Bartender](https://www.macbartender.com/Bartender5/) and [Tuck](https://usetuck.com/) | Commercial management suites with secondary surfaces | Validate demand across notch and non-notch Macs | Rules, modes, styling, search, and suite behavior |
| [Dozer](https://github.com/Mortennn/Dozer) | Very small open-source hider | Tiny preferences and narrow communication | No notch-safe secondary home |

## Positioning guardrails

The v1 product remains distinct only if it keeps all of these constraints:

- exactly three placements: Menu Bar, Dropdown, and Always Hidden;
- a transient Dropdown, not a searchable launcher or persistent second desktop bar;
- manual placement, not automatic policies;
- source-app-native interaction where feasible, not reimplemented app actions;
- one global layout, not modes or per-display profiles;
- system appearance, not a theme editor;
- recovery and permission transparency as core behavior;
- no accounts, sync, analytics, or network dependency for core layout management; signed updates use the narrowly scoped [update policy](DECISIONS.md#networking-and-updates).

## UX patterns worth retaining

- Barbee's horizontal drag lanes are a clearer organizer than teaching separators alone. Use Menu Bar, Dropdown, and Always Hidden labels.
- The Launcher's Placement must be visibly fixed to Menu Bar while its order remains draggable.
- Dragging is the 1.0.0 layout interaction; keyboard and contextual **Move to…** accessibility equivalents are explicitly deferred to 1.1.0.
- Row Capacity is a configurable logical maximum, defaulting to 10 and counting the gear; physical display width may force an earlier wrap because Source Items can contain text or changing values.
- New and uncertain items should fail visible in the real menu bar.
- A real native interaction may require temporary promotion to the system bar. This must be explained by behavior, not marketed as in-panel embedding.

## Strategic caution

Keeping a source menu native while the Dropdown remains simultaneously visible is stronger than the behavior demonstrated by examined open-source projects. TrayNook will attempt it and investigate workarounds first; if none is reliable, the accepted fallback is to hide the Dropdown temporarily and resume it after the native interaction.

See [Hidden Bar source and Barbee behavior analysis](REFERENCE_ANALYSIS.md) for exact source permalinks, the current official Barbee lane screenshot, and the developer-reported historical evidence that Barbee's Enhanced items were captured proxies rather than embedded foreign status items.

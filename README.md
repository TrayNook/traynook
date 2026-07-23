# TrayNook — design workspace

This repository contains the research and product-design workspace plus a
disposable Gate A inventory/identity spike. No production application code has
been written yet.

The selected product name is **TrayNook**, pending final trademark and release-surface clearance. The intended first public version is **1.0.0**.

The canonical GitHub owner is **mahenzon**; the intended public repository is `github.com/mahenzon/TrayNook`.

Permanent bundle identifier: `io.github.mahenzon.TrayNook`.

Planned Homebrew install command: `brew install --cask mahenzon/tap/traynook`.

Direct releases use a signed and notarized `TrayNook.app` ZIP plus its SHA-256 checksum; TrayNook 1.0.0 has no DMG or installer package.

Copyright © 2026 Suren Khorenyan. Released under the [MIT License](LICENSE).

## Documents

- [Product design](docs/PRODUCT_DESIGN.md) — user experience, v1 feature set, non-goals, and release criteria
- [Technical feasibility](docs/FEASIBILITY.md) — what macOS permits, the proposed mechanism, permissions, risks, and prototype gates
- [Competitor research](docs/COMPETITOR_RESEARCH.md) — what already exists and the deliberately narrow product position
- [Reference analysis](docs/REFERENCE_ANALYSIS.md) — exact Hidden Bar source mechanism and evidence-backed Barbee behavior
- [Decision record](docs/DECISIONS.md) — choices settled together before implementation
- [Naming research](docs/NAMING.md) — shortlist and preliminary collision checks
- [Domain language](CONTEXT.md) — precise terms used throughout the project
- [Translation guide](TRANSLATING.md) — contribution workflow and RTL review expectations

## Prototype status

Phase 1 is implemented in
[`Prototypes/InventoryIdentitySpike`](Prototypes/InventoryIdentitySpike). It uses
public Accessibility APIs to inventory Source Items, conservatively assess
identity and manageability, watch for changes, and measure metadata scan cost.
The spike must still be run through the Gate A live compatibility matrix before
Gate A is accepted.

## Current conclusion

The product is technically plausible as a menu-bar **proxy Dropdown**, pending a focused prototype. It is not possible as a literal container for other apps' menu-bar items: macOS does not expose a public API that lets one process adopt another process's status item.

TrayNook therefore keeps every real item owned by its source app and assigns it to Menu Bar, Dropdown, or Always Hidden. Dropdown items receive visual proxies and are temporarily revealed and activated when native interaction is needed; Always Hidden items receive no proxy. Exact off-screen images and reliable cross-process control may require unsupported WindowServer interfaces. Such calls are allowed only as isolated, capability-gated last resorts with tested crash-free fallbacks; see [ADR 0001](docs/adr/0001-isolate-and-gate-private-macos-apis.md).

Native source-app interfaces anchor to the temporarily promoted real Menu Bar item, not to the visual proxy; see [ADR 0007](docs/adr/0007-use-proxies-and-native-interaction-handoff.md).

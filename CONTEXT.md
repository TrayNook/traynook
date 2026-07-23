# TrayNook Context

This context describes a macOS utility that gives infrequently used menu-bar items a compact Dropdown without taking ownership of those items.

## Language

**Source Item**:
The real menu-bar item owned and rendered by macOS or another application. Its owning process remains responsible for its behavior.
_Avoid_: Native icon, original icon, foreign icon

**Launcher**:
TrayNook's own Source Item, used to open the Dropdown. Its Placement is permanently Menu Bar Zone, but the user may change its order within that zone; it is never represented inside the Dropdown.
_Avoid_: Control icon, app icon, trigger

**Dropdown**:
The transient panel opened from the Launcher that displays Running Proxy Items in wrapped rows.
_Avoid_: Shelf, second status bar, tray, overflow menu

**Settings Button**:
The gear-icon control that is first in the Dropdown's visual and keyboard order and opens or raises Settings. It occupies a first-row slot and scrolls with that row, but is not a Source Item, Proxy Item, or part of the user's configurable item order.
_Avoid_: Settings item, gear proxy

**Proxy Item**:
A visual control in the Dropdown that represents a Source Item without taking ownership of it. It forwards an interaction to the corresponding Source Item.
_Avoid_: Copied icon, cloned item, embedded icon

**Menu Bar Zone**:
The ordered set of Source Items the user chooses to keep visible in the macOS menu bar.
_Avoid_: Shown section, main bar, permanent icons

**Dropdown Zone**:
The ordered set of Source Items the user chooses to access through Proxy Items in the Dropdown.
_Avoid_: Hidden section, collapsed section, overflow

**Always Hidden Zone**:
The ordered set of Source Items the user chooses to show in neither the Menu Bar nor the Dropdown while their source applications continue running.
_Avoid_: Disabled items, removed items, never shown

**Placement Lane**:
An ordered collection in Settings that represents one possible Placement. It is an editor concept, not a row inside the Dropdown.
_Avoid_: Dropdown row, icon row, section

**Placement**:
The user's choice of Menu Bar Zone, Dropdown Zone, or Always Hidden Zone for a manageable Source Item.
_Avoid_: Visibility, hidden state

**Dropdown Row**:
A horizontal sequence of controls inside the open Dropdown. Rows are created automatically from the configured Row Capacity.
_Avoid_: Placement lane, settings row

**Row Capacity**:
The configurable maximum number of controls in a Dropdown Row: valid from 1–30, recommended from 5–20, and defaulting to 10. The Settings Button consumes one first-row slot, and physical screen width may force an earlier wrap.
_Avoid_: Lane count, row width, row length

**Desired Layout**:
The persisted order and Placement the user configured for known Source Items.
_Avoid_: Saved state, icon preferences

**Observed Layout**:
The Source Items and ordering that macOS currently exposes to the application.
_Avoid_: Current state, actual bar

**Placement Mismatch**:
A temporary state in which a Managed Item's requested Placement remains in Desired Layout but macOS has not accepted or retained it. The real item stays visible in Menu Bar Zone until an explicit retry or meaningful capability or environment change permits reconciliation.
_Avoid_: Protected Item, failed icon

**Interaction Handoff**:
The temporary reveal and activation of a Source Item so its owning application can present its native interface, anchored to the real item's temporary Menu Bar position rather than the Proxy Item.
_Avoid_: Virtual click, forwarded menu

**Managed Item**:
A Source Item the application can reliably identify, move, render, and restore on the current macOS version.
_Avoid_: Supported icon

**Protected Item**:
A Source Item that TrayNook cannot move or activate reliably on the current system. It remains in Menu Bar Zone with an explanation; capture-only failure instead uses the app-icon fallback.
_Avoid_: Broken icon, unsupported app

**Ambiguous Item**:
A Source Item that TrayNook cannot confidently match to one saved identity. It remains visible in Menu Bar Zone until the user authoritatively matches it to a compatible saved identity, treats it as a new Menu Bar item, or acknowledges it as Unmanaged. TrayNook never presents the user's mapping as an independently verified match.
_Avoid_: Unknown item, duplicate item, broken item

**Unmanaged**:
The acknowledged state of an Ambiguous Item the user chose to leave visible in Menu Bar Zone and outside automatic placement. It produces no ongoing attention indicator, retains a later Resolve action in Settings, and alerts again only after a materially new identity conflict.
_Avoid_: Ignored, resolved identity

**Running**:
The state of a known Source Item that TrayNook currently observes.
_Avoid_: Available, active app

**Not Running**:
The state of a known item whose source application remains installed but whose Source Item is not currently observed.
_Avoid_: Offline, disabled, closed

**App Missing**:
The state of a saved item whose source application bundle cannot currently be found. It does not assert that the user deleted the application.
_Avoid_: Deleted, removed forever, unavailable

**Supported Baseline**:
The minimum behavior an OS version must provide for TrayNook to call it supported: discovery, three-lane Settings movement, usable proxies, primary and secondary native handoff, and safe restoration.
_Avoid_: Partial support, best-effort support

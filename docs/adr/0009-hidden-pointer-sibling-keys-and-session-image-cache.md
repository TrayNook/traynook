---
status: accepted
---

# Hide the pointer, persist sibling keys, cache last-seen proxy images

Decided 2026-10-28 for build 19. Three earlier rules were stricter than what public
macOS APIs can deliver; this records what replaces them and why.

## Pointer during native moves

Status-item reordering happens only on the real pointer path, and every
pointer-free route tried in build 18 failed to promote the item. TrayNook now
hides the pointer with `CGDisplayHideCursor` for the duration of the synthesized
Command-drag or click, warps it back, and shows it again from every release path.
The pointer still moves; the user is not meant to see it. The strict
`--require-still-pointer` check therefore stays a measurement of displacement,
not a release criterion. Whether a non-frontmost process can hide the pointer
with the public call is unverified on device; if it cannot, the next option is
to keep TrayNook active for the move, never a private connection property.

## Several items from one application

The plain bundle identifier remains the saved key for an application's only
verified item. When one application owns several `AXMenuBarItem`s, each sibling
persists as `bundle#ax:<identifier>` when its AXIdentifier is unique among the
siblings and identifier-shaped (ASCII letters, digits, `.`, `_`, `-`, at most 64
characters), otherwise as `bundle#w<rank>` where rank is the creation order of
the sibling's status window. Window identifiers themselves are never persisted.
An AXIdentifier in that shape is accepted as a non-content discriminator because
it is assigned in code, not from user data; longer or free-form values are not
persisted and fall back to the rank. Status-level windows without a verified
item are runtime-only and never rank siblings or get a key.

Rank can shift when an application creates or destroys items dynamically. The
section is revealed whenever any sibling is removed or a ranked sibling's
status window changes within one process while concealed, so such a shift
cannot silently swap placements. A ranked proxy action also checks its original
window identifier against a fresh inventory before acting; a replacement between
polling and clicking cannot redirect the action to another sibling.
Ranks are assumed stable across a relaunch
(an application creates its items in code order), so a relaunched multi-item
application rebinds its hidden siblings without revealing; an application that
creates items in a different order on each launch would swap keys, and that
case is accepted as unlikely until seen. An application growing from one item
to two re-keys its first item; the old entry stays as Not Running until the
user forgets it. This replaces "indistinguishable
siblings stay Ambiguous" for the rank case; truly indistinguishable siblings
(no window identity) remain Ambiguous.

## Proxy images

`CGWindowListCreateImage` returns nil for offscreen status windows on macOS 15.7
(verified over 50 status-level windows), and offscreen capture otherwise needs a
private SkyLight call, which ADR 0001 forbids. TrayNook captures each Dropdown
item whenever it is onscreen (launch before concealment, Apply, promotion) and
keeps the last capture in memory for the session. Hidden items therefore show
their last-seen image; this is the normal state, not a transient fallback, and
the dropdown labels it as last seen. Images are purged when the item leaves the
Dropdown placement or Screen Recording is unavailable, and never written to disk.
Without Screen Recording the dropdown uses application icons.

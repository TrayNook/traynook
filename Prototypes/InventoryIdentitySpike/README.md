# Gate A — inventory and identity spike

This disposable Swift package implements the first TrayNook prototype phase from
[`docs/FEASIBILITY.md`](../../docs/FEASIBILITY.md): inspect public Accessibility
metadata, assess identity conservatively, detect inventory changes, and measure
the cost of metadata polling.

It deliberately contains no production UI, placement mutation, synthesized input,
screen capture, persistence, private API, analytics, or network access.

## Run

```sh
cd Prototypes/InventoryIdentitySpike
swift run traynook-inventory-spike scan
```

The spike does not trigger the macOS Accessibility prompt by default. Use
`scan --prompt` when you intentionally want the system prompt, grant the built
executable or its parent terminal in **System Settings → Privacy & Security →
Accessibility**, and rerun.

Watch for additions, removals, relaunches, order changes, and runtime metadata
changes while measuring each scan:

```sh
swift run traynook-inventory-spike watch --samples 30 --interval 1
```

Add `--json` to either command for machine-readable output. JSON can contain live
Accessibility titles and labels, so redirect it to a file only during an explicit
local test and delete the file after recording non-identifying conclusions.
The spike itself writes nothing to disk.

### Measure new-item detection

The sanitized addition harness continuously scans, accepts a `SIGUSR1` marker,
and reports the marker-to-detection upper bound plus aggregate scan cost:

```sh
swift run traynook-inventory-spike validate-addition \
  --bundle-id <target-bundle-id> --interval 0.25 --timeout 60 --json
```

The command prints the exact `kill -USR1` marker command to stderr. Send that
signal immediately before causing an already-running app to create its Source
Item. Unlike `scan --json` and `watch --json`, this command's report is sanitized:
it excludes the target bundle identifier, Source Item inventory, Accessibility
metadata, geometry, process IDs, and provisional identities.

Record only non-identifying conclusions in
[`Validation/GATE_A_MATRIX.md`](Validation/GATE_A_MATRIX.md).

### Exercise an app-owned boundary

The separate boundary executable is a disposable public-AppKit bridge for the
next Gate A scenario:

```sh
swift run traynook-boundary-spike
```

It creates a Launcher and a visible separator using only `NSStatusItem`. The
separator starts at square length, so launch does not deliberately conceal other
items. AppKit does not provide a public API to set status-item order. Command-drag
the Launcher to the right of the separator and place the separator at the desired
test boundary. Expansion remains disabled until their live window geometry
confirms that safe relationship on one screen. Then choose **Expand Boundary**
explicitly from either prototype item's menu. Choose **Collapse Boundary** before
rearranging the test setup. Termination synchronously collapses the boundary and
removes both prototype status items before allowing Quit.

The executable does not yet move foreign Source Items or claim that the boundary
works across the compatibility matrix. Forced termination removes the
process-owned items, but macOS may retain user-authored status-item ordering.

Pass a target bundle to enable a one-shot dry run:

```sh
swift run traynook-boundary-spike --target-bundle-id <target-bundle-id>
```

After positioning and expanding the boundary, choose **Arm Safe-Default Dry
Run**. The spike reports whether a newly added target item is uniquely actionable
but posts no input.

The live bridge additionally requires `--execute-correction` and the explicit
**Arm One Live Safe-Default Correction** menu action. On a matching addition it
collapses the boundary first, rebinds the unique identity from a fresh scan,
requires two stable visible same-display observations, rejects active physical
mouse/modifier input, then posts one public Quartz Command-drag with only the
Command modifier. It requires two stable reconciled observations both before and
after re-expanding. The arm expires after 60 seconds and can be cancelled from
the menu; system sleep or display reconfiguration cancels it. Any permission,
identity, process, display, geometry, collateral-order, input, or timeout
uncertainty leaves the boundary collapsed and reports only a non-identifying
failure code.

Do not run live correction against an Apple/system item, an Ambiguous or
Protected Item, or an item needed for recovery. Live validation requires an
explicitly chosen disposable third-party item, Accessibility approval, free
menu-bar space, no pointer input during the short drag, and a known manual
Command-drag recovery path.

## Verify

```sh
swift test
```

The fixture suite verifies:

- two items from one app can remain provisionally distinct when each exposes a
  unique Accessibility identifier;
- PID, width, title, and label changes do not silently create new identities;
- indistinguishable duplicate items remain Ambiguous;
- a new Source Item is detected, including an indistinguishable sibling that
  can only be reported as a bundle-level inventory change;
- physical ordering remains deterministic when some items lack geometry;
- missing geometry yields a non-mutating Protected classification.

## Interpretation limits

An `AXIdentifier` is only a **candidate** discriminator. It cannot enter
TrayNook's future persistent store until manual matrix testing establishes that it
is stable across source-app relaunch and contains no user content. Bundle-only
identity is provisional when exactly one item from that bundle is observed.

`candidate`, `requiresValidation`, and `protected` are non-mutating capability
assessments. In particular, the absence of `AXPress` does not prove that no safe
activation path exists; it records work for later prototype gates.

Gate A is not accepted from automated tests alone. Record live results for Sonoma
14, Sequoia 15, and Tahoe 26, including at least one app with two Source Items, an
already-running app that creates a new item, source-app relaunch, dynamic
width/title changes, protected system items, and idle scan timings.

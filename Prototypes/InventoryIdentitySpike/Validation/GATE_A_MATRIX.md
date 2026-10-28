# Gate A live compatibility matrix

Status: partially run. Production MVP native acceptance updated on 2026-09-18; full Gate A is still open.

Use this file to record sanitized conclusions only. Do not paste raw `scan`,
`watch`, or Accessibility output. In particular, never record Source Item titles,
labels, identifier candidates, geometry, process/window IDs, hashes of
content-bearing strings, or a source-application inventory.

The 2026-09-16 crowded-control blocker below is historical. On 2026-09-18,
automatic own-control positioning, native drags in both directions, native menu
handoff/dismissal, and clipped-item AXPress passed live checks. The actual saved
MVP layout also concealed six selected sources while eleven Menu Bar sources
stayed onscreen. This does not close the broader identity/platform matrix; see
[the current MVP report](../../../docs/MVP_REPORT.md) and the repeatable native
checks in `Scripts/` at the repository root.

## Test environments

| macOS | Exact version/build | Architecture | Hardware/display facts | Result |
| --- | --- | --- | --- | --- |
| Sonoma 14 | Not run | Not run | Intel, no notch | Not run |
| Sequoia 15 | 15.7.1 (24G231) | arm64 | Apple silicon; display class pending | Partial — permission and initial enumeration exercised at `3bf230d` |
| Tahoe 26 | Not run | Not run | Apple silicon | Not run |

Record only facts needed to interpret compatibility, such as architecture,
notch/non-notch, and Retina/non-Retina. Do not record serial numbers, account
names, hostnames, or other device identifiers.

## Scenarios

Run every row on every environment above.

| Scenario | Sonoma 14 | Sequoia 15 | Tahoe 26 |
| --- | --- | --- | --- |
| Enumerate representative manageable Source Items | Not run | Partial — 19 Source Items enumerated in 41,490.66 ms; classification review pending (`3bf230d`) | Not run |
| Two Source Items from one app remain distinguishable | Not run | Not run | Not run |
| Source-app quit/relaunch preserves provisional identity | Not run | Not run | Not run |
| Width/title changes do not create a new identity | Not run | Not run | Not run |
| Already-running app creates a Source Item | Not run | Not run | Not run |
| New item on either boundary side returns to safe default | Not run | Not run | Not run |
| Obvious non-candidates are identified without mutation | Not run | Not run | Not run |
| Accessibility denial and regrant fail safely | Not run | Pass — denial returned an empty non-mutating result; regrant resumed enumeration (`3bf230d`) | Not run |

For the addition row, run:

```sh
.build/apps/TrayNook\ Inventory\ Spike.app/Contents/MacOS/traynook-inventory-spike \
  validate-addition \
  --bundle-id <target-bundle-id> --interval 0.25 --timeout 60 --json
```

The command first acquires a granted, complete baseline; it then prints a PID and
waits for `SIGUSR1`. Send the displayed command immediately before triggering
creation of the target Source Item. Its JSON report contains only
OS/architecture, polling parameters, aggregate scan timings, the configured
messaging timeout, complete/incomplete scan and cannot-complete counts, change
kind, and the marker-to-detection upper bound. An incomplete snapshot is never
diffed or used for correction.

## Measured results

Choose latency and idle metadata-monitoring budgets only after measurements
exist. Record the proposed thresholds and rationale here; the product documents
do not currently define numeric acceptance limits.

| Metric | Sonoma 14 | Sequoia 15 | Tahoe 26 | Accepted budget |
| --- | --- | --- | --- | --- |
| Marker-to-detection upper bound | Not run | Not run | Not run | Pending evidence |
| Average metadata scan | Not run | 41,490.66 ms (one pre-timeout scan at `3bf230d`) | Not run | Pending evidence |
| Maximum metadata scan | Not run | 41,490.66 ms (one pre-timeout scan at `3bf230d`) | Not run | Pending evidence |

## Conclusions

- Gate A remains open until every environment and scenario has a recorded,
  reviewed result.
- “Protected” remains provisional until later non-mutating probes and the
  placement gate establish that movement and activation are unavailable.
- Safe-default correction has a dry-run-by-default boundary/movement bridge, but
  it remains unaccepted until the live matrix verifies both insertion sides,
  restoration, collateral order, and fail-visible behavior.
- The first granted Sequoia scan proved public Accessibility enumeration but
  exposed an unacceptable 41.49-second synchronous scan.
- On 2026-09-16 the MVP shared scanner was rebuilt and remeasured. A live local
  diagnostic returned a complete 19-item inventory in 674 ms, then 478 ms on the final build, with zero incomplete
  apps, after selecting actual public status-window owners and adding a global
  scan budget. These are local samples, not an accepted performance budget.
- A disposable owned fixture was discovered uniquely in a complete inventory.
  Its native click/drag/conceal run was blocked because macOS placed the new
  controls offscreen in the crowded menu bar. No existing items were manipulated.
  Source restart, insertion correction, and the remaining OS matrix still need
  live acceptance. See [MVP report](../../../docs/MVP_REPORT.md).

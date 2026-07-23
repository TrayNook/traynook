# Gate A live compatibility matrix

Status: not run.

Use this file to record sanitized conclusions only. Do not paste raw `scan`,
`watch`, or Accessibility output. In particular, never record Source Item titles,
labels, identifier candidates, geometry, process/window IDs, hashes of
content-bearing strings, or a source-application inventory.

## Test environments

| macOS | Exact version/build | Architecture | Hardware/display facts | Result |
| --- | --- | --- | --- | --- |
| Sonoma 14 | Not run | Not run | Intel, no notch | Not run |
| Sequoia 15 | Not run | Not run | Apple silicon, notch | Not run |
| Tahoe 26 | Not run | Not run | Apple silicon | Not run |

Record only facts needed to interpret compatibility, such as architecture,
notch/non-notch, and Retina/non-Retina. Do not record serial numbers, account
names, hostnames, or other device identifiers.

## Scenarios

Run every row on every environment above.

| Scenario | Sonoma 14 | Sequoia 15 | Tahoe 26 |
| --- | --- | --- | --- |
| Enumerate representative manageable Source Items | Not run | Not run | Not run |
| Two Source Items from one app remain distinguishable | Not run | Not run | Not run |
| Source-app quit/relaunch preserves provisional identity | Not run | Not run | Not run |
| Width/title changes do not create a new identity | Not run | Not run | Not run |
| Already-running app creates a Source Item | Not run | Not run | Not run |
| New item on either boundary side returns to safe default | Not run | Not run | Not run |
| Obvious non-candidates are identified without mutation | Not run | Not run | Not run |
| Accessibility denial and regrant fail safely | Not run | Not run | Not run |

For the addition row, run:

```sh
swift run traynook-inventory-spike validate-addition \
  --bundle-id <target-bundle-id> --interval 0.25 --timeout 60 --json
```

The command prints a PID and waits for `SIGUSR1`. Send the displayed command
immediately before triggering creation of the target Source Item. Its JSON report
contains only OS/architecture, polling parameters, aggregate scan timings,
change kind, and the marker-to-detection upper bound.

## Measured results

Choose latency and idle metadata-monitoring budgets only after measurements
exist. Record the proposed thresholds and rationale here; the product documents
do not currently define numeric acceptance limits.

| Metric | Sonoma 14 | Sequoia 15 | Tahoe 26 | Accepted budget |
| --- | --- | --- | --- | --- |
| Marker-to-detection upper bound | Not run | Not run | Not run | Pending evidence |
| Average metadata scan | Not run | Not run | Not run | Pending evidence |
| Maximum metadata scan | Not run | Not run | Not run | Pending evidence |

## Conclusions

- Gate A remains open until every environment and scenario has a recorded,
  reviewed result.
- “Protected” remains provisional until later non-mutating probes and the
  placement gate establish that movement and activation are unavailable.
- Safe-default correction has a dry-run-by-default boundary/movement bridge, but
  it remains unaccepted until the live matrix verifies both insertion sides,
  restoration, collateral order, and fail-visible behavior.

import Foundation

public struct InventoryMonitor {
  private let scanner: AccessibilityInventoryScanner
  private let differ: SnapshotDiffer

  public init(
    scanner: AccessibilityInventoryScanner = AccessibilityInventoryScanner(),
    differ: SnapshotDiffer = SnapshotDiffer()
  ) {
    self.scanner = scanner
    self.differ = differ
  }

  public func watch(
    sampleCount: Int,
    intervalSeconds: Double,
    promptForPermission: Bool = false
  ) -> WatchReport {
    precondition(sampleCount > 0)
    precondition(intervalSeconds >= 0)

    var samples: [WatchSample] = []
    var previousItems: [ClassifiedSourceItem]?

    for sampleIndex in 0..<sampleCount {
      let snapshot = scanner.scan(
        promptForPermission: promptForPermission && sampleIndex == 0
      )
      let changes =
        previousItems.map {
          differ.changes(from: $0, to: snapshot.items)
        } ?? []
      samples.append(WatchSample(snapshot: snapshot, changes: changes))
      previousItems = snapshot.items

      if sampleIndex < sampleCount - 1, intervalSeconds > 0 {
        Thread.sleep(forTimeInterval: intervalSeconds)
      }
    }

    let durations = samples.map(\.snapshot.metrics.durationMilliseconds)
    let average = durations.reduce(0, +) / Double(durations.count)

    return WatchReport(
      samples: samples,
      metrics: WatchMetrics(
        sampleCount: sampleCount,
        intervalSeconds: intervalSeconds,
        averageScanMilliseconds: average,
        maximumScanMilliseconds: durations.max() ?? 0
      )
    )
  }
}

import Foundation

public struct InventoryMonitor {
  private let scanner: any InventoryScanning
  private let differ: SnapshotDiffer

  public init(
    scanner: any InventoryScanning = AccessibilityInventoryScanner(),
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
    var changeTracker = CompleteSnapshotChangeTracker()

    for sampleIndex in 0..<sampleCount {
      let snapshot = scanner.scan(
        promptForPermission: promptForPermission && sampleIndex == 0
      )
      let changes = changeTracker.changes(
        for: snapshot,
        using: differ
      )
      samples.append(WatchSample(snapshot: snapshot, changes: changes))

      if sampleIndex < sampleCount - 1, intervalSeconds > 0 {
        Thread.sleep(forTimeInterval: intervalSeconds)
      }
    }

    let durations = samples.map(\.snapshot.metrics.durationMilliseconds)
    let average = durations.reduce(0, +) / Double(durations.count)
    let completeSampleCount = samples.filter {
      $0.snapshot.completeness == .complete
    }.count

    return WatchReport(
      samples: samples,
      metrics: WatchMetrics(
        sampleCount: sampleCount,
        completeSampleCount: completeSampleCount,
        incompleteSampleCount: samples.count - completeSampleCount,
        intervalSeconds: intervalSeconds,
        averageScanMilliseconds: average,
        maximumScanMilliseconds: durations.max() ?? 0
      )
    )
  }
}

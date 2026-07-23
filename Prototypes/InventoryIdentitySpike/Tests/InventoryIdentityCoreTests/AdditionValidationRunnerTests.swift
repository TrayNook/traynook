import Foundation
import Testing

@testable import InventoryIdentityCore

@Suite("Gate A addition validation runner")
struct AdditionValidationRunnerTests {
  @Test("Denied and incomplete baselines never arm validation")
  func invalidBaselinesDoNotArm() {
    for initial in [
      snapshot(
        permission: .denied,
        completeness: .incomplete,
        items: []
      ),
      snapshot(
        permission: .granted,
        completeness: .incomplete,
        items: []
      ),
    ] {
      let scanner = SequenceScanner([initial])
      var armed = false
      let report = runner(scanner: scanner).run(
        intervalSeconds: 0.25,
        timeoutSeconds: 60,
        targetBundleIdentifier: "example.target",
        markerUptimeNanoseconds: { nil },
        onArmed: { armed = true }
      )

      #expect(!armed)
      #expect(
        report.status
          == (initial.permission == .denied
            ? .accessibilityDenied
            : .inventoryIncomplete)
      )
      #expect(report.completeScanCount == 0)
      #expect(report.incompleteScanCount == 1)
    }
  }

  @Test("An incomplete sample is skipped without replacing the baseline")
  func incompleteSampleIsSkipped() {
    let original = item(
      bundleIdentifier: "example.original",
      runtimeID: "100:0"
    )
    let addition = item(
      bundleIdentifier: "example.target",
      runtimeID: "200:0"
    )
    let scanner = SequenceScanner([
      snapshot(items: [original]),
      snapshot(
        completeness: .incomplete,
        items: [],
        incompleteApplicationCount: 1,
        cannotCompleteApplicationCount: 1
      ),
      snapshot(items: [original, addition]),
    ])
    var armed = false

    let report = runner(scanner: scanner).run(
      intervalSeconds: 0.25,
      timeoutSeconds: 60,
      targetBundleIdentifier: "example.target",
      markerUptimeNanoseconds: { 0 },
      onArmed: { armed = true }
    )

    #expect(armed)
    #expect(report.status == .detected)
    #expect(report.completedScanCount == 3)
    #expect(report.completeScanCount == 2)
    #expect(report.incompleteScanCount == 1)
    #expect(report.cannotCompleteApplicationScanCount == 1)
    #expect(report.messagingTimeoutMilliseconds == 200)
    #expect(report.detectedChangeKind == .created)
  }

  @Test("Repeated incomplete samples time out without fabricated additions")
  func incompleteSamplesTimeOut() {
    let original = item(
      bundleIdentifier: "example.original",
      runtimeID: "100:0"
    )
    let scanner = SequenceScanner([
      snapshot(items: [original]),
      snapshot(
        completeness: .incomplete,
        items: [],
        incompleteApplicationCount: 1,
        cannotCompleteApplicationCount: 1
      ),
    ])
    let clock = StepClock(step: 1_000_000_000)
    let runner = AdditionValidationRunner(
      scanner: scanner,
      uptimeNanoseconds: clock.now,
      sleep: { _ in }
    )

    let report = runner.run(
      intervalSeconds: 0.25,
      timeoutSeconds: 2,
      targetBundleIdentifier: "example.target",
      markerUptimeNanoseconds: { 1_000_000_000 }
    )

    #expect(report.status == .additionTimedOut)
    #expect(report.incompleteScanCount == 1)
    #expect(report.detectedChangeKind == nil)
  }

  @Test("A marker newer than a clock sample cannot underflow")
  func futureMarkerDoesNotUnderflow() {
    let original = item(
      bundleIdentifier: "example.original",
      runtimeID: "100:0"
    )
    let scanner = SequenceScanner([
      snapshot(items: [original]),
      snapshot(items: [original]),
    ])
    let clock = ScriptedClock([
      100,
      150,
      160,
      1_000_000_300,
    ])
    let runner = AdditionValidationRunner(
      scanner: scanner,
      uptimeNanoseconds: clock.now,
      sleep: { _ in }
    )

    let report = runner.run(
      intervalSeconds: 0.25,
      timeoutSeconds: 0.5,
      targetBundleIdentifier: "example.target",
      markerUptimeNanoseconds: { 200 }
    )

    #expect(report.status == .additionTimedOut)
    #expect(report.markerToDetectionMilliseconds == nil)
  }

  private func runner(
    scanner: any InventoryScanning
  ) -> AdditionValidationRunner {
    let clock = StepClock(step: 1_000_000)
    return AdditionValidationRunner(
      scanner: scanner,
      uptimeNanoseconds: clock.now,
      sleep: { _ in }
    )
  }

  private func snapshot(
    permission: AccessibilityPermissionStatus = .granted,
    completeness: InventoryScanCompleteness = .complete,
    items: [ClassifiedSourceItem],
    incompleteApplicationCount: Int = 0,
    cannotCompleteApplicationCount: Int = 0
  ) -> InventorySnapshot {
    InventorySnapshot(
      capturedAt: Date(timeIntervalSince1970: 0),
      permission: permission,
      completeness: completeness,
      items: items,
      warnings: [],
      metrics: ScanMetrics(
        durationMilliseconds: 10,
        inspectedApplicationCount: 2,
        sourceItemCount: items.count,
        incompleteApplicationCount: incompleteApplicationCount,
        cannotCompleteApplicationCount:
          cannotCompleteApplicationCount,
        maximumApplicationScanMilliseconds: 5,
        messagingTimeoutMilliseconds: 200
      )
    )
  }

  private func item(
    bundleIdentifier: String,
    runtimeID: String
  ) -> ClassifiedSourceItem {
    let identity = ProvisionalIdentityKey(
      bundleIdentifier: bundleIdentifier
    )
    return ClassifiedSourceItem(
      observation: RawSourceItemObservation(
        runtimeID: runtimeID,
        processIdentifier: 100,
        bundleIdentifier: bundleIdentifier,
        applicationName: "Fixture",
        role: "AXMenuBarItem",
        frame: ItemFrame(x: 0, y: 0, width: 24, height: 24),
        actions: ["AXPress"],
        metadata: LiveAccessibilityMetadata(),
        observedOrder: 0
      ),
      identity: IdentityAssessment(
        status: .provisionalBundleIdentity,
        provisionalKey: identity,
        reason: "fixture"
      ),
      manageability: ManageabilityAssessment(
        status: .candidate,
        reason: "fixture"
      )
    )
  }
}

private final class SequenceScanner: InventoryScanning, @unchecked Sendable {
  private let lock = NSLock()
  private let snapshots: [InventorySnapshot]
  private var index = 0

  init(_ snapshots: [InventorySnapshot]) {
    precondition(!snapshots.isEmpty)
    self.snapshots = snapshots
  }

  func scan(promptForPermission: Bool) -> InventorySnapshot {
    lock.lock()
    defer { lock.unlock() }
    let snapshot = snapshots[min(index, snapshots.count - 1)]
    index += 1
    return snapshot
  }
}

private final class StepClock: @unchecked Sendable {
  private let lock = NSLock()
  private let step: UInt64
  private var value: UInt64 = 0

  init(step: UInt64) {
    self.step = step
  }

  func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    value += step
    return value
  }
}

private final class ScriptedClock: @unchecked Sendable {
  private let lock = NSLock()
  private let values: [UInt64]
  private var index = 0

  init(_ values: [UInt64]) {
    precondition(!values.isEmpty)
    self.values = values
  }

  func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let value = values[min(index, values.count - 1)]
    index += 1
    return value
  }
}

import Foundation
import Testing

@testable import InventoryIdentityCore

@Suite("Complete inventory snapshot tracking")
struct CompleteSnapshotChangeTrackerTests {
  @Test("An incomplete sample cannot replace the last complete baseline")
  func incompleteSampleDoesNotCreateFalseChanges() {
    let item = classifiedItem()
    var tracker = CompleteSnapshotChangeTracker()

    #expect(tracker.changes(for: snapshot(items: [item])).isEmpty)
    #expect(
      tracker.changes(
        for: snapshot(items: [], completeness: .incomplete)
      ).isEmpty
    )
    #expect(tracker.changes(for: snapshot(items: [item])).isEmpty)

    let realRemoval = tracker.changes(for: snapshot(items: []))
    #expect(realRemoval.count == 1)
    #expect(realRemoval.first?.kind == .removed)
  }

  @Test("A denied sample cannot replace the last complete baseline")
  func deniedSampleDoesNotCreateFalseChanges() {
    let item = classifiedItem()
    var tracker = CompleteSnapshotChangeTracker()

    #expect(tracker.changes(for: snapshot(items: [item])).isEmpty)
    #expect(
      tracker.changes(
        for: snapshot(
          items: [],
          permission: .denied,
          completeness: .incomplete
        )
      ).isEmpty
    )
    #expect(tracker.changes(for: snapshot(items: [item])).isEmpty)
  }

  private func snapshot(
    items: [ClassifiedSourceItem],
    permission: AccessibilityPermissionStatus = .granted,
    completeness: InventoryScanCompleteness = .complete
  ) -> InventorySnapshot {
    InventorySnapshot(
      capturedAt: Date(timeIntervalSince1970: 0),
      permission: permission,
      completeness: completeness,
      items: items,
      warnings: [],
      metrics: ScanMetrics(
        durationMilliseconds: 1,
        inspectedApplicationCount: 1,
        sourceItemCount: items.count,
        incompleteApplicationCount:
          completeness == .complete ? 0 : 1,
        cannotCompleteApplicationCount:
          completeness == .complete ? 0 : 1,
        maximumApplicationScanMilliseconds: 1,
        messagingTimeoutMilliseconds: 200
      )
    )
  }

  private func classifiedItem() -> ClassifiedSourceItem {
    let identity = ProvisionalIdentityKey(
      bundleIdentifier: "example.complete",
      discriminatorCandidate: "primary"
    )
    return ClassifiedSourceItem(
      observation: RawSourceItemObservation(
        runtimeID: "100:0",
        processIdentifier: 100,
        bundleIdentifier: identity.bundleIdentifier,
        applicationName: "Complete",
        role: "AXMenuBarItem",
        frame: ItemFrame(x: 0, y: 0, width: 24, height: 24),
        actions: ["AXPress"],
        metadata: LiveAccessibilityMetadata(
          identifierCandidate: identity.discriminatorCandidate
        ),
        observedOrder: 0
      ),
      identity: IdentityAssessment(
        status: .provisionalDiscriminator,
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

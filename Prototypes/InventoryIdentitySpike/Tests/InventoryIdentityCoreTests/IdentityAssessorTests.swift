import Foundation
import Testing

@testable import InventoryIdentityCore

private struct GateAFixture: Decodable {
  let relaunchBefore: [RawSourceItemObservation]
  let relaunchAfter: [RawSourceItemObservation]
  let ambiguousDuplicates: [RawSourceItemObservation]
  let createdItem: RawSourceItemObservation
}

@Suite("Gate A identity and inventory logic")
struct IdentityAssessorTests {
  private let assessor = IdentityAssessor()
  private let differ = SnapshotDiffer()

  @Test("Unique AX identifiers distinguish two items across relaunch and text changes")
  func uniqueDiscriminatorsSurviveRelaunch() throws {
    let fixture = try loadFixture()
    let before = assessor.classify(fixture.relaunchBefore)
    let after = assessor.classify(fixture.relaunchAfter)

    #expect(
      before.map(\.identity.status) == [
        .provisionalDiscriminator,
        .provisionalDiscriminator,
      ])
    #expect(
      before.compactMap(\.identity.provisionalKey)
        == after.compactMap(\.identity.provisionalKey)
    )

    let changes = differ.changes(from: before, to: after)
    #expect(changes.filter { $0.kind == .created }.isEmpty)
    #expect(changes.filter { $0.kind == .removed }.isEmpty)
    #expect(changes.filter { $0.kind == .processReplaced }.count == 2)
    #expect(changes.filter { $0.kind == .runtimeMetadataChanged }.count == 2)
  }

  @Test("Indistinguishable duplicate items remain Ambiguous")
  func duplicatesRemainAmbiguous() throws {
    let items = assessor.classify(try loadFixture().ambiguousDuplicates)

    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.identity.status == .ambiguous })
    #expect(items.allSatisfy { $0.identity.provisionalKey == nil })
  }

  @Test("A newly observed bundle is reported as a created Source Item")
  func detectsCreatedItem() throws {
    let fixture = try loadFixture()
    let before = assessor.classify(fixture.relaunchBefore)
    let after = assessor.classify(
      fixture.relaunchBefore + [fixture.createdItem]
    )

    let changes = differ.changes(from: before, to: after)

    #expect(changes.filter { $0.kind == .created }.count == 1)
    #expect(
      changes.first { $0.kind == .created }?.identity?.bundleIdentifier
        == "example.new-item"
    )
  }

  @Test("Adding a second item from a running app preserves the first identity")
  func detectsNewSiblingWithoutReplacingExistingIdentity() throws {
    let fixture = try loadFixture()
    let first = fixture.relaunchBefore[0]
    let second = fixture.relaunchBefore[1]
    let before = assessor.classify([first])
    let after = assessor.classify([first, second])

    let changes = differ.changes(from: before, to: after)

    #expect(changes.filter { $0.kind == .created }.count == 1)
    #expect(changes.filter { $0.kind == .removed }.isEmpty)
    #expect(
      changes.first { $0.kind == .created }?.identity?.discriminatorCandidate
        == "timer.secondary"
    )
  }

  @Test("Adding an indistinguishable sibling reports a bundle inventory change")
  func detectsAmbiguousSiblingInventoryChange() throws {
    let duplicates = try loadFixture().ambiguousDuplicates
    let before = assessor.classify([duplicates[0]])
    let after = assessor.classify(duplicates)

    let changes = differ.changes(from: before, to: after)
    let inventoryChange = try #require(
      changes.first { $0.kind == .ambiguousInventoryChanged }
    )

    #expect(changes.allSatisfy { $0.kind != .removed })
    #expect(inventoryChange.identity == nil)
    #expect(
      inventoryChange.runtimeGroup?.bundleIdentifier
        == "example.indistinguishable"
    )
    #expect(inventoryChange.previousCount == 1)
    #expect(inventoryChange.currentCount == 2)
  }

  @Test("Siblings without identifiers are ranked by status-window creation order")
  func siblingsRankedByWindowOrder() throws {
    let duplicates = try loadFixture().ambiguousDuplicates
    let withWindows = duplicates.enumerated().map { index, raw in
      // Observed right-to-left on purpose: physical order must not matter.
      sibling(raw, window: UInt32(200 - index), x: Double(100 * index))
    }
    let items = assessor.classify(withWindows)

    #expect(items.allSatisfy { $0.identity.status == .provisionalDiscriminator })
    #expect(Set(items.compactMap(\.identity.persistentKey)).count == 2)
    let keys = items.sorted { $0.observation.statusWindowIdentifier! < $1.observation.statusWindowIdentifier! }
      .map(\.identity.persistentKey)
    #expect(keys == ["example.indistinguishable", "example.indistinguishable#w1"])

    let relaunched = duplicates.enumerated().map { index, raw in
      sibling(raw, window: UInt32(900 - index), x: Double(100 * index), pid: 77)
    }
    let changes = differ.changes(from: items, to: assessor.classify(relaunched))
    #expect(changes.filter { $0.kind == .created || $0.kind == .removed }.isEmpty)
    #expect(changes.filter { $0.kind == .processReplaced }.count == 2)

    let partial = [withWindows[0], sibling(duplicates[1], window: nil, x: 100)]
    #expect(assessor.classify(partial).allSatisfy { $0.identity.status == .ambiguous })
  }

  private func sibling(_ raw: RawSourceItemObservation, window: UInt32?, x: Double,
    pid: Int32? = nil) -> RawSourceItemObservation {
    RawSourceItemObservation(runtimeID: "\(pid ?? raw.processIdentifier):\(x)",
      processIdentifier: pid ?? raw.processIdentifier,
      bundleIdentifier: raw.bundleIdentifier, applicationName: raw.applicationName,
      role: raw.role, frame: ItemFrame(x: x, y: 0, width: 24, height: 24),
      actions: raw.actions, metadata: raw.metadata, observedOrder: raw.observedOrder,
      statusWindowIdentifier: window)
  }

  @Test("Physical ordering remains total when geometry is missing")
  func ordersMixedGeometryDeterministically() {
    let observations = [
      observation(
        runtimeID: "z-framed-first",
        frame: ItemFrame(x: 10, y: 0, width: 20, height: 20)
      ),
      observation(runtimeID: "a-unframed", frame: nil),
      observation(
        runtimeID: "b-framed-second",
        frame: ItemFrame(x: 20, y: 0, width: 20, height: 20)
      ),
    ]

    #expect(
      physicallyOrdered(observations).map(\.runtimeID) == [
        "z-framed-first",
        "b-framed-second",
        "a-unframed",
      ])
  }

  @Test("Missing geometry is classified as Protected without moving the item")
  func missingGeometryIsProtected() {
    let raw = RawSourceItemObservation(
      runtimeID: "500:0",
      processIdentifier: 500,
      bundleIdentifier: "example.protected",
      applicationName: "Protected",
      role: "AXMenuBarItem",
      frame: nil,
      actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(),
      observedOrder: 0
    )

    let item = assessor.classify([raw]).first

    #expect(item?.manageability.status == .protected)
  }

  @Test("Apple system controls remain Protected even with geometry and AXPress")
  func systemControlsAreProtected() throws {
    let raw = RawSourceItemObservation(
      runtimeID: "500:0",
      processIdentifier: 500,
      bundleIdentifier: "com.apple.controlcenter",
      applicationName: "Control Center",
      role: "AXMenuBarItem",
      frame: ItemFrame(x: 800, y: 0, width: 24, height: 24),
      actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(identifierCandidate: "system.control"),
      observedOrder: 0
    )
    let items = assessor.classify([raw])
    let identity = try #require(items.first?.identity.provisionalKey)

    #expect(items.first?.manageability.status == .protected)
    #expect(throws: SafeDefaultCorrectionPlanningError.targetProtected) {
      try SafeDefaultCorrectionPlanner().plan(
        target: identity,
        in: items,
        boundaryFrame: ItemFrame(x: 900, y: 0, width: 24, height: 24),
        launcherFrame: ItemFrame(x: 924, y: 0, width: 24, height: 24),
        safeMenuBarFrame: ItemFrame(x: 700, y: 0, width: 300, height: 24)
      )
    }
  }

  @Test("Finite coordinates whose edges overflow are not usable geometry")
  func overflowingGeometryIsProtected() {
    let frame = ItemFrame(
      x: .greatestFiniteMagnitude,
      y: 0,
      width: .greatestFiniteMagnitude,
      height: 24
    )
    let items = assessor.classify([observation(runtimeID: "500:0", frame: frame)])

    #expect(!frame.isUsable)
    #expect(items.first?.manageability.status == .protected)
  }

  private func observation(
    runtimeID: String,
    frame: ItemFrame?
  ) -> RawSourceItemObservation {
    RawSourceItemObservation(
      runtimeID: runtimeID,
      processIdentifier: 500,
      bundleIdentifier: "example.order",
      applicationName: "Order",
      role: "AXMenuBarItem",
      frame: frame,
      actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(),
      observedOrder: 0
    )
  }

  private func loadFixture() throws -> GateAFixture {
    let url = try #require(
      Bundle.module.url(
        forResource: "gate-a-scenarios",
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    )
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(GateAFixture.self, from: data)
  }
}

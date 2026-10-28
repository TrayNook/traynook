import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Concealed inventory monitoring")
@MainActor
struct AppModelInventoryTests {
  private let known: Set<String> = ["example.timer", "example.known"]

  @Test("An unchanged multi-item system app does not reopen the hidden section")
  func stableSystemItemsRemainConcealed() {
    let inventory = IdentityAssessor().classify([
      item(),
      item(bundle: "com.apple.controlcenter", pid: 20, index: 0, identifier: "clock"),
      item(bundle: "com.apple.controlcenter", pid: 20, index: 1, identifier: "wifi"),
    ])
    #expect(!AppModel.inventoryRequiresReveal(previous: inventory, current: inventory, known: known))
  }

  @Test("Dynamic titles, geometry, ordering, and window churn do not change source identity")
  func metadataChangesRemainConcealed() {
    let before = IdentityAssessor().classify([item(identifier: "primary")])
    let after = IdentityAssessor().classify([
      item(index: 2, identifier: "primary", title: "updated", x: -300),
    ])
    #expect(!AppModel.inventoryRequiresReveal(previous: before, current: after, known: known))
  }

  @Test("A restarted or relaunched known source rebinds its process instead of revealing")
  func knownSourcesRebind() {
    let assessor = IdentityAssessor()
    let original = assessor.classify([item(identifier: "primary")])
    let restarted = assessor.classify([item(pid: 30, identifier: "primary")])
    let restartChanges = AppModel.keyedChanges(from: original, to: restarted)
    #expect(!AppModel.inventoryRequiresReveal(restartChanges, known: known))
    #expect(restartChanges.contains { AppModel.rebindsProcess($0, known: known) })

    let relaunched = assessor.classify([item(bundle: "example.known", pid: 31)])
    let relaunchChanges = AppModel.keyedChanges(from: [], to: relaunched)
    #expect(!AppModel.inventoryRequiresReveal(relaunchChanges, known: known))
    #expect(relaunchChanges.contains { AppModel.rebindsProcess($0, known: known) })
    #expect(!relaunchChanges.contains { AppModel.rebindsProcess($0, known: []) })

    #expect(!AppModel.inventoryRequiresReveal(previous: original, current: [], known: known))

    // A known second sibling (ranked by window creation order) rebinds too.
    let siblings = assessor.classify([
      item(bundle: "example.pair", pid: 40, index: 0, window: 10),
      item(bundle: "example.pair", pid: 40, index: 1, window: 11),
    ])
    let siblingChanges = AppModel.keyedChanges(from: [], to: siblings)
    #expect(siblingChanges.compactMap(\.key).sorted() == ["example.pair", "example.pair#w1"])
    #expect(AppModel.inventoryRequiresReveal(siblingChanges, known: ["example.pair"]))
    #expect(!AppModel.inventoryRequiresReveal(siblingChanges, known: ["example.pair", "example.pair#w1"]))
  }

  @Test("An unknown bundle or an ambiguous group change requests a reveal")
  func realInventoryChangesReveal() {
    let assessor = IdentityAssessor()
    let original = assessor.classify([item(identifier: "primary")])
    #expect(AppModel.inventoryRequiresReveal(previous: original,
      current: assessor.classify([item(identifier: "primary"), item(bundle: "example.new", pid: 30)]),
      known: known))
    #expect(AppModel.inventoryRequiresReveal(
      previous: assessor.classify([item(index: 0), item(index: 1)]),
      current: assessor.classify([item(index: 0), item(index: 1), item(index: 2)]),
      known: known))
  }

  private func item(bundle: String = "example.timer", pid: Int32 = 10,
    index: Int = 0, identifier: String? = nil, title: String = "ready", x: Double = 1100,
    window: UInt32? = nil
  ) -> RawSourceItemObservation {
    RawSourceItemObservation(runtimeID: "\(pid):\(index)", processIdentifier: pid,
      bundleIdentifier: bundle, applicationName: "Fixture", role: "AXMenuBarItem",
      frame: ItemFrame(x: x, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(identifierCandidate: identifier, title: title),
      observedOrder: index, statusWindowIdentifier: window)
  }
}

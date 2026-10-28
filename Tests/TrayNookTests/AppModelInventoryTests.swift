import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Concealed inventory monitoring")
@MainActor
struct AppModelInventoryTests {
  @Test("An unchanged multi-item system app does not reopen the hidden section")
  func stableSystemItemsRemainConcealed() {
    let inventory = IdentityAssessor().classify([
      item(),
      item(bundle: "com.apple.controlcenter", pid: 20, index: 0, identifier: "clock"),
      item(bundle: "com.apple.controlcenter", pid: 20, index: 1, identifier: "wifi"),
    ])
    #expect(!AppModel.inventoryRequiresReveal(previous: inventory, current: inventory,
      previousWindows: [1, 2, 3], currentWindows: [1, 2, 3]))
  }

  @Test("Dynamic titles, geometry, and ordering do not change source identity")
  func metadataChangesRemainConcealed() {
    let before = IdentityAssessor().classify([item(identifier: "primary")])
    let after = IdentityAssessor().classify([
      item(index: 2, identifier: "primary", title: "updated", x: -300),
    ])
    #expect(!AppModel.inventoryRequiresReveal(previous: before, current: after,
      previousWindows: [1], currentWindows: [1]))
  }

  @Test("Actual source, process, ambiguity, and window changes request a reveal")
  func realInventoryChangesReveal() {
    let assessor = IdentityAssessor()
    let original = assessor.classify([item(identifier: "primary")])
    let changedInventories = [
      assessor.classify([item(pid: 30, identifier: "primary")]),
      assessor.classify([item(identifier: "primary"), item(bundle: "example.new", pid: 30)]),
      assessor.classify([item(identifier: "replacement")]),
      [],
    ]
    for changed in changedInventories {
      #expect(AppModel.inventoryRequiresReveal(previous: original, current: changed,
        previousWindows: [1], currentWindows: [1]))
    }
    #expect(AppModel.inventoryRequiresReveal(
      previous: assessor.classify([item(index: 0), item(index: 1)]),
      current: assessor.classify([item(index: 0), item(index: 1), item(index: 2)]),
      previousWindows: [1], currentWindows: [1]))
    #expect(AppModel.inventoryRequiresReveal(previous: original, current: original,
      previousWindows: [1], currentWindows: [1, 2]))
  }

  private func item(bundle: String = "example.timer", pid: Int32 = 10,
    index: Int = 0, identifier: String? = nil, title: String = "ready", x: Double = 1100
  ) -> RawSourceItemObservation {
    RawSourceItemObservation(runtimeID: "\(pid):\(index)", processIdentifier: pid,
      bundleIdentifier: bundle, applicationName: "Fixture", role: "AXMenuBarItem",
      frame: ItemFrame(x: x, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(identifierCandidate: identifier, title: title),
      observedOrder: index)
  }
}

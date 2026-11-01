import AppKit
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Concealment recovery", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct ConcealmentRecoveryTests {
  @Test("Two scans with unknown geometry reveal temporarily and retain saved-layout recovery")
  func unknownGeometryRecovers() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let saved = model.layout

    var reads = 0
    model.validateConcealment { _ in reads += 1; return nil }
    #expect(model.concealed)
    #expect(model.reapplyNotBefore == nil)
    #expect(reads == model.items.count)

    let beforeReveal = Date()
    model.validateConcealment { _ in nil }
    #expect(!model.concealed)
    let retry = try #require(model.reapplyNotBefore)
    #expect(retry >= beforeReveal.addingTimeInterval(3))
    #expect(model.layout == saved)

    model.reveal()
    #expect(model.reapplyNotBefore == nil)
  }

  @Test("A safe scan clears a single unknown-geometry observation")
  func safeScanResetsDebounce() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model

    model.validateConcealment { _ in nil }
    model.validateConcealment { $0.identity.persistentKey == Fixture.hidden }
    model.validateConcealment { _ in nil }
    #expect(model.concealed)
    #expect(model.reapplyNotBefore == nil)
  }

  @Test("A confirmed unassigned or protected source behind the boundary stays revealed for review")
  func confirmedUnsafeSourceDoesNotRecover() {
    for protected in [false, true] {
      let fixture = Fixture()
      defer { fixture.close() }
      let model = fixture.model
      if protected {
        let original = model.items[1]
        model.items[1] = ClassifiedSourceItem(observation: original.observation,
          identity: original.identity,
          manageability: ManageabilityAssessment(status: .protected, reason: "fixture"))
        model.layout.items[1].placement = .dropdown
      }

      for _ in 0..<2 { model.validateConcealment { _ in true } }
      #expect(!model.concealed)
      #expect(model.reapplyNotBefore == nil)
    }
  }

  @Test("Confirmed unsafe placement wins over unknown geometry in the same scan")
  func confirmedUnsafePlacementWins() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model

    for _ in 0..<2 {
      model.validateConcealment { $0.identity.persistentKey == Fixture.hidden ? nil : true }
    }
    #expect(!model.concealed)
    #expect(model.reapplyNotBefore == nil)
    #expect(model.message == "An unassigned or protected item is behind the separator. Items have been revealed.")
  }
}

@MainActor
private final class Fixture {
  static let hidden = "example.hidden"
  let model: AppModel
  private let launcher: NSStatusItem
  private let preferenceKeys: [String]
  private let previousPreferences: [String: Any]

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
    preferenceKeys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let defaults = UserDefaults.standard
    previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    model = AppModel(native: NativeMenuBarController(launcher: launcher), store: nil)
    launcher.isVisible = false
    model.permissionGranted = true
    model.scanComplete = true
    model.layout.items = [SavedItem(id: Self.hidden, placement: .dropdown), SavedItem(id: "example.bar")]
    model.items = IdentityAssessor().classify(model.layout.items.enumerated().map { index, saved in
      RawSourceItemObservation(runtimeID: "fixture:\(index)", processIdentifier: Int32(100 + index),
        bundleIdentifier: saved.id, applicationName: saved.id, role: "AXMenuBarItem",
        frame: ItemFrame(x: index == 0 ? -100 : 1200, y: 6, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: index,
        isOnscreen: index != 0)
    })
    model.concealed = true
  }

  func close() {
    model.stop()
    NativeMenuBarController.removePreservingPosition(launcher)
    let defaults = UserDefaults.standard
    for key in preferenceKeys {
      if let value = previousPreferences[key] { defaults.set(value, forKey: key) }
      else { defaults.removeObject(forKey: key) }
    }
    defaults.synchronize()
  }
}

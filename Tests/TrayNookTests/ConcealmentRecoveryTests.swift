import AppKit
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Concealment recovery", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct ConcealmentRecoveryTests {
  @Test("Repeated incomplete reads keep an unchanged native section concealed")
  func unchangedWindowsStayConcealed() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let initial = fixture.snapshot()
    model.accept(initial)
    model.concealed = true
    let saved = model.layout
    let observed = model.items

    for _ in 0..<8 {
      #expect(!model.acceptScanStatus(fixture.snapshot(complete: false)))
      #expect(model.concealed)
      #expect(!model.scanComplete)
      #expect(!model.canEdit)
      #expect(model.reapplyNotBefore == nil)
      #expect(model.layout == saved)
      #expect(model.items == observed)
    }

    #expect(model.acceptScanStatus(initial))
    #expect(model.canEdit)
    #expect(model.concealed)
  }

  @Test("Changed or unavailable native windows still require scan recovery",
    arguments: ["added", "moved", "owner", "visibility", "missing", "permission", "stale"])
  func changedWindowsRecover(_ change: String) {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot())
    model.concealed = true
    let saved = model.layout
    let observed = model.items
    var windows = fixture.windows
    let first = windows[0]
    switch change {
    case "added": windows.append(StatusWindowState(processIdentifier: 102, windowIdentifier: 102,
      frame: ItemFrame(x: 1250, y: 6, width: 24, height: 24), isOnscreen: true))
    case "moved": windows[0] = StatusWindowState(processIdentifier: first.processIdentifier,
      windowIdentifier: first.windowIdentifier,
      frame: ItemFrame(x: -200, y: 6, width: 24, height: 24), isOnscreen: first.isOnscreen)
    case "owner": windows[0] = StatusWindowState(processIdentifier: 999,
      windowIdentifier: first.windowIdentifier, frame: first.frame, isOnscreen: first.isOnscreen)
    case "visibility": windows[0] = StatusWindowState(processIdentifier: first.processIdentifier,
      windowIdentifier: first.windowIdentifier, frame: first.frame, isOnscreen: !first.isOnscreen)
    default: break
    }
    let snapshot = fixture.snapshot(complete: false, windows: change == "missing" ? nil : windows,
      permission: change == "permission" ? .denied : .granted,
      capturedAt: change == "stale" ? .distantPast : Date())
    for _ in 0..<4 { #expect(!model.acceptScanStatus(snapshot)) }
    #expect(!model.concealed)
    #expect(!model.canEdit)
    #expect(model.layout == saved)
    #expect(model.items == observed)
    #expect(model.reapplyNotBefore != nil)
  }

  @Test("Reveal invalidates the previously verified native windows")
  func revealInvalidatesWindowBaseline() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot())
    model.reveal()
    model.concealed = true
    for _ in 0..<4 { #expect(!model.acceptScanStatus(fixture.snapshot(complete: false))) }
    #expect(!model.concealed)
  }

  @Test("An unverified concealment scan cannot become a stable-window baseline")
  func unsafeGeometryStillRecovers() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot())
    model.concealed = true
    model.validateConcealment { _ in nil }
    for _ in 0..<4 { #expect(!model.acceptScanStatus(fixture.snapshot(complete: false))) }
    #expect(!model.concealed)
    #expect(model.reapplyNotBefore != nil)
  }

  @Test("Malformed Accessibility geometry reaches safety recovery without crashing diagnostics")
  func malformedGeometryRecovers() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let saved = model.layout
    let original = try #require(model.items.first).observation
    for component in 0..<4 {
      for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int.max)] {
        model.reveal()
        model.concealed = true
        var geometry: [Double] = [-100, 6, 24, 24]
        geometry[component] = value
        model.items[0] = try #require(IdentityAssessor().classify([
          RawSourceItemObservation(runtimeID: original.runtimeID, processIdentifier: original.processIdentifier,
            bundleIdentifier: original.bundleIdentifier, applicationName: original.applicationName,
            role: original.role,
            frame: ItemFrame(x: geometry[0], y: geometry[1], width: geometry[2], height: geometry[3]),
            actions: original.actions, metadata: original.metadata, observedOrder: original.observedOrder)
        ]).first)

        model.validateConcealment { $0.identity.persistentKey == Fixture.hidden ? nil : false }
        model.validateConcealment { $0.identity.persistentKey == Fixture.hidden ? nil : false }
        #expect(!model.concealed)
        #expect(model.reapplyNotBefore != nil)
        #expect(model.layout == saved)
      }
    }
  }

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

  var windows: [StatusWindowState] {
    model.items.map { item in
      StatusWindowState(processIdentifier: item.observation.processIdentifier,
        windowIdentifier: UInt32(item.observation.processIdentifier), frame: item.observation.frame!,
        isOnscreen: item.observation.isOnscreen == true)
    }
  }

  func snapshot(complete: Bool = true) -> InventorySnapshot {
    snapshot(complete: complete, windows: windows)
  }

  func snapshot(complete: Bool, windows: [StatusWindowState]?,
    permission: AccessibilityPermissionStatus = .granted, capturedAt: Date = Date()) -> InventorySnapshot {
    InventorySnapshot(capturedAt: capturedAt, permission: permission,
      completeness: complete ? .complete : .incomplete, items: complete ? model.items : [],
      statusWindowRuntimeIDs: Set((windows ?? []).map(\.windowIdentifier)), statusWindows: windows,
      warnings: complete ? [] : ["Fixture app did not respond"],
      metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 2,
        sourceItemCount: complete ? model.items.count : 0))
  }

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

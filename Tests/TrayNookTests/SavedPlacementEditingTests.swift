import AppKit
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Saved placement editing")
@MainActor
struct SavedPlacementEditingTests {
  @Test("A closed app can change its saved placement without a native operation",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  func editsClosedApp() throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let native = NativeMenuBarController(launcher: launcher)
    defer {
      native.remove()
      NSStatusBar.system.removeStatusItem(launcher)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutStore(url: directory.appendingPathComponent("layout.json"))
    let original = SavedLayout(items: [SavedItem(id: "us.zoom.xos"), SavedItem(id: "example.other"),
      SavedItem(id: "com.apple.controlcenter")])
    try store.save(original)
    let model = AppModel(native: native, store: store)
    model.permissionGranted = true
    model.scanComplete = true
    model.undoManager.groupsByEvent = false
    #expect(model.canChoosePlacement("us.zoom.xos"))
    #expect(!model.canChoosePlacement("example.unknown"))
    #expect(!model.canChoosePlacement(model.ownBundle))
    #expect(!model.canChoosePlacement("com.apple.controlcenter"))
    model.setPlacement("com.apple.controlcenter", .dropdown)
    #expect(model.layout == original)

    for placement in [Placement.dropdown, .alwaysHidden, .menuBar] {
      model.undoManager.beginUndoGrouping()
      model.setPlacement("us.zoom.xos", placement)
      model.undoManager.endUndoGrouping()
      #expect(model.layout.items.first { $0.id == "us.zoom.xos" }?.placement == placement)
      #expect(try store.load() == model.layout)
      #expect(!model.busy)
      #expect(model.pendingPlacementKeys.isEmpty)
      #expect(model.layout.items.first { $0.id == "example.other" } == original.items[1])
    }
    #expect(model.undoManager.canUndo)
    model.undoManager.undo()
    #expect(model.layout.items.first { $0.id == "us.zoom.xos" }?.placement == .alwaysHidden)
    #expect(try store.load() == model.layout)
    model.undoManager.redo()
    #expect(model.layout.items.first { $0.id == "us.zoom.xos" }?.placement == .menuBar)

    model.permissionGranted = false
    model.setPlacement("us.zoom.xos", .dropdown)
    #expect(model.layout.items.first { $0.id == "us.zoom.xos" }?.placement == .menuBar)
    model.permissionGranted = true
    model.busy = true
    model.setPlacement("us.zoom.xos", .dropdown)
    #expect(model.layout.items.first { $0.id == "us.zoom.xos" }?.placement == .menuBar)
    model.busy = false

    // A returning source keeps the edited placement and rejoins the dropdown.
    model.undoManager.beginUndoGrouping()
    model.setPlacement("us.zoom.xos", .dropdown)
    model.undoManager.endUndoGrouping()
    let observation = RawSourceItemObservation(runtimeID: "zoom:0", processIdentifier: 100,
      bundleIdentifier: "us.zoom.xos", applicationName: "Zoom", role: "AXMenuBarItem",
      frame: ItemFrame(x: 1200, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 0)
    let live = try #require(IdentityAssessor().classify([observation]).first)
    model.items = [live]
    #expect(model.dropdownItems == [live])
    #expect(try store.load() == model.layout)

    let blocked = model.layout
    model.items = [ClassifiedSourceItem(observation: live.observation, identity: live.identity,
      manageability: ManageabilityAssessment(status: .protected, reason: "fixture"))]
    #expect(!model.canChoosePlacement("us.zoom.xos"))
    model.setPlacement("us.zoom.xos", .alwaysHidden)
    #expect(model.layout == blocked)

    model.items = [live, live]
    #expect(!model.canChoosePlacement("us.zoom.xos"))
    model.items = [ClassifiedSourceItem(observation: live.observation,
      identity: IdentityAssessment(status: .ambiguous, provisionalKey: nil, reason: "fixture"),
      manageability: live.manageability)]
    #expect(!model.canChoosePlacement("us.zoom.xos"))
    model.setPlacement("us.zoom.xos", .alwaysHidden)
    #expect(model.layout == blocked)
  }
}

import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Selective Menu Bar placement")
@MainActor
struct SelectivePlacementTests {
  private let safe = ItemFrame(x: 900, y: 0, width: 540, height: 24)
  private let display = ItemFrame(x: 0, y: 0, width: 1440, height: 900)
  private let boundary = ItemFrame(x: -1560, y: 0, width: 2562, height: 24)

  @Test("A returning source goes before the leftmost visible item, including protected system items")
  func choosesLeftmostVisibleSource() throws {
    let source = item("example.source", x: -1600)
    let system = item("com.apple.controlcenter", x: 1050)
    let app = item("example.visible", x: 1150)
    let candidates = [app, source, system]
    #expect(anchor(candidates, excluding: source)?.observation.runtimeID == system.observation.runtimeID)
    #expect(system.manageability.status == .protected)
  }

  @Test("Clipped, hidden, unrelated-row, and source windows cannot become the visible anchor")
  func rejectsUnsafeAnchors() {
    let source = item("example.source", x: 1040)
    let visible = item("example.visible", x: 1100)
    let candidates = [source, item("example.hidden", x: -1600),
      item("example.clipped", x: 1020, onscreen: false),
      item("example.other-row", x: 1020, y: -1440),
      item("example.cutoff", x: 895), visible]
    #expect(anchor(candidates, excluding: source)?.observation.runtimeID == visible.observation.runtimeID)
    #expect(anchor([source], excluding: source) == nil)
  }

  @Test("Explicit preview destinations preserve the requested system or app anchor and terminal slot")
  func preservesExplicitAnchors() throws {
    let source = item("example.source", x: -1600, window: 10)
    let system = item("com.apple.controlcenter", x: 1050, window: 20)
    let app = item("example.visible", x: 1150, window: 30)
    let candidates = [source, system, app]
    for target in [system, app] {
      #expect(try explicitAnchor(.before(target), items: candidates, source: source) == target)
    }
    #expect(try explicitAnchor(.beforeLauncher, items: candidates, source: source) == nil)
    #expect(try explicitAnchor(.leftmost, items: candidates, source: source) == system)

    let replacement = item("example.visible", x: 1150, window: 31)
    for current in [[source, system], [source, system, replacement], [source, system, app, app]] {
      #expect(throws: (any Error).self) {
        try explicitAnchor(.before(app), items: current, source: source)
      }
    }
    #expect(throws: (any Error).self) {
      try explicitAnchor(.before(source), items: candidates, source: source)
    }
  }

  @Test("Showing one source reserves room without pushing the boundary behind the safe edge")
  func checksCapacity() {
    let anchor = ItemFrame(x: 1050, y: 0, width: 24, height: 24)
    #expect(NativeMenuBarController.canShowWhileConcealed(sourceWidth: 24,
      anchor: anchor, boundary: boundary, safeFrame: safe))
    for width in [Double.nan, .infinity, 0, -1, 101] {
      #expect(!NativeMenuBarController.canShowWhileConcealed(sourceWidth: width,
        anchor: anchor, boundary: boundary, safeFrame: safe))
    }
    #expect(!NativeMenuBarController.canShowWhileConcealed(sourceWidth: 24,
      anchor: ItemFrame(x: 910, y: 0, width: 24, height: 24), boundary: boundary, safeFrame: safe))
  }

  private func anchor(_ items: [ClassifiedSourceItem], excluding source: ClassifiedSourceItem) -> ClassifiedSourceItem? {
    NativeMenuBarController.leftmostVisibleSource(in: items, excluding: source.observation.runtimeID,
      boundary: boundary, safeFrame: safe, displayFrame: display)
  }

  private func explicitAnchor(_ placement: NativeMenuBarController.VisiblePlacement,
    items: [ClassifiedSourceItem], source: ClassifiedSourceItem) throws -> ClassifiedSourceItem? {
    try NativeMenuBarController.visiblePlacementAnchor(for: placement, in: items,
      excluding: source.observation.runtimeID, boundary: boundary, safeFrame: safe, displayFrame: display)
  }

  private func item(_ bundle: String, x: Double, y: Double = 0, onscreen: Bool = true,
    window: UInt32? = nil) -> ClassifiedSourceItem {
    IdentityAssessor().classify([RawSourceItemObservation(runtimeID: bundle, processIdentifier: 100,
      bundleIdentifier: bundle, applicationName: bundle, role: "AXMenuBarItem",
      frame: ItemFrame(x: x, y: y, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 0, isOnscreen: onscreen,
      statusWindowIdentifier: window)])[0]
  }
}

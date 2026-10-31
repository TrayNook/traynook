import AppKit
import InventoryIdentityCore
import SwiftUI
import Testing

@testable import TrayNook

@Suite("Drag rendering", .serialized)
@MainActor
struct DragRenderingTests {
  // GUI session required. Records main-thread layout cost, not display FPS:
  // TRAYNOOK_APPKIT_TESTS=1 Scripts/test.sh --filter DragRenderingTests
  @Test("Measure preview pointer and slot rendering costs",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  func previewSlotCrossings() async throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let defaults = UserDefaults.standard
    let keys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)", "NSStatusItem VisibleCC \(name)"]
    }
    let previous = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let native = NativeMenuBarController(launcher: launcher)
    defer {
      native.remove()
      NSStatusBar.system.removeStatusItem(launcher)
      for key in keys {
        if let value = previous[key] { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    let model = AppModel(native: native, store: nil)
    model.permissionGranted = true
    model.scanComplete = true
    model.layout = SavedLayout(rowCapacity: 10, items: (0..<24).map {
      SavedItem(id: "example.fixture\($0)", placement: .dropdown)
    })
    model.items = IdentityAssessor().classify((0..<24).map { index in
      RawSourceItemObservation(runtimeID: "fixture\(index)", processIdentifier: 100,
        bundleIdentifier: "example.fixture\(index)", applicationName: "Fixture \(index)",
        role: "AXMenuBarItem", frame: ItemFrame(x: 1200, y: 0, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(identifierCandidate: "fixture"),
        observedOrder: index)
    })
    let session = PreviewDragSession()
    let image = try #require(NSImage(systemSymbolName: "app", accessibilityDescription: nil))
    let host = LayoutCountingHost(rootView: LayoutPreviewView(model: model, drag: session)
      .overlay(alignment: .topLeading) { PreviewFloatingIcon(pointer: session.pointer, image: image) })
    let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 760, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { session.cancel(); window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    #expect(session.begin("example.fixture0", layout: model.layout) { _, _, _ in
      Issue.record("Benchmark must not save the draft"); return false
    })
    var pointerRenderTimes: [Double] = []
    host.layoutCount = 0
    for tick in 0..<120 {
      let start = ContinuousClock.now
      session.pointer.location = CGPoint(x: 150 + tick, y: 150)
      host.layoutSubtreeIfNeeded()
      let components = start.duration(to: .now).components
      pointerRenderTimes.append(Double(components.seconds) + Double(components.attoseconds) / 1e18)
      try await Task.sleep(for: .milliseconds(8))
    }
    let pointerSorted = pointerRenderTimes.sorted()
    print("PREVIEW_POINTER_RENDER: median=\(pointerSorted[60] * 1000)ms, p95=\(pointerSorted[114] * 1000)ms, host layouts=\(host.layoutCount)")
    host.layoutCount = 0
    var renderTimes: [Double] = []
    for tick in 0..<120 {
      let start = ContinuousClock.now
      session.pointer.location = CGPoint(x: 150 + tick % 400, y: 150)
      session.move(to: .dropdown, before: "example.fixture\(tick % 23 + 1)")
      host.layoutSubtreeIfNeeded()
      let components = start.duration(to: .now).components
      renderTimes.append(Double(components.seconds) + Double(components.attoseconds) / 1e18)
      try await Task.sleep(for: .milliseconds(8))
    }
    let sorted = renderTimes.sorted()
    print("PREVIEW_RENDER: 24 icons / 120 slot crossings: median=\(sorted[60] * 1000)ms, p95=\(sorted[114] * 1000)ms, max=\(sorted.last! * 1000)ms, host layouts=\(host.layoutCount)")
    #expect(session.draft != model.layout)
    #expect(session.draft?.items.count == model.layout.items.count)
    session.cancel()
    #expect(session.draft == nil)
    #expect(model.layout.items.first?.id == "example.fixture0")
  }

  @Test("Pointer motion keeps resting detail rows unchanged",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  func restingRows() async throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let pointer = DetailReorderPointer()
    let probe = RenderProbe()
    let content = VStack(spacing: 8) {
      ForEach(0..<24) { index in
        HStack {
          Text("Fixture \(index)")
          Spacer()
          Button("Menu Bar") {}
          RenderWitness(probe: probe, index: index).frame(width: 1, height: 1)
        }
        .frame(height: 44)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
          probe.positions[index] = origin
          probe.geometryUpdates[index, default: 0] += 1
        }
        .modifier(DetailReorderRow(pointer: pointer, dragged: index == 0))
      }
    }
    let host = LayoutCountingHost(rootView: content)
    let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 500, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    probe.updates = [:]
    probe.geometryUpdates = [:]
    let initialPosition = probe.positions[0]
    host.layoutCount = 0
    let start = ContinuousClock.now
    for offset in 1...120 {
      pointer.offset = CGFloat(offset)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(2))
    }
    let duration = start.duration(to: .now)
    let restingUpdates = probe.updates.filter { $0.key != 0 }.values.reduce(0, +)
    print("DETAIL_RENDER: 120 pointer updates / 24 rows: \(duration), resting view updates=\(restingUpdates), dragged geometry updates=\(probe.geometryUpdates[0, default: 0]), host layouts=\(host.layoutCount)")
    #expect(probe.geometryUpdates[0, default: 0] > 0)
    let initialY = try #require(initialPosition?.y)
    let finalY = try #require(probe.positions[0]?.y)
    #expect(abs(finalY - initialY - 120) < 0.5)
    #expect(probe.geometryUpdates.filter { $0.key != 0 }.values.reduce(0, +) == 0)
    #expect(restingUpdates == 0)
  }
}

@MainActor
private final class RenderProbe {
  var updates: [Int: Int] = [:]
  var geometryUpdates: [Int: Int] = [:]
  var positions: [Int: CGPoint] = [:]
}

private struct RenderWitness: NSViewRepresentable {
  let probe: RenderProbe
  let index: Int

  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    probe.updates[index, default: 0] += 1
  }
}

@MainActor
private final class LayoutCountingHost<Content: View>: NSHostingView<Content> {
  var layoutCount = 0
  override func layout() {
    layoutCount += 1
    super.layout()
  }
}

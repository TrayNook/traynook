import AppKit
import InventoryIdentityCore
import SwiftUI
import Testing

@testable import TrayNook

@Suite("Saved layout preview")
@MainActor
struct LayoutPreviewTests {
  @Test("Dropdown fits its controls instead of reserving empty columns")
  func compactColumns() {
    #expect(DropdownView.columnCount(rowCapacity: 10, controlCount: 6, maximumWidth: 700) == 6)
    #expect(DropdownView.columnCount(rowCapacity: 3, controlCount: 6, maximumWidth: 700) == 3)
    #expect(DropdownView.columnCount(rowCapacity: 30, controlCount: 31, maximumWidth: 112) == 2)
    #expect(DropdownView.columnCount(rowCapacity: 10, controlCount: 1, maximumWidth: 700) == 1)
  }

  @Test("Small icon grids keep compact margins while footers stay readable")
  func compactGridWidths() {
    let cases: [(Int, CGFloat)] = [(1, 64), (2, 108), (3, 152), (4, 196)]
    for (columns, width) in cases {
      #expect(DropdownView.contentWidth(columns: columns, hasFooter: false) == width)
      #expect(DropdownView.contentWidth(columns: columns, hasFooter: true) == max(180, width))
    }
  }

  // Opt in only in an exclusive macOS GUI session, outside the sandbox:
  // TRAYNOOK_PREVIEW_SNAPSHOT=/tmp/traynook-preview.png Scripts/test.sh --filter LayoutPreviewTests
  @Test("Preview preserves homes and order, protects sources, and wraps the shared grid",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_PREVIEW_SNAPSHOT"] != nil))
  func rendersPreview() throws {
    let output = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["TRAYNOOK_PREVIEW_SNAPSHOT"]))
    let productionIDs = ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"]
    try #require(!productionIDs.contains(Bundle.main.bundleIdentifier ?? ""))
    for id in productionIDs {
      try #require(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
        "Quit TrayNook before rendering this isolated GUI test.")
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let defaults = UserDefaults.standard
    let keys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let previous = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    let launcher = NSStatusBar.system.statusItem(withLength: 24)
    let native = NativeMenuBarController(launcher: launcher)
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      for key in keys {
        if let value = previous[key] { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
      defaults.synchronize()
    }
    let model = AppModel(native: native, store: nil)
    model.permissionGranted = true
    model.scanComplete = true
    // Use familiar installed icons when available, but keep all observations
    // synthetic and every test valid on a clean machine.
    let applications = [
      (id: "com.raycast.macos", name: "Raycast"),
      (id: "org.herf.Flux", name: "f.lux"),
      (id: "eu.exelban.Stats", name: "Stats"),
      (id: "me.guillaumeb.MonitorControl", name: "MonitorControl"),
    ].enumerated().map { index, candidate in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.id) != nil
        ? candidate : (id: "example.dropdown\(index)", name: "Fixture \(index + 1)")
    }
    model.layout = SavedLayout(rowCapacity: 3, items: [
      SavedItem(id: applications[0].id, placement: .dropdown),
      SavedItem(id: "example.timer"),
      SavedItem(id: "com.apple.controlcenter", placement: .alwaysHidden),
      SavedItem(id: applications[1].id, placement: .dropdown),
      SavedItem(id: "example.multiple", placement: .dropdown),
      SavedItem(id: "example.hidden", placement: .alwaysHidden),
      SavedItem(id: "example.hidden2", placement: .alwaysHidden),
      SavedItem(id: "example.hidden3", placement: .alwaysHidden),
      SavedItem(id: "example.missing", placement: .dropdown),
      SavedItem(id: applications[2].id, placement: .dropdown),
      SavedItem(id: "example.weather"),
      SavedItem(id: applications[3].id, placement: .dropdown),
    ])
    model.items = IdentityAssessor().classify([
      item(applications[3].id, name: applications[3].name),
      item(applications[1].id, name: applications[1].name),
      item("example.timer", name: "Timer"),
      item("com.apple.controlcenter", name: "System"),
      item(applications[0].id, name: applications[0].name),
      item("example.multiple", name: "Multiple", index: 0),
      item("example.multiple", name: "Multiple", index: 1),
      item("example.hidden", name: "Hidden"),
      item("example.hidden2", name: "Hidden 2"),
      item("example.hidden3", name: "Hidden 3"),
      item(applications[2].id, name: applications[2].name),
      item("example.weather", name: "Weather"),
    ])
    let preview = LayoutPreviewView(model: model)
    // Ambiguous siblings have no persistent identity, so no lane lists them.
    #expect(preview.items(in: .menuBar).map(\.id) == [
      "example.timer", "com.apple.controlcenter", "example.weather",
    ])
    #expect(preview.items(in: .alwaysHidden).map(\.id) == ["example.hidden", "example.hidden2", "example.hidden3"])
    let dropdown = applications.map(\.id)
    #expect(preview.items(in: .dropdown).map(\.id) == dropdown)
    #expect(model.dropdownItems.compactMap { $0.observation.bundleIdentifier } == dropdown)
    #expect(!Placement.allCases.flatMap { preview.items(in: $0) }.contains { $0.id == "example.missing" })
    let originalLayout = model.layout
    let reordered = [applications[1].id, applications[0].id, applications[2].id, applications[3].id]
    model.setOrder(reordered, undoable: false)
    #expect(preview.items(in: .dropdown).map(\.id) == reordered)
    #expect(model.dropdownItems.compactMap { $0.observation.bundleIdentifier } == reordered)
    model.setOrder(applications.map(\.id), undoable: false)
    #expect(model.layout == originalLayout)
    // A lane order with an unknown key or a missing key changes nothing.
    model.setOrder(["example.unknown"] + applications.map(\.id), undoable: false)
    #expect(model.layout == originalLayout)

    let columns = DropdownView.columnCount(rowCapacity: model.layout.rowCapacity,
      controlCount: model.dropdownItems.count + 1, maximumWidth: 650)
    #expect(columns == 3)
    // Settings consumes the first grid cell: the four live sources occupy two
    // rows with capacity 3 and three rows at the narrower two-column width.
    #expect((model.dropdownItems.count + 1 + columns - 1) / columns == 2)
    #expect(DropdownView.columnCount(rowCapacity: 3, controlCount: 5, maximumWidth: 112) == 2)

    try snapshot(preview.frame(width: 650), to: output)
    let settingsOutput = URL(fileURLWithPath: output.deletingPathExtension().path + "-settings.png")
    try snapshot(SettingsView(model: model), size: NSSize(width: 760, height: 590),
      to: settingsOutput, checkScrolling: true, minimumScrollDistance: 100, expectedPreview: true)
    for capacity in [1, 30] {
      model.layout.rowCapacity = capacity
      #expect(DropdownView.columnCount(rowCapacity: capacity, controlCount: 5, maximumWidth: 700)
        == (capacity == 1 ? 1 : 5))
      let edgeOutput = URL(fileURLWithPath:
        output.deletingPathExtension().path + "-settings-capacity-\(capacity).png")
      try snapshot(SettingsView(model: model), size: NSSize(width: 760, height: 590),
        to: edgeOutput, checkScrolling: true, minimumScrollDistance: 100, expectedPreview: true)
    }
    model.screenRecordingGranted = true
    for (tab, name) in [(1, "permissions"), (2, "general")] {
      model.selectedTab = tab
      let tabOutput = URL(fileURLWithPath:
        output.deletingPathExtension().path + "-settings-\(name).png")
      try snapshot(SettingsView(model: model), size: NSSize(width: 760, height: 590),
        to: tabOutput, checkScrolling: true, expectedPreview: false)
    }
    model.selectedTab = 1
    model.permissionGranted = false
    model.screenRecordingGranted = false
    let permissionsOutput = URL(fileURLWithPath:
      output.deletingPathExtension().path + "-settings-permissions-ungranted.png")
    try snapshot(SettingsView(model: model), size: NSSize(width: 760, height: 590),
      to: permissionsOutput, checkScrolling: true, expectedPreview: false)
    model.selectedTab = 2
    let generalOutput = URL(fileURLWithPath:
      output.deletingPathExtension().path + "-settings-general-ungranted.png")
    try snapshot(SettingsView(model: model), size: NSSize(width: 760, height: 590),
      to: generalOutput, checkScrolling: true, expectedPreview: false)
  }

  private func snapshot<Content: View>(_ content: Content, size requestedSize: NSSize? = nil,
    to output: URL, checkScrolling: Bool = false, minimumScrollDistance: CGFloat = 0,
    expectedPreview: Bool? = nil) throws {
    let host = NSHostingView(rootView: content)
    let size = requestedSize ?? host.fittingSize
    try #require(size.width.isFinite && size.height.isFinite && size.width >= 650 && size.height > 100)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    host.layoutSubtreeIfNeeded()
    try #require(host.fittingSize.height.isFinite && host.bounds.height.isFinite)
    try #require(host.bounds.width <= size.width + 1 && host.bounds.height <= size.height + 1)
    if let expectedPreview {
      #expect(previewSurfaces(in: host).count == (expectedPreview ? 1 : 0),
        "The interactive layout preview belongs only to the Layout tab.")
    }
    if checkScrolling {
      let scroll = try #require(scrollViews(in: host).max {
        $0.bounds.width < $1.bounds.width
      })
      let document = try #require(scroll.documentView)
      try #require(document.bounds.width <= scroll.contentView.bounds.width + 1,
        "Settings content must fit horizontally at the minimum window width.")
      let overflow = max(0, document.bounds.height - scroll.contentView.bounds.height)
      try #require(overflow >= minimumScrollDistance)
      if overflow > 1 {
        let initial = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: initial.x,
          y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try #require(scroll.contentView.bounds.origin.y > initial.y + max(0, overflow - 1),
          "All vertically overflowing Settings content must remain reachable.")
        scroll.contentView.scroll(to: initial)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
      }
    }
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try #require(bitmap.pixelsWide >= 650 && bitmap.pixelsHigh > 100 && png.count > 1_000)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output, options: .atomic)
    print("Preview snapshot: \(output.path)")
  }

  private func scrollViews(in view: NSView) -> [NSScrollView] {
    let current = (view as? NSScrollView).map { [$0] } ?? []
    return current + view.subviews.flatMap { scrollViews(in: $0) }
  }

  private func previewSurfaces(in view: NSView) -> [PreviewDragSurface.Surface] {
    let current = (view as? PreviewDragSurface.Surface).map { [$0] } ?? []
    return current + view.subviews.flatMap { previewSurfaces(in: $0) }
  }

  private func item(_ bundle: String, name: String, index: Int = 0) -> RawSourceItemObservation {
    RawSourceItemObservation(runtimeID: "\(bundle):\(index)", processIdentifier: 100,
      bundleIdentifier: bundle, applicationName: name, role: "AXMenuBarItem",
      frame: ItemFrame(x: 1200, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(identifierCandidate: index == 0 ? "fixture" : nil), observedOrder: index)
  }
}

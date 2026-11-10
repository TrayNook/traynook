import AppKit
import CryptoKit
import InventoryIdentityCore
import SwiftUI
import Testing

@testable import TrayNook

@Suite("Native website visuals")
@MainActor
struct WebsiteSnapshotTests {
  // Opt in only in a macOS GUI session; the fixture never starts discovery or native movement.
  @Test("Export production Settings and Dropdown with an isolated example layout",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_WEBSITE_SNAPSHOTS"] != nil))
  func exportNativeViews() throws {
    let output = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["TRAYNOOK_WEBSITE_SNAPSHOTS"]), isDirectory: true)
    try #require(!["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"]
      .contains(Bundle.main.bundleIdentifier ?? ""))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let application = NSApplication.shared
    let previousPolicy = application.activationPolicy()
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)
    defer { application.setActivationPolicy(previousPolicy) }

    let defaults = try #require(UserDefaults(suiteName: "example.TrayNook.WebsiteSnapshot"))
    defaults.setVolatileDomain(["dropdownGlyphs": false], forName: UserDefaults.argumentDomain)
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let metadata = WindowMetadataReader(load: { _ in
      preconditionFailure("A website snapshot must not read native window metadata.")
    })
    let native = NativeMenuBarController(launcher: launcher, metadataReader: metadata,
      restoreSavedPositions: false)
    let icons = ApplicationIconCache(resolveApplication: { bundle in
      let paths = [
        "example.timer": "/System/Applications/Clock.app",
        "example.weather": "/System/Applications/Weather.app",
        "example.notes": "/System/Applications/Notes.app",
        "example.calendar": "/System/Applications/Calendar.app",
        "example.music": "/System/Applications/Music.app",
        "example.cloud": "/System/Applications/Reminders.app",
      ]
      precondition(paths[bundle] != nil, "Only fixed example icons may be loaded.")
      return paths[bundle].map { URL(fileURLWithPath: $0) }
    })
    let model = AppModel(native: native, store: nil,
      loginItemStatus: LoginItemStatus(read: { .notRegistered },
        register: { preconditionFailure("No login-item changes in a snapshot.") },
        unregister: { preconditionFailure("No login-item changes in a snapshot.") }),
      currentAccessibilityPermission: {
        preconditionFailure("A website snapshot must not query Accessibility inventory.")
      }, inventoryScanner: WebsiteSnapshotScanner(), sourceStatusSnapshot: {
        preconditionFailure("A website snapshot must not read status windows.")
      }, applicationIcons: icons)
    defer {
      model.stop()
      NativeMenuBarController.removePreservingPosition(launcher)
    }
    model.permissionGranted = true
    model.scanComplete = true
    model.screenRecordingGranted = false
    let fixtures: [(String, String, Placement)] = [
      ("timer", "Timer", .menuBar), ("weather", "Weather", .menuBar),
      ("notes", "Notes", .dropdown), ("calendar", "Calendar", .dropdown),
      ("music", "Music", .dropdown), ("cloud", "Cloud", .alwaysHidden),
    ]
    model.layout = SavedLayout(rowCapacity: 4, items: fixtures.map {
      SavedItem(id: "example.\($0.0)", placement: $0.2)
    })
    model.items = IdentityAssessor().classify(fixtures.enumerated().map { index, fixture in
      RawSourceItemObservation(runtimeID: "example.\(fixture.0):0", processIdentifier: 100,
        bundleIdentifier: "example.\(fixture.0)", applicationName: fixture.1,
        role: "AXMenuBarItem", frame: ItemFrame(x: 0, y: 0, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(identifierCandidate: "fixture"),
        observedOrder: index, isOnscreen: false, statusWindowIdentifier: nil)
    })
    try #require(model.items.allSatisfy {
      $0.observation.bundleIdentifier?.hasPrefix("example.") == true
        && $0.observation.isOnscreen == false && $0.observation.statusWindowIdentifier == nil
    })
    try #require(model.dropdownItems.count == 3 && model.canEdit)
    var exported: [[String: Any]] = []
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let appearance = try #require(NSAppearance(named: appearanceName))
      let updates = UpdateController(publicKey: nil, isProduction: false,
        automaticChecksAllowed: false,
        cacheDirectory: output.appendingPathComponent("unused-update-cache"), defaults: defaults)
      defer { updates.stop() }
      let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      settings.isReleasedWhenClosed = false
      settings.title = "TrayNook Settings"
      settings.appearance = appearance
      settings.contentViewController = NSHostingController(rootView:
        SettingsView(model: model, updates: updates).defaultAppStorage(defaults))
      settings.setContentSize(NSSize(width: 820, height: 650))
      settings.center()
      settings.makeKeyAndOrderFront(nil)
      settle(settings)
      exported.append(try snapshot(try #require(settings.contentView?.superview), scale: 2,
        name: "settings-\(name).png", output: output, view: "SettingsView · Layout"))
      settings.close()

      // A private anchor presents the actual AppKit popover without sampling a desktop/status bar.
      let anchor = NSWindow(contentRect: NSRect(x: 300, y: 400, width: 240, height: 80),
        styleMask: [.borderless], backing: .buffered, defer: false)
      anchor.isReleasedWhenClosed = false
      anchor.appearance = appearance
      anchor.backgroundColor = .windowBackgroundColor
      let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
      anchor.contentView = anchorView
      anchor.orderFront(nil)
      let popover = NSPopover()
      popover.behavior = .applicationDefined
      popover.animates = false
      popover.appearance = appearance
      let host = NSHostingController(rootView:
        DropdownView(model: model, maximumWidth: 700).defaultAppStorage(defaults))
      popover.contentViewController = host
      popover.contentSize = host.view.fittingSize
      popover.show(relativeTo: NSRect(x: 108, y: 60, width: 24, height: 20), of: anchorView, preferredEdge: .minY)
      let popupWindow = try #require(host.view.window)
      settle(popupWindow)
      // AppKit's cached drawing omits the popover's WindowServer mask/shadow; export honest content only.
      exported.append(try snapshot(host.view, scale: 4,
        name: "dropdown-\(name).png", output: output, view: "DropdownView · native NSPopover content, without external chrome"))
      popover.close()
      anchor.close()
    }
    try #require(model.proxyImages.isEmpty)
    try writeManifest(exported, output: output)
  }

  private func settle(_ window: NSWindow) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  private func snapshot(_ view: NSView, scale: Int, name: String, output: URL,
    view label: String) throws -> [String: Any] {
    let size = view.bounds.size
    try #require(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try #require(png.count > 1_000)
    let url = output.appendingPathComponent(name)
    try png.write(to: url, options: .atomic)
    print("Native website visual: \(url.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
    return ["file": name, "nativeView": label, "logicalWidth": size.width,
      "logicalHeight": size.height, "pixelWidth": bitmap.pixelsWide,
      "pixelHeight": bitmap.pixelsHigh, "scale": scale,
      "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()]
  }

  private func writeManifest(_ images: [[String: Any]], output: URL) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let sourcePaths = ["Sources/TrayNook/Views.swift", "Sources/TrayNook/LayoutPreviewView.swift",
      "Sources/TrayNook/AppModel.swift", "Sources/TrayNook/ApplicationIconCache.swift",
      "Sources/TrayNook/NativeMenuBarController.swift", "Tests/TrayNookTests/WebsiteSnapshotTests.swift",
      "Scripts/snapshot-website.sh"]
    let hashes = try Dictionary(uniqueKeysWithValues: sourcePaths.map { path in
      (path, SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path)))
        .map { String(format: "%02x", $0) }.joined())
    })
    let info = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Support/Info.plist")))
    let manifest: [String: Any] = [
      "product": "TrayNook", "version": info["CFBundleShortVersionString"] ?? "unknown",
      "build": info["CFBundleVersion"] ?? "unknown",
      "baseCommit": ProcessInfo.processInfo.environment["TRAYNOOK_SNAPSHOT_SOURCE_REVISION"] ?? "working tree",
      "renderer": "Unmodified production SwiftUI views in real AppKit NSWindow and NSPopover, rendered via NSView.cacheDisplay. Settings includes native window chrome; Dropdown exports native popover content only because cached drawing omits the WindowServer arrow mask and shadow. No desktop screenshot or compositing.",
      "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
      "language": "English (the app's current localization)",
      "data": "Fixed example.* observations only; synthetic Timer, Weather, Notes, Calendar, Music, Cloud names. Fixed macOS bundled application icons are illustrative fixture artwork, not a claim that those apps expose these menu-bar items.",
      "privacy": "No running-application discovery, desktop capture, native movement, real app inventory, persisted layouts, or update requests. Item observations are offscreen and have no window identifiers.",
      "sourceSHA256": hashes, "images": images,
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      .write(to: output.appendingPathComponent("provenance.json"), options: .atomic)
  }
}

private struct WebsiteSnapshotScanner: InventoryScanning {
  func scan(promptForPermission: Bool) -> InventorySnapshot {
    preconditionFailure("A website snapshot must not discover running applications.")
  }
}

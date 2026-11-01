import AppKit
import InventoryIdentityCore
import QuartzCore
import SwiftUI
import Testing

@testable import TrayNook

@Suite("Settings scroll performance", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_SCROLL_BENCHMARK"] == "1"))
@MainActor
struct ScrollPerformanceTests {
  // Measures synchronous main-thread work, not display FPS. No native input is posted.
  @Test("Measure Settings scrolling with and without unchanged inventory polls")
  func settingsScroll() async throws {
    for id in ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"] {
      try #require(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
        "Quit TrayNook before creating the isolated visible test controls.")
    }
    NSApplication.shared.setActivationPolicy(.accessory)
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
    native.reveal(keepBoundaryVisible: true)
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      for key in keys {
        if let value = previous[key] { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
      defaults.synchronize()
    }

    let bundles = installedBundles()
    let observations = (0..<30).map { index in
      let bundle = bundles[index % bundles.count]
      return RawSourceItemObservation(runtimeID: "fixture:\(index)", processIdentifier: 100,
        bundleIdentifier: bundle, applicationName: "Fixture \(index)", role: "AXMenuBarItem",
        frame: ItemFrame(x: 1000 + Double(index) * 28, y: 0, width: 24, height: 24),
        actions: ["AXPress"],
        metadata: LiveAccessibilityMetadata(identifierCandidate: "source-\(index)"),
        observedOrder: index)
    }
    let inventory = IdentityAssessor().classify(observations)
    let model = AppModel(native: native, store: nil)
    model.permissionGranted = true
    model.scanComplete = true
    model.layout = SavedLayout(rowCapacity: 9, items: inventory.enumerated().compactMap { index, item in
      guard let key = item.identity.persistentKey else { return nil }
      return SavedItem(id: key, placement: index < 10 ? .menuBar : index < 25 ? .dropdown : .alwaysHidden)
    })
    model.items = inventory
    try await Task.sleep(for: .milliseconds(250))
    #expect(model.layout.items.count == 30)
    let host = NSHostingView(rootView: SettingsView(model: model))
    let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 760, height: 590),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    let scroll = try #require(scrollViews(in: host).max { $0.bounds.width < $1.bounds.width })
    let document = try #require(scroll.documentView)
    let overflow = document.bounds.height - scroll.contentView.bounds.height
    try #require(overflow > 300, "The real Settings detail rows must overflow vertically.")

    for polling in [false, true] {
      var times: [Double] = []
      var pollTimes: [Double] = []
      for step in 0..<360 {
        let start = ContinuousClock.now
        if polling && step % 180 == 178 { model.scanning = true }
        if polling && step % 180 == 0 {
          let pollStart = ContinuousClock.now
          model.accept(InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
            items: inventory, warnings: [],
            metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: bundles.count,
              sourceItemCount: inventory.count)))
          model.scanning = false
          pollTimes.append(milliseconds(since: pollStart))
        }
        let fraction = Double(step % 120) / 119
        let progress = (step / 120) % 2 == 0 ? fraction : 1 - fraction
        scroll.contentView.scroll(to: CGPoint(x: 0, y: overflow * progress))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        times.append(milliseconds(since: start))
        try await Task.sleep(for: .milliseconds(16))
      }
      let sorted = times.sorted()
      let warmed = times.dropFirst(20)
      print("SETTINGS_SCROLL polling=\(polling) rows=30 frames=360 median=\(sorted[180])ms p95=\(sorted[342])ms max=\(sorted.last!)ms warmedMax=\(warmed.max()!)ms pollMax=\(pollTimes.max() ?? 0)ms")
      #expect(times.allSatisfy { $0.isFinite })
      #expect(warmed.allSatisfy { $0 <= 100 },
        "A warmed scrolling step, including poll acceptance and rendering, must not block the main thread for 100 ms.")
    }
  }

  private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
  }

  private func scrollViews(in view: NSView) -> [NSScrollView] {
    let current = (view as? NSScrollView).map { [$0] } ?? []
    return current + view.subviews.flatMap { scrollViews(in: $0) }
  }

  private func installedBundles() -> [String] {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json")
    let layout = (try? LayoutStore(url: url).load()) ?? SavedLayout()
    let candidates = layout.items.map { String($0.id.split(separator: "#")[0]) }
      + ["com.raycast.macos", "org.mozilla.firefox", "com.microsoft.VSCode"]
    let installed = Set(candidates.filter {
      !$0.hasPrefix("com.apple.") && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
    }).sorted()
    return installed.isEmpty ? ["example.fixture"] : Array(installed.prefix(10))
  }
}

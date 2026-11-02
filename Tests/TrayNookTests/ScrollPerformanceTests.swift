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
  // Measures synchronous work and main-loop scheduling gaps, not display FPS. No native input is posted.
  @Test("Measure Settings scrolling concurrently with background inventory inspection")
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
    let model = AppModel(native: native, store: nil, currentAccessibilityPermission: { true })
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
      let polls = PollMeasurements()
      let heartbeat = HeartbeatMeasurements()
      let heartbeatTask = Task { @MainActor in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(2)) }
          catch { break }
          heartbeat.tick()
        }
      }
      var pollTask: Task<Void, Never>?
      defer {
        heartbeatTask.cancel()
        pollTask?.cancel()
        model.scanning = false
      }
      for step in 0..<360 {
        if step == 20 { heartbeat.beginWarmed() }
        let start = ContinuousClock.now
        if polling && step % 180 == 0 {
          #expect(!polls.running, "The benchmark must not accumulate overlapping inventory polls.")
          if !polls.running {
            polls.running = true
            model.scanning = true
            let snapshot = InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
              items: inventory, warnings: [],
              metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: bundles.count,
                sourceItemCount: inventory.count))
            pollTask = Task { @MainActor in
              let pollStart = ContinuousClock.now
              defer { polls.running = false; model.scanning = false }
              let accepted = await model.acceptLatest(snapshot)
              guard !Task.isCancelled else { return }
              polls.latencies.append(milliseconds(pollStart.duration(to: .now)))
              if accepted { polls.accepted += 1 }
            }
          }
        }
        let fraction = Double(step % 120) / 119
        let progress = (step / 120) % 2 == 0 ? fraction : 1 - fraction
        scroll.contentView.scroll(to: CGPoint(x: 0, y: overflow * progress))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        times.append(milliseconds(start.duration(to: .now)))
        try await Task.sleep(for: .milliseconds(16))
      }
      // Worker latency is not UI blocking; await completion outside the frame stopwatch.
      await pollTask?.value
      heartbeatTask.cancel()
      await heartbeatTask.value
      let sorted = times.sorted()
      let warmed = times.dropFirst(20)
      let gaps = heartbeat.gaps.sorted()
      try #require(!gaps.isEmpty && !heartbeat.warmedGaps.isEmpty,
        "The main-actor heartbeat must run during scrolling.")
      print("SETTINGS_SCROLL polling=\(polling) rows=30 frames=360 median=\(sorted[180])ms p95=\(sorted[342])ms max=\(sorted.last!)ms warmedMax=\(warmed.max()!)ms heartbeatMedian=\(gaps[gaps.count / 2])ms heartbeatP95=\(gaps[Int(Double(gaps.count - 1) * 0.95)])ms heartbeatMax=\(gaps.last!)ms warmedHeartbeatMax=\(heartbeat.warmedGaps.max()!)ms acceptedPolls=\(polls.accepted) pollLatencyMax=\(polls.latencies.max() ?? 0)ms")
      #expect(times.allSatisfy { $0.isFinite })
      #expect(warmed.allSatisfy { $0 <= 100 },
        "A warmed synchronous scroll/layout/display step must not block the main thread for 100 ms.")
      #expect(heartbeat.warmedGaps.allSatisfy { $0 <= 100 },
        "Background completion and UI publication must not delay a warmed main-actor heartbeat for 100 ms.")
      if polling { #expect(polls.accepted >= 2, "Both background inspection results must reach the model.") }
    }
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

@MainActor
private final class PollMeasurements {
  var running = false
  var accepted = 0
  var latencies: [Double] = []
}

@MainActor
private final class HeartbeatMeasurements {
  var gaps: [Double] = []
  var warmedGaps: [Double] = []
  private var previous = ContinuousClock.now
  private var warmed = false

  func beginWarmed() {
    previous = .now
    warmed = true
  }

  func tick() {
    let now = ContinuousClock.now
    let gap = milliseconds(previous.duration(to: now))
    gaps.append(gap)
    if warmed { warmedGaps.append(gap) }
    previous = now
  }
}

private func milliseconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

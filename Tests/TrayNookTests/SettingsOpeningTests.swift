import AppKit
import InventoryIdentityCore
import QuartzCore
import SwiftUI
import Testing

@testable import TrayNook

@Suite("Settings opening performance", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_SETTINGS_OPEN_BENCHMARK"] == "1"))
@MainActor
struct SettingsOpeningTests {
  // Run alone in an exclusive macOS GUI session, outside the sandbox, with TrayNook quit:
  // TRAYNOOK_SETTINGS_OPEN_BENCHMARK=1 Scripts/test.sh --filter SettingsOpeningTests
  // Measures content construction, excluding production frame restoration/activation; not display FPS.
  @Test("Measure first opening, retained content, and entry refresh")
  func settingsOpening() async throws {
    for id in ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"] {
      try #require(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
        "Quit TrayNook before creating the isolated Settings window.")
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
    launcher.isVisible = false
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      for key in keys {
        if let value = previous[key] { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
      defaults.synchronize()
    }

    let bundles = try #require(installedBundles().nilIfEmpty,
      "The opening benchmark needs at least one installed application icon.")
    let observations = (0..<30).map { index in
      RawSourceItemObservation(runtimeID: "fixture:\(index)", processIdentifier: 100,
        bundleIdentifier: bundles[index % bundles.count], applicationName: "Fixture \(index)",
        role: "AXMenuBarItem",
        frame: ItemFrame(x: 1000 + Double(index) * 28, y: 0, width: 24, height: 24),
        actions: ["AXPress"],
        metadata: LiveAccessibilityMetadata(identifierCandidate: "source-\(index)"),
        observedOrder: index)
    }
    let inventory = IdentityAssessor().classify(observations)
    let model = AppModel(native: native, store: nil,
      loginItemStatus: LoginItemStatus(read: { .notRegistered }, register: {}, unregister: {}),
      currentAccessibilityPermission: { true })
    model.permissionGranted = true
    model.scanComplete = true
    model.layout = SavedLayout(rowCapacity: 9, items: inventory.enumerated().compactMap { index, item in
      guard let key = item.identity.persistentKey else { return nil }
      return SavedItem(id: key, placement: index < 10 ? .menuBar : index < 25 ? .dropdown : .alwaysHidden)
    })
    model.items = inventory
    #expect(model.layout.items.count == 30)

    let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 760, height: 590),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let manageable = inventory.filter { model.isManageable($0) }.count
    print("SETTINGS_OPEN_FIXTURE savedItems=30 manageable=\(manageable) protected=\(30 - manageable) installedIconBundles=\(bundles.count) polling=false nativeControlsHidden=true")

    var phases: [String: Double] = [:]
    try await measure("firstRoot", window: window) {
      let creation = ContinuousClock.now
      let host = NSHostingView(rootView: SettingsView(model: model))
      phases["hostCreation"] = openingMilliseconds(creation.duration(to: .now))
      let assignment = ContinuousClock.now
      window.contentView = host
      phases["contentAssignment"] = openingMilliseconds(assignment.duration(to: .now))
      let presentation = ContinuousClock.now
      window.orderFront(nil)
      phases["orderFront"] = openingMilliseconds(presentation.duration(to: .now))
    }
    for key in phases.keys.sorted() {
      print("SETTINGS_OPEN_PHASE case=firstRoot phase=\(key) duration=\(phases[key]!)ms")
    }

    window.orderOut(nil)
    try await Task.sleep(for: .milliseconds(100))
    try await measure("retainedOrderFront", window: window) { window.orderFront(nil) }

    window.orderOut(nil)
    try await Task.sleep(for: .milliseconds(100))
    try await measure("settingsEntryRefresh", window: window) {
      model.invalidateApplicationIcons()
      model.selectedTab = 0
      window.orderFront(nil)
    }

    window.orderOut(nil)
    window.contentView = nil
    try await Task.sleep(for: .milliseconds(100))
    try await measure("freshRootWarmIcons", window: window) {
      window.contentView = NSHostingView(rootView: SettingsView(model: model))
      window.orderFront(nil)
    }

    // Published scan/message changes can invalidate the whole Settings tree.
    // Exercise that separately from cold construction without starting native inspection.
    try await measure("scanMessageTransition", window: window, transition: {
      model.scanComplete = true
      model.scanning = false
      model.message = nil
    }) {
      model.scanComplete = false
      model.scanning = true
      model.message = "The menu bar is still being inspected. Keep editing after the scan completes."
    }
  }

  private func measure(_ name: String, window: NSWindow,
    transition: (() -> Void)? = nil, prepare: () -> Void) async throws {
    let heartbeat = OpeningHeartbeat()
    let heartbeatTask = Task { @MainActor in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(2)) }
        catch { break }
        heartbeat.tick()
      }
    }
    defer { heartbeatTask.cancel() }
    let start = ContinuousClock.now
    prepare()
    let flushStart = ContinuousClock.now
    flush(window)
    let firstFlush = openingMilliseconds(flushStart.duration(to: .now))
    let initial = openingMilliseconds(start.duration(to: .now))
    // Captures construction even before the heartbeat task gets its first turn.
    heartbeat.tick()
    var work: [Double] = []
    var transitioned = false
    let deadline = start.advanced(by: .seconds(1))
    repeat {
      try await Task.sleep(for: .milliseconds(16))
      let frameStart = ContinuousClock.now
      if !transitioned, start.duration(to: .now) >= .milliseconds(250) {
        transition?()
        transitioned = true
      }
      flush(window)
      work.append(openingMilliseconds(frameStart.duration(to: .now)))
    } while ContinuousClock.now < deadline
    heartbeatTask.cancel()
    await heartbeatTask.value
    let gaps = heartbeat.gaps.sorted()
    try #require(!work.isEmpty && !gaps.isEmpty)
    print("SETTINGS_OPEN case=\(name) initial=\(initial)ms firstFlush=\(firstFlush)ms settleWorkMax=\(work.max()!)ms heartbeatP95=\(gaps[Int(Double(gaps.count - 1) * 0.95)])ms heartbeatMax=\(gaps.last!)ms samples=\(gaps.count) elapsed=\(openingMilliseconds(start.duration(to: .now)))ms")
    #expect(([initial, firstFlush] + work + gaps).allSatisfy { $0.isFinite && $0 >= 0 })
    // A hang guard; this is not a display-frame or full production opening budget.
    #expect(gaps.last! < 500, "Settings content blocked the main actor for over 500 ms.")
  }

  private func flush(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    window.contentView?.displayIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
  }

  private func installedBundles() -> [String] {
    // Read-only: use realistic locally installed icons without loading user preferences into the model.
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/io.github.mahenzon.TrayNook.dev/layout.json")
    let layout = (try? LayoutStore(url: url).load()) ?? SavedLayout()
    let candidates = layout.items.map { String($0.id.split(separator: "#")[0]) }
      + ["com.raycast.macos", "org.mozilla.firefox", "com.microsoft.VSCode",
         "com.apple.finder", "com.apple.Safari", "com.apple.systempreferences"]
    return Array(Set(candidates.filter {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
    }).sorted().prefix(10))
  }
}

@MainActor
private final class OpeningHeartbeat {
  var gaps: [Double] = []
  private var previous = ContinuousClock.now

  func tick() {
    let now = ContinuousClock.now
    gaps.append(openingMilliseconds(previous.duration(to: now)))
    previous = now
  }
}

private func openingMilliseconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

private extension Array {
  var nilIfEmpty: Self? { isEmpty ? nil : self }
}

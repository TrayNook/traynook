import AppKit
import ApplicationServices
import InventoryIdentityCore

func L(_ value: String) -> String { value }

private struct PlacementFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

private struct HiddenWitness: Codable {
  var samples = 0
  var revealed = 0
  var unavailable = 0
  var maximumSampleGapSeconds = 0.0
}

private struct VisibleStatusWindow {
  let x: CGFloat
  let width: CGFloat
  let owner: Int32
  let bundle: String
}

@MainActor
private final class PlacementCheck: NSObject, NSApplicationDelegate {
  private let directory = URL(fileURLWithPath: CommandLine.arguments[1])
  private let token = CommandLine.arguments[2]
  private var item: NSStatusItem?
  private var children: [Process] = []
  private var witness = HiddenWitness()
  private var lastSampleUptime: TimeInterval?
  private var finished = false
  private var role: String { CommandLine.arguments.last ?? "Harness" }
  private func bundle(_ role: String) -> String { "io.github.mahenzon.TrayNook.PlacementCheck.\(role).\(token)" }
  private func signal(_ name: String) -> URL { directory.appendingPathComponent(name) }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if role != "Harness" {
      createSource()
      return
    }
    Task {
      let result = await run()
      finished = true
      exit(result)
    }
    Task {
      try? await Task.sleep(for: .seconds(90))
      guard !finished else { return }
      print("FAILED: selective placement exceeded its 90 second deadline.")
      cleanup()
      exit(1)
    }
  }

  private func createSource() {
    let position = role == "Source" ? 5000 : role == "Sentinel" ? 4500 : 100
    UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position Fixture")
    let source = NSStatusBar.system.statusItem(withLength: 24)
    source.autosaveName = "Fixture"
    source.button?.title = role == "Source" ? "F" : role == "Sentinel" ? "S" : "A"
    source.button?.setAccessibilityIdentifier("TrayNookPlacement\(role)")
    source.button?.target = self
    source.button?.action = #selector(activated)
    item = source
    try? Data().write(to: signal("\(role)-ready"))
    if role == "Sentinel" {
      RunLoop.main.add(Timer(timeInterval: 1.0 / 120, target: self,
        selector: #selector(sampleVisibility), userInfo: nil, repeats: true), forMode: .common)
    }
    Timer.scheduledTimer(withTimeInterval: 100, repeats: false) { _ in
      MainActor.assumeIsolated { NSApp.terminate(nil) }
    }
  }

  @objc private func activated() { try? Data().write(to: signal("\(role)-action")) }

  @objc private func sampleVisibility() {
    guard FileManager.default.fileExists(atPath: signal("watch-hidden").path) else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if let previous = lastSampleUptime {
      witness.maximumSampleGapSeconds = max(witness.maximumSampleGapSeconds, now - previous)
    }
    lastSampleUptime = now
    witness.samples += 1
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    let owned = windows?.filter {
      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
        && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow))
    }
    if let owned, !owned.isEmpty {
      if owned.contains(where: { $0[kCGWindowIsOnscreen as String] as? Bool == true }) {
        witness.revealed += 1
      }
    } else { witness.unavailable += 1 }
    if let data = try? JSONEncoder().encode(witness) {
      try? data.write(to: signal("witness.json"), options: .atomic)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let item { NSStatusBar.system.removeStatusItem(item) }
    if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
  }

  private func launch(_ role: String) throws -> Process {
    let child = Process()
    child.executableURL = directory.appendingPathComponent("\(role).app/Contents/MacOS/Check")
    child.arguments = [directory.path, token, role]
    child.standardOutput = FileHandle.nullDevice
    children.append(child)
    try child.run()
    return child
  }

  private func cleanup() {
    for child in children where child.isRunning { child.terminate(); child.waitUntilExit() }
    for role in ["Harness", "Source", "Sentinel", "Anchor"] {
      UserDefaults.standard.removePersistentDomain(forName: bundle(role))
    }
  }

  private func wait(_ label: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard condition() else { throw PlacementFailure("Timed out waiting for \(label).") }
  }

  private func snapshot() async throws -> InventorySnapshot {
    let snapshot = await Task.detached { AccessibilityInventoryScanner().scan() }.value
    guard snapshot.permission == .granted, snapshot.completeness == .complete else {
      throw PlacementFailure("A complete fixture inventory is unavailable: \(snapshot.warnings.joined(separator: "; "))")
    }
    return snapshot
  }

  private func source(_ role: String, in snapshot: InventorySnapshot) throws -> ClassifiedSourceItem {
    let matches = snapshot.items.filter { $0.observation.bundleIdentifier == bundle(role) }
    guard matches.count == 1, let source = matches.first,
      source.identity.persistentKey == bundle(role) else {
      throw PlacementFailure("The exact \(role) fixture could not be bound.")
    }
    return source
  }

  private func visibleWindows() -> [UInt32: VisibleStatusWindow] {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.reduce(into: [:]) { result, window in
      guard (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
        let id = window[kCGWindowNumber as String] as? UInt32,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return }
      let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
      result[id] = VisibleStatusWindow(x: frame.minX, width: frame.width, owner: owner,
        bundle: NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? "unknown")
    }
  }

  private func place(_ label: String, original: ClassifiedSourceItem,
    operation: (ClassifiedSourceItem) async throws -> ClassifiedSourceItem
  ) async throws -> ClassifiedSourceItem {
    let started = ContinuousClock.now
    let deadline = started.advanced(by: .seconds(5))
    var attempts = 0
    var interruption: NativeMenuActionError?
    defer { print("\(label): \(started.duration(to: .now)), retries=\(max(0, attempts - 1))") }
    while true {
      guard ContinuousClock.now < deadline else { throw interruption ?? .inputNotIdle }
      let current = try source("Source", in: await snapshot())
      guard NativeMenuBarController.preservesSourceIdentity(original: original, current: current) else {
        throw PlacementFailure("The source identity changed while waiting to place it.")
      }
      guard ContinuousClock.now < deadline else { throw interruption ?? .inputNotIdle }
      attempts += 1
      do { return try await operation(current) }
      catch let error as NativeMenuActionError {
        switch error {
        case .inputNotIdle, .inputInterrupted, .placementInterrupted:
          interruption = error
          guard ContinuousClock.now < deadline else { throw error }
          try await Task.sleep(for: .milliseconds(300))
        default: throw error
        }
      }
    }
  }

  private func run() async -> Int32 {
    guard AXIsProcessTrusted(),
      ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"].allSatisfy({
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
      }) else {
      print("FAILED: Quit TrayNook and grant Accessibility to the invoking terminal; no input was posted.")
      return 1
    }
    let originalWindows = visibleWindows()
    UserDefaults.standard.set(600, forKey: "NSStatusItem Preferred Position TrayNook.HiddenBoundary")
    let launcher = NSStatusBar.system.statusItem(withLength: 24)
    launcher.button?.title = "T"
    let native = NativeMenuBarController(launcher: launcher)
    var stage = "setup"
    do {
      _ = try launch("Anchor")
      _ = try launch("Sentinel")
      _ = try launch("Source")
      for role in ["Anchor", "Sentinel", "Source"] {
        try await wait("\(role) launch") { FileManager.default.fileExists(atPath: self.signal("\(role)-ready").path) }
      }
      try await Task.sleep(for: .milliseconds(500))
      try await native.prepareLayout(keepingVisible: [bundle("Anchor")])
      let initial = try await snapshot()
      let allowed = Set(initial.items.compactMap { item -> String? in
        guard let key = item.identity.persistentKey, item.manageability.status != .protected,
          let owner = item.observation.bundleIdentifier, !owner.hasPrefix("com.apple."),
          owner != bundle("Anchor") else { return nil }
        return key
      })
      try await native.conceal(allowedKeys: allowed)
      let hidden = try await snapshot()
      guard try source("Source", in: hidden).observation.isOnscreen == false,
        try source("Sentinel", in: hidden).observation.isOnscreen == false,
        native.isBehindBoundary(try source("Anchor", in: hidden)) == false else {
        throw PlacementFailure("The hidden source/sentinel and visible anchor were not established.")
      }
      try Data().write(to: signal("watch-hidden"))
      try await wait("independent sentinel witness") { (self.readWitness()?.samples ?? 0) >= 3 }
      for cycle in 1...2 {
        stage = "show \(cycle)"
        let before = try await snapshot()
        let shown = try await place("Show \(cycle)", original: source("Source", in: before)) {
          try await native.showWhileConcealed($0)
        }
        let after = try await snapshot()
        let current = try source("Source", in: after)
        guard native.isConcealed, !native.hasPendingActivation,
          native.isBehindBoundary(current) == false, current.observation.isOnscreen == true,
          shown.observation.statusWindowIdentifier == current.observation.statusWindowIdentifier,
          let frame = current.observation.frame else {
          throw PlacementFailure("The selected source was not permanently shown with the section still concealed.")
        }
        for other in after.items where other.identity.persistentKey != current.identity.persistentKey
          && other.observation.role == "AXMenuBarItem" && other.observation.isOnscreen == true
          && native.isBehindBoundary(other) == false && !native.isClipped(other.observation) {
          guard let otherFrame = other.observation.frame,
            otherFrame.y < frame.y + frame.height, otherFrame.y + otherFrame.height > frame.y else { continue }
          guard frame.x + frame.width <= otherFrame.x + 2 else {
            throw PlacementFailure("The restored source appeared to the right of an existing visible source.")
          }
        }
        guard try source("Sentinel", in: after).observation.isOnscreen == false else {
          throw PlacementFailure("The hidden sentinel was revealed by showing the selected source.")
        }
        stage = "hide \(cycle)"
        let returned = try await place("Hide \(cycle)", original: current) {
          try await native.hideWhileConcealed($0)
        }
        guard native.isConcealed, !native.hasPendingActivation,
          native.isBehindBoundary(returned) == true, returned.observation.isOnscreen == false else {
          throw PlacementFailure("The selected source did not return behind the expanded separator.")
        }
      }
      try await Task.sleep(for: .milliseconds(100))
      guard let witness = readWitness(), witness.samples >= 3,
        witness.revealed == 0, witness.unavailable == 0 else {
        throw PlacementFailure("The independent sentinel witness saw a reveal or unobservable interval.")
      }
      for role in ["Source", "Sentinel", "Anchor"] {
        guard !FileManager.default.fileExists(atPath: signal("\(role)-action").path) else {
          throw PlacementFailure("Placement unexpectedly activated the \(role) source.")
        }
      }
      printWitness()
      try FileManager.default.removeItem(at: signal("watch-hidden"))
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      cleanup()
      let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
      var restored = visibleWindows()
      while ContinuousClock.now < cleanupDeadline {
        let settled = originalWindows.allSatisfy { id, window in
          restored[id].map { abs($0.x - window.x) <= 2 } == true
        }
        if settled { break }
        try await Task.sleep(for: .milliseconds(20))
        restored = visibleWindows()
      }
      let surviving = originalWindows.keys.filter { restored[$0] != nil }.count
      print("Cleanup windows: original=\(originalWindows.count), surviving=\(surviving), missing=\(originalWindows.count - surviving)")
      for (id, window) in originalWindows where restored[id] == nil {
        print("Cleanup missing: id=\(id), owner=\(window.owner), bundle=\(window.bundle), beforeX=\(window.x), width=\(window.width)")
      }
      var positionsMatch = true
      for (id, window) in originalWindows {
        guard let after = restored[id] else { continue }
        guard abs(after.x - window.x) <= 2 else {
          print("Cleanup mismatch: id=\(id), beforeOwner=\(window.owner), beforeBundle=\(window.bundle), afterOwner=\(after.owner), afterBundle=\(after.bundle), beforeX=\(window.x), afterX=\(after.x), delta=\(after.x - window.x), beforeWidth=\(window.width), afterWidth=\(after.width)")
          positionsMatch = false
          continue
        }
      }
      guard positionsMatch else {
        print("FAILED: pre-existing status windows did not return to their original positions within two seconds.")
        return 1
      }
      print("SELECTIVE_PLACEMENT_CHECK_PASSED")
      return 0
    } catch {
      print("FAILED at \(stage): \(error.localizedDescription)")
      printWitness()
      try? FileManager.default.removeItem(at: signal("watch-hidden"))
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      cleanup()
      return 1
    }
  }

  private func readWitness() -> HiddenWitness? {
    guard let data = try? Data(contentsOf: signal("witness.json")) else { return nil }
    return try? JSONDecoder().decode(HiddenWitness.self, from: data)
  }

  private func printWitness() {
    guard let witness = readWitness() else { print("Hidden sentinel: witness unavailable"); return }
    print("Hidden sentinel: \(witness.samples) independent samples, revealed=\(witness.revealed), unavailable=\(witness.unavailable); max sample gap \(witness.maximumSampleGapSeconds) s")
  }
}

@main
enum SelectivePlacementCheck {
  @MainActor static func main() {
    guard CommandLine.arguments.count == 4 else { exit(2) }
    let application = NSApplication.shared
    let delegate = PlacementCheck()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) { }
  }
}

import AppKit
import ApplicationServices
import InventoryIdentityCore

func L(_ value: String) -> String { value }

private struct Failure: LocalizedError {
  let errorDescription: String?
  init(_ description: String) { errorDescription = description }
}

@MainActor
private final class CancellationCheck: NSObject, NSApplicationDelegate {
  private var fixtureItem: NSStatusItem?
  private let directory = URL(fileURLWithPath: CommandLine.arguments[1])
  private let fixtureBundle = "io.github.mahenzon.TrayNook.CancellationCheck.Fixture"
  private let sentinelBundle = "io.github.mahenzon.TrayNook.CancellationCheck.Sentinel"
  private var isSentinel: Bool { CommandLine.arguments.contains("--sentinel") }
  private var actionFile: URL { directory.appendingPathComponent(isSentinel ? "sentinel-action" : "source-action") }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--source") {
      UserDefaults.standard.set(isSentinel ? 4500 : 5000,
        forKey: "NSStatusItem Preferred Position Fixture")
      let item = NSStatusBar.system.statusItem(withLength: 24)
      item.autosaveName = "Fixture"
      item.button?.title = isSentinel ? "S" : "F"
      item.button?.setAccessibilityIdentifier("TrayNookCancellationFixture")
      item.button?.target = self
      item.button?.action = #selector(activated)
      fixtureItem = item
      if !isSentinel {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self,
              FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("make-wide").path)
            else { return }
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("make-wide"))
            self.fixtureItem?.length = NSScreen.main?.frame.width ?? 2000
            try? Data().write(to: self.directory.appendingPathComponent("wide-ready"))
          }
        }
      }
      Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
        MainActor.assumeIsolated { NSApp.terminate(nil) }
      }
    } else {
      Task { exit(await run()) }
    }
  }

  @objc private func activated() {
    try? Data("unexpected source action".utf8).write(to: actionFile)
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let fixtureItem { NSStatusBar.system.removeStatusItem(fixtureItem) }
    if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
  }

  private func read(_ pid: Int32, expectedBundle: String? = nil) async throws -> ClassifiedSourceItem {
    let snapshot = await Task.detached { AccessibilityInventoryScanner().scan() }.value
    let matches = snapshot.items.filter { $0.observation.processIdentifier == pid }
    guard snapshot.completeness == .complete, matches.count == 1,
      let item = matches.first, item.observation.bundleIdentifier == (expectedBundle ?? fixtureBundle) else {
      throw Failure("The exact owned fixture could not be bound in a complete inventory.")
    }
    return item
  }

  private func run() async -> Int32 {
    guard AXIsProcessTrusted(),
      ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"].allSatisfy({
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
      }) else {
      print("FAILED: Quit TrayNook and grant Accessibility to the invoking terminal.")
      return 1
    }
    UserDefaults.standard.set(600, forKey: "NSStatusItem Preferred Position TrayNook.HiddenBoundary")
    let launcher = NSStatusBar.system.statusItem(withLength: 24)
    launcher.button?.title = "T"
    let native = NativeMenuBarController(launcher: launcher)
    let fixture = Process(), sentinel = Process()
    fixture.executableURL = directory.appendingPathComponent("Fixture.app/Contents/MacOS/Check")
    fixture.arguments = [directory.path, "--source"]
    sentinel.executableURL = directory.appendingPathComponent("Sentinel.app/Contents/MacOS/Check")
    sentinel.arguments = [directory.path, "--source", "--sentinel"]
    fixture.standardOutput = FileHandle.nullDevice
    sentinel.standardOutput = FileHandle.nullDevice
    defer {
      SelectiveCancellationHooks.callback = nil
      native.remove()
      NSStatusBar.system.removeStatusItem(launcher)
      for process in [fixture, sentinel] where process.isRunning {
        process.terminate(); process.waitUntilExit()
      }
      for bundle in [fixtureBundle, sentinelBundle, Bundle.main.bundleIdentifier].compactMap({ $0 }) {
        UserDefaults.standard.removePersistentDomain(forName: bundle)
      }
    }
    var stage = "setup"
    do {
      let probe = await Task.detached { AccessibilityInventoryScanner().scan() }.value
      print("Setup inventory: permission=\(probe.permission.rawValue) completeness=\(probe.completeness.rawValue) items=\(probe.items.count) scanMs=\(Int(probe.metrics.durationMilliseconds)) incompleteApps=\(probe.metrics.incompleteApplicationCount) warnings=\(probe.warnings)")
      try await native.prepareLayout()
      try sentinel.run(); try fixture.run()
      try await Task.sleep(for: .seconds(1))
      let snapshot = await Task.detached { AccessibilityInventoryScanner().scan() }.value
      guard snapshot.completeness == .complete else { throw Failure("Initial inventory is incomplete.") }
      // This isolated check does not save a layout or move any pre-existing item.
      // Its temporary separator may conceal the third-party sources already to
      // its left; native guards still protect every visible system/unknown item.
      let allowed = Set(snapshot.items.compactMap { item -> String? in
        guard let key = item.identity.persistentKey, item.manageability.status != .protected,
          let bundle = item.observation.bundleIdentifier, !bundle.hasPrefix("com.apple.") else { return nil }
        return key
      })
      for phase in ["queued-down", "delivered-down", "delivered-up", "queued-motion", "queued-up-motion", "motion-down", "motion-up",
        "return-motion-down", "return-motion-up"] {
        stage = "\(phase): conceal"
        try await native.conceal(allowedKeys: allowed)
        stage = "\(phase): bind"
        let source = try await read(fixture.processIdentifier)
        let initialSentinel = try await read(sentinel.processIdentifier, expectedBundle: sentinelBundle)
        guard native.isConcealed, let sourceFrame = source.observation.frame,
          let sentinelFrame = initialSentinel.observation.frame,
          sourceFrame.maxX < 0, sentinelFrame.maxX < 0,
          sourceFrame.minX < sentinelFrame.minX else {
          throw Failure("The owned source must begin fully offscreen behind the expanded separator.")
        }
        let originalGap = sentinelFrame.minX - sourceFrame.maxX
        let returning = phase.hasPrefix("return-")
        let motion = phase.contains("motion")
        let priorPointer = CGEvent(source: nil)?.location
        let userPointer = CGPoint(x: 400, y: 400)
        defer {
          if motion, CGEvent(source: nil)?.location == userPointer, let priorPointer {
            CGWarpMouseCursorPosition(priorPointer)
          }
        }
        if returning { _ = try await native.prepareActivation(source) }
        SelectiveCancellationHooks.reset()
        var reached = false
        var operation: Task<Void, Error>?
        SelectiveCancellationHooks.callback = { type, stage in
          let matches = phase == "queued-down" && type == .leftMouseDown && stage == "queued"
            || phase == "queued-motion" && type == .leftMouseDown && stage == "queued"
            || phase == "queued-up-motion" && type == .leftMouseUp && stage == "queued"
            || phase == "delivered-down" && type == .leftMouseDown && stage == "delivered"
            || phase == "delivered-up" && type == .leftMouseUp && stage == "delivered"
            || phase.hasSuffix("motion-down") && type == .leftMouseDown && stage == "delivered"
            || phase.hasSuffix("motion-up") && type == .leftMouseUp && stage == "delivered"
          guard matches, !reached else { return }
          reached = true
          if motion {
            // A deterministic coordinate race, not a claim of real HID input.
            CGWarpMouseCursorPosition(userPointer)
            return
          }
          operation?.cancel()
          if phase == "queued-down" { native.reveal() }
        }
        stage = "\(phase): prepare"
        let task = Task {
          if returning { try await native.restoreActivation() }
          else { _ = try await native.prepareActivation(source) }
        }
        operation = task
        do {
          try await task.value
          if !phase.hasSuffix("motion-up") { throw Failure("The scheduled interruption did not stop the operation.") }
        }
        catch is CancellationError { }
        catch {
          guard phase.hasSuffix("motion-down") && error.localizedDescription.hasPrefix("Physical input interrupted")
            || phase.hasPrefix("queued-") && motion && error.localizedDescription.hasPrefix("macOS could not route")
          else { throw error }
        }
        stage = "\(phase): counts"
        SelectiveCancellationHooks.callback = nil
        guard reached else { throw Failure("The requested cancellation edge was not reached.") }
        let counts = (SelectiveCancellationHooks.downPosts, SelectiveCancellationHooks.upPosts,
          SelectiveCancellationHooks.emergencyReleases)
        let expected = phase == "queued-down" || phase == "queued-motion" ? (0, 0, 0)
          : phase == "delivered-down" || phase.hasSuffix("motion-down") || phase == "queued-up-motion"
            ? (1, 0, 1) : (1, 1, 0)
        guard counts == expected else {
          throw Failure("Unexpected posted down/up/recovery counts at \(phase): \(counts).")
        }
        // Let asynchronously posted recovery input finish before verifying it.
        try await Task.sleep(for: .milliseconds(250))
        if motion, CGEvent(source: nil)?.location != userPointer {
          throw Failure("Interruption or delayed completion stole the user's new pointer position.")
        }
        stage = "\(phase): restore"
        if native.hasPendingActivation { try await native.restoreActivation() }
        try await Task.sleep(for: .milliseconds(250))
        if motion, CGEvent(source: nil)?.location != userPointer {
          throw Failure("Restoration stole the user's new pointer position.")
        }
        guard !native.hasPendingActivation,
          !CGEventSource.buttonState(.combinedSessionState, button: .left),
          !FileManager.default.fileExists(atPath: directory.appendingPathComponent("source-action").path),
          !FileManager.default.fileExists(atPath: directory.appendingPathComponent("sentinel-action").path)
        else { throw Failure("Cancellation left pending input, a pending return, or an unintended source action.") }
        if phase != "queued-down" {
          let restored = try await read(fixture.processIdentifier)
          let restoredSentinel = try await read(sentinel.processIdentifier, expectedBundle: sentinelBundle)
          guard native.isConcealed, native.isBehindBoundary(restored) == true,
            let restoredFrame = restored.observation.frame, let restoredSentinelFrame = restoredSentinel.observation.frame,
            restoredFrame.maxX < 0, restoredSentinelFrame.maxX < 0,
            restoredFrame.minX < restoredSentinelFrame.minX,
            abs(restoredSentinelFrame.minX - restoredFrame.maxX - originalGap) <= 2 else {
            throw Failure("The cancelled source did not return behind the still-expanded separator.")
          }
        }
        print("PASS: \(phase), posted down/up/recovery=\(counts), no source action, no held button")
      }
      stage = "no safe slot"
      SelectiveCancellationHooks.callback = nil
      SelectiveCancellationHooks.reset()
      try Data().write(to: directory.appendingPathComponent("make-wide"))
      for _ in 0..<50 {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("wide-ready").path) { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let wide = try await read(fixture.processIdentifier)
      guard (wide.observation.frame?.width ?? 0) > 1000 else { throw Failure("Wide fixture was not established.") }
      do {
        _ = try await native.prepareActivation(wide)
        throw Failure("A source wider than the safe status area was promoted.")
      } catch {
        guard error.localizedDescription.hasPrefix("There is not enough space") else { throw error }
      }
      guard SelectiveCancellationHooks.downPosts == 0, SelectiveCancellationHooks.upPosts == 0,
        !native.hasPendingActivation, native.isConcealed,
        try await read(sentinel.processIdentifier, expectedBundle: sentinelBundle).observation.isOnscreen == false else {
        throw Failure("No-space rejection posted input or lost concealment.")
      }
      print("PASS: no safe slot rejected before input, no pending return, peers remain concealed")
      print("SELECTIVE_CANCELLATION_CHECK_PASSED")
      return 0
    } catch {
      print("FAILED at \(stage): \(error.localizedDescription); posted down/up/recovery="
        + "\(SelectiveCancellationHooks.downPosts)/\(SelectiveCancellationHooks.upPosts)/\(SelectiveCancellationHooks.emergencyReleases)")
      return 1
    }
  }
}

@main
enum SelectiveCancellationCheck {
  @MainActor static func main() {
    guard CommandLine.arguments.count > 1 else { exit(2) }
    let app = NSApplication.shared
    let delegate = CancellationCheck()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) { }
  }
}

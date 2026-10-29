import AppKit
import ApplicationServices
import InventoryIdentityCore

func L(_ value: String) -> String { value }

private struct CheckFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

@MainActor
private final class MovementCheck: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var fixtureItem: NSStatusItem?
  private let directory = URL(fileURLWithPath: CommandLine.arguments[1])
  private var eventsURL: URL { directory.appendingPathComponent("events.txt") }
  private var controlURL: URL { directory.appendingPathComponent("control.txt") }
  private let fixtureBundle = "io.github.mahenzon.TrayNook.NativeCheck.Fixture"
  private var lostPlacementFocus = false

  @objc private func placementResignedActive(_ notification: Notification) {
    lostPlacementFocus = true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--source") {
      createFixture()
    } else {
      Task { exit(await runCheck()) }
    }
  }

  private func createFixture() {
    UserDefaults.standard.set(2, forKey: "NSStatusItem Preferred Position Fixture")
    let item = NSStatusBar.system.statusItem(withLength: 24)
    item.autosaveName = "Fixture"
    item.button?.title = "F"
    item.button?.setAccessibilityIdentifier("TrayNookNativeMovementFixture")
    item.button?.target = self
    item.button?.action = #selector(clicked)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    fixtureItem = item
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self,
          (try? String(contentsOf: self.controlURL, encoding: .utf8)) == "clip" else { return }
        try? FileManager.default.removeItem(at: self.controlURL)
        let width = NSScreen.main?.auxiliaryTopRightArea?.width ?? NSScreen.main?.frame.width ?? 800
        self.fixtureItem?.isVisible = false
        UserDefaults.standard.set(width + 100, forKey: "NSStatusItem Preferred Position Fixture")
        self.fixtureItem?.autosaveName = "Fixture"
        self.fixtureItem?.isVisible = true
      }
    }
    // Clean up even if the parent check is interrupted.
    Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
      MainActor.assumeIsolated { NSApp.terminate(nil) }
    }
  }

  @objc private func clicked() {
    let event = NSApp.currentEvent
    let freshRightClick = event?.type == .rightMouseUp
      && ProcessInfo.processInfo.systemUptime - (event?.timestamp ?? 0) < 0.2
    append(freshRightClick ? "secondary" : "primary")
    guard let button = fixtureItem?.button else { return }
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(withTitle: "TrayNook disposable fixture", action: nil, keyEquivalent: "")
    let close = Timer(timeInterval: 0.15, target: menu,
      selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
    RunLoop.main.add(close, forMode: .common)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
  }

  func menuWillOpen(_ menu: NSMenu) { append("menu") }

  private func append(_ message: String) {
    let previous = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? ""
    try? (previous + message + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let fixtureItem { NSStatusBar.system.removeStatusItem(fixtureItem) }
    if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
  }

  private func runCheck() async -> Int32 {
    guard ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"].allSatisfy({
      NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
    }) else {
      print("FAILED: Quit TrayNook before running the disposable fixture check.")
      return 1
    }
    guard AXIsProcessTrusted() else {
      print("FAILED: Accessibility is denied; no input was posted.")
      return 1
    }
    UserDefaults.standard.set(600, forKey: "NSStatusItem Preferred Position TrayNook.HiddenBoundary")
    let launcher = NSStatusBar.system.statusItem(withLength: 24)
    launcher.button?.title = "T"
    let native = NativeMenuBarController(launcher: launcher)
    let fixture = Process()
    fixture.executableURL = directory.appendingPathComponent("Fixture.app/Contents/MacOS/NativeMovementCheck")
    fixture.arguments = [directory.path, "--source"]
    fixture.standardOutput = FileHandle.nullDevice
    defer {
      native.remove()
      NSStatusBar.system.removeStatusItem(launcher)
      if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
      if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
      UserDefaults.standard.removePersistentDomain(forName: fixtureBundle)
    }
    do {
      try "".write(to: eventsURL, atomically: true, encoding: .utf8)
      try await native.prepareLayout()
      try fixture.run()
      try await Task.sleep(for: .seconds(1))
      let source = try await readFixture(processIdentifier: fixture.processIdentifier)
      guard source.observation.isOnscreen == true, native.isBehindBoundary(source) == false else {
        throw CheckFailure("Disposable fixture is not visible beside the launcher; no item was moved.")
      }
      if CommandLine.arguments.contains("--pointer-motion") {
        try await checkActivationDuringPointerMotion(source, native: native)
        print("PASS: exactly one AX primary action during continuous pointer-motion events")
      } else {
        try await checkPlacementFocus(source, native: native)
        try await checkActivation(source, native: native, secondary: false)
        print("PASS: primary native menu and observed dismissal")
        try await checkActivation(source, native: native, secondary: true)
        print("PASS: secondary native menu and observed dismissal")
      }
      if CommandLine.arguments.contains("--clipped") {
        try "clip".write(to: controlURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(0.5))
        let clipped = try await readFixture(processIdentifier: fixture.processIdentifier)
        guard native.isClipped(clipped.observation) else {
          print("Fixture visibility=\(String(describing: clipped.observation.isOnscreen)), frame=\(String(describing: clipped.observation.frame))")
          throw CheckFailure("This display did not clip the fixture; the optional AX fallback check cannot run.")
        }
        try await checkActivation(clipped, native: native, secondary: false)
        print("PASS: clipped fixture AXPress and observed native menu dismissal")
      }
      print("NATIVE_MOVEMENT_CHECK_PASSED")
      return 0
    } catch {
      print("FAILED: \(error.localizedDescription)")
      return 1
    }
  }

  private func checkPlacementFocus(_ source: ClassifiedSourceItem,
    native: NativeMenuBarController) async throws {
    let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    settings.title = "TrayNook placement focus check"
    settings.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { settings.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(300))
    guard NSApp.isActive, NSApp.keyWindow === settings else {
      throw CheckFailure("The check could not activate its Settings window.")
    }
    lostPlacementFocus = false
    NotificationCenter.default.addObserver(self, selector: #selector(placementResignedActive(_:)),
      name: NSApplication.didResignActiveNotification, object: NSApp)
    defer { NotificationCenter.default.removeObserver(self,
      name: NSApplication.didResignActiveNotification, object: NSApp) }
    for hidden in [true, false] {
      try await native.move(source, toHidden: hidden)
      guard !lostPlacementFocus, NSApp.isActive, NSApp.keyWindow === settings else {
        throw CheckFailure("Changing placement deactivated Settings or changed its key window.")
      }
      print("PASS: move fixture \(hidden ? "behind the boundary" : "to the visible section") while Settings stays active")
    }
  }

  private func readFixture(processIdentifier: Int32) async throws -> ClassifiedSourceItem {
    let snapshot = await Task.detached { AccessibilityInventoryScanner().scan() }.value
    let matches = snapshot.items.filter { $0.observation.bundleIdentifier == fixtureBundle }
    guard snapshot.completeness == .complete, matches.count == 1,
      let source = matches.first, source.observation.processIdentifier == processIdentifier else {
      throw CheckFailure("A complete inventory with our exact fixture process is unavailable.")
    }
    return source
  }

  private func checkActivation(_ source: ClassifiedSourceItem,
    native: NativeMenuBarController, secondary: Bool) async throws {
    try "".write(to: eventsURL, atomically: true, encoding: .utf8)
    let observer = NativeMenuInteraction(processIdentifier: source.observation.processIdentifier)
    defer { observer?.cancel() }
    do { try await native.activate(source, secondary: secondary) }
    catch NativeMenuActionError.responseTimedOut {
      // AX menus can hold the synchronous response until dismissal. Observe
      // delivery and closure without issuing the action a second time.
    }
    guard await observer?.waitForDismissal() == true else {
      throw CheckFailure("The fixture's native menu dismissal was not observed.")
    }
    let events = try String(contentsOf: eventsURL, encoding: .utf8)
    let lines = events.split(separator: "\n")
    guard lines.filter({ $0 == (secondary ? "secondary" : "primary") }).count == 1,
      lines.filter({ $0 == (secondary ? "primary" : "secondary") }).isEmpty,
      lines.filter({ $0 == "menu" }).count == 1 else {
      throw CheckFailure("The fixture did not receive the expected native action.")
    }
  }

  /// Keep the recent HID movement signal active without displacing the pointer
  /// or clicking any application. The old physical-click path waits for this
  /// signal to stop; an explicitly advertised AXPress must not need that wait.
  private func checkActivationDuringPointerMotion(_ source: ClassifiedSourceItem,
    native: NativeMenuBarController) async throws {
    guard source.observation.actions.contains(kAXPressAction as String) else {
      throw CheckFailure("The fixture does not advertise AXPress.")
    }
    let timer = Timer(timeInterval: 0.04, repeats: true) { _ in
      guard let point = CGEvent(source: nil)?.location,
        let eventSource = CGEventSource(stateID: .privateState),
        let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
          mouseCursorPosition: point, mouseButton: .left) else { return }
      event.flags = []
      event.post(tap: .cghidEventTap)
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    try await Task.sleep(for: .seconds(0.12))
    guard CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) < 0.2 else {
      throw CheckFailure("The test could not establish the recent physical-motion signal.")
    }
    print("CHECK: recent HID pointer-motion signal is active; invoking the fixture once")
    try await checkActivation(source, native: native, secondary: false)
  }
}

@main
enum NativeMovementCheck {
  @MainActor static func main() {
    guard CommandLine.arguments.count > 1 else { exit(2) }
    let app = NSApplication.shared
    let delegate = MovementCheck()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
  }
}

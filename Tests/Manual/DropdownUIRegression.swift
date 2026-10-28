import AppKit
import ApplicationServices

/// Drives the packaged production app through Accessibility. This helper does
/// not import or call AppModel, DropdownView, or NativeMenuBarController.
private struct CheckFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

private struct FixtureMenuGeometry: Codable {
  let source: CGRect
  let menu: CGRect
  let display: CGRect
  let safeStatusArea: CGRect
  let notch: CGRect?

  var isSafe: Bool {
    safeStatusArea.insetBy(dx: 0, dy: -1).contains(source)
      && display.contains(menu)
      && !(notch?.intersects(menu) ?? false)
  }
}

private struct PointerWitness: Codable {
  var samples = 0
  var displacedSamples = 0
  var maximumDistance: Double = 0
  var maximumExcursionSeconds: Double = 0
}

@MainActor
private final class DropdownCheck: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let directory: URL
  let token: String
  var fixtureItem: NSStatusItem?
  var fixture: Process?
  var sentinel: Process?
  var production: Process?
  private var menuOpen = false
  private var pointerWitness = PointerWitness()
  private var watchedPointer: CGPoint?
  private var excursionStarted: TimeInterval?
  private var controlSnapshots: [String] = []
  private var sourceLayout: (url: URL, data: Data)?
  private var sourceWindowOrder: [UInt32: CGFloat] = [:]
  var appID: String { "io.github.mahenzon.TrayNook.UIRegression.App.\(token)" }
  var fixtureID: String { "io.github.mahenzon.TrayNook.UIRegression.Fixture.\(token)" }
  var sentinelID: String { "io.github.mahenzon.TrayNook.UIRegression.Sentinel.\(token)" }
  var isSentinel: Bool { CommandLine.arguments.contains("--sentinel") }
  var fixtureName: String {
    fixture.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier)?.localizedName }
      ?? "TrayNook UI Fixture"
  }
  var eventsURL: URL { directory.appendingPathComponent(isSentinel ? "sentinel-events.txt" : "events.txt") }
  private func signal(_ name: String) -> URL { directory.appendingPathComponent(name) }
  var supportURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(appID)
  }

  init(directory: URL, token: String) { self.directory = directory; self.token = token }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--source") { createFixture(); return }
    Task {
      let result = await runCheck()
      await cleanup()
      let preserved = verifyOriginalState()
      if result == 0 && preserved { print("DROPDOWN_UI_REGRESSION_PASSED") }
      exit(result == 0 && preserved ? 0 : 1)
    }
    Task {
      try? await Task.sleep(for: .seconds(200))
      print("FAILED: UI regression exceeded its 200 second deadline.")
      await cleanup()
      exit(1)
    }
  }

  private func createFixture() {
    UserDefaults.standard.set(isSentinel ? 3 : 2, forKey: "NSStatusItem Preferred Position Fixture")
    let item = NSStatusBar.system.statusItem(withLength: 24)
    item.autosaveName = "Fixture"
    item.button?.title = isSentinel ? "S" : "F"
    item.button?.setAccessibilityIdentifier(isSentinel ? "TrayNookHiddenSentinel" : "TrayNookDropdownUIFixture")
    item.button?.target = self
    item.button?.action = #selector(clicked)
    fixtureItem = item
    append("ready")
    // This runs in the source processes, independently of blocked production AX
    // calls. Common-mode sampling continues through native menu tracking.
    RunLoop.main.add(Timer(timeInterval: 1.0 / 120, target: self,
      selector: #selector(sampleHandoff), userInfo: nil, repeats: true), forMode: .common)
    Timer.scheduledTimer(withTimeInterval: 110, repeats: false) { _ in
      MainActor.assumeIsolated { NSApp.terminate(nil) }
    }
  }

  @objc private func clicked() {
    append("action")
    guard let button = fixtureItem?.button else { return }
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(withTitle: "Disposable TrayNook UI test menu", action: nil, keyEquivalent: "")
    let holdingMenu = FileManager.default.fileExists(atPath: directory.appendingPathComponent("hold-menu").path)
    let close = Timer(timeInterval: holdingMenu ? 5 : 0.6, target: menu,
      selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
    RunLoop.main.add(close, forMode: .common)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuOpen = true
    try? String(ProcessInfo.processInfo.systemUptime).write(to: signal("menu-open-uptime"),
      atomically: true, encoding: .utf8)
    append("menu-open")
  }
  func menuDidClose(_ menu: NSMenu) {
    menuOpen = false
    try? String(ProcessInfo.processInfo.systemUptime).write(to: signal("menu-close-uptime"),
      atomically: true, encoding: .utf8)
    append("menu-close")
  }

  @objc private func sampleHandoff() {
    if isSentinel {
      guard FileManager.default.fileExists(atPath: signal("watch-hidden").path) else {
        watchedPointer = nil
        pointerWitness = PointerWitness()
        excursionStarted = nil
        return
      }
      if !FileManager.default.fileExists(atPath: signal("watch-ready").path) {
        watchedPointer = nil
        pointerWitness = PointerWitness()
        excursionStarted = nil
      }
      if watchedPointer == nil,
        let data = try? Data(contentsOf: signal("watch-pointer.json")) {
        watchedPointer = try? JSONDecoder().decode(CGPoint.self, from: data)
      }
      if let expected = watchedPointer, let actual = CGEvent(source: nil)?.location {
        let distance = hypot(actual.x - expected.x, actual.y - expected.y)
        pointerWitness.samples += 1
        let now = ProcessInfo.processInfo.systemUptime
        if distance > 2 {
          pointerWitness.displacedSamples += 1
          if excursionStarted == nil { excursionStarted = now }
        }
        if let excursionStarted {
          pointerWitness.maximumExcursionSeconds = max(pointerWitness.maximumExcursionSeconds, now - excursionStarted)
        }
        if distance <= 2 { excursionStarted = nil }
        pointerWitness.maximumDistance = max(pointerWitness.maximumDistance, distance)
        if let data = try? JSONEncoder().encode(pointerWitness) {
          try? data.write(to: signal("pointer-witness.json"), options: .atomic)
        }
      }
      let visibility = fixtureOnscreen(pid: ProcessInfo.processInfo.processIdentifier)
      if visibility == false {
        if !FileManager.default.fileExists(atPath: signal("watch-ready").path) {
          try? Data().write(to: signal("watch-ready"))
        }
      } else {
        let name = visibility == true ? "sentinel-revealed" : "sentinel-unobservable"
        if !FileManager.default.fileExists(atPath: signal(name).path) {
          try? Data().write(to: signal(name))
        }
      }
      return
    }
    guard menuOpen, let button = fixtureItem?.button, let window = button.window,
      let screen = window.screen ?? NSScreen.main,
      let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let menuWindow = windows.first(where: {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
          && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.popUpMenuWindow))
          && ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
      }), let menuBounds = menuWindow[kCGWindowBounds as String] as? [String: Any],
      let menuFrame = CGRect(dictionaryRepresentation: menuBounds as CFDictionary) else { return }
    let display = CGDisplayBounds(displayNumber.uint32Value)
    func converted(_ rect: CGRect) -> CGRect {
      CGRect(x: display.minX + rect.minX - screen.frame.minX,
        y: display.minY + screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    let safe = screen.auxiliaryTopRightArea ?? CGRect(x: screen.frame.minX,
      y: screen.frame.maxY - NSStatusBar.system.thickness, width: screen.frame.width,
      height: NSStatusBar.system.thickness)
    var notch: CGRect?
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
      left.maxX < right.minX {
      notch = converted(CGRect(x: left.maxX, y: max(left.minY, right.minY),
        width: right.minX - left.maxX, height: min(left.maxY, right.maxY) - max(left.minY, right.minY)))
    }
    let geometry = FixtureMenuGeometry(
      source: converted(window.convertToScreen(button.convert(button.bounds, to: nil))),
      menu: menuFrame, display: display, safeStatusArea: converted(safe), notch: notch)
    if let data = try? JSONEncoder().encode(geometry) {
      try? data.write(to: signal("menu-geometry.json"), options: .atomic)
      if !geometry.isSafe && !FileManager.default.fileExists(atPath: signal("unsafe-menu-geometry.json").path) {
        try? data.write(to: signal("unsafe-menu-geometry.json"), options: .atomic)
      }
    }
  }

  private func append(_ message: String) {
    let previous = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? ""
    try? (previous + message + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let fixtureItem { NSStatusBar.system.removeStatusItem(fixtureItem) }
  }

  private func runCheck() async -> Int32 {
    do {
      guard ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"].allSatisfy({
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
      }) else { throw CheckFailure("Quit TrayNook before this isolated UI test. No apps were started.") }
      guard AXIsProcessTrusted() else {
        throw CheckFailure("Accessibility is denied for the invoking terminal; no input was posted.")
      }
      sourceWindowOrder = visibleStatusWindowPositions()
      try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
      var layout: [String: Any] = ["version": 1, "rowCapacity": 10,
        "items": [["id": fixtureID, "placement": "dropdown"],
                  ["id": sentinelID, "placement": "alwaysHidden"]]]
      if let index = CommandLine.arguments.firstIndex(of: "--layout") {
        guard CommandLine.arguments.indices.contains(index + 1) else { throw CheckFailure("Missing --layout path.") }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let data = try Data(contentsOf: url)
        guard var copied = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var items = copied["items"] as? [[String: Any]] else {
          throw CheckFailure("The supplied layout is not a TrayNook layout object.")
        }
        sourceLayout = (url, data)
        items.append(["id": fixtureID, "placement": "dropdown"])
        items.append(["id": sentinelID, "placement": "alwaysHidden"])
        copied["items"] = items
        layout = copied
        print("Copied existing placements read-only into the isolated test layout.")
      }
      try JSONSerialization.data(withJSONObject: layout).write(
        to: supportURL.appendingPathComponent("layout.json"), options: .atomic)
      if CommandLine.arguments.contains("--invalid-positions") {
        UserDefaults.standard.setPersistentDomain([
          "NSStatusItem Preferred Position TrayNookLauncher": 6000,
          "NSStatusItem Preferred Position TrayNook.HiddenBoundary": 0,
        ], forName: appID)
        UserDefaults.standard.synchronize()
      }
      fixture = try launch("Fixture.app/Contents/MacOS/DropdownUIRegression", arguments: [directory.path, token, "--source"])
      try await wait("fixture launch", seconds: 5) { self.events().contains("ready\n") }
      guard let fixture else { throw CheckFailure("Fixture process was not created.") }
      try await wait("fixture status window", seconds: 5) {
        self.fixtureOnscreen(pid: fixture.processIdentifier) != nil
      }
      sentinel = try launch("Sentinel.app/Contents/MacOS/DropdownUIRegression",
        arguments: [directory.path, token, "--source", "--sentinel"])
      guard let sentinel else { throw CheckFailure("Sentinel process was not created.") }
      try await wait("hidden sentinel launch", seconds: 5) {
        (try? String(contentsOf: self.signal("sentinel-events.txt"), encoding: .utf8))?.contains("ready\n") == true
          && self.fixtureOnscreen(pid: sentinel.processIdentifier) != nil
      }
      production = try launch("App.app/Contents/MacOS/TrayNook", arguments: [])
      guard let production else { throw CheckFailure("Production process was not created.") }
      let application = AXUIElementCreateApplication(production.processIdentifier)
      AXUIElementSetMessagingTimeout(application, 1)
      try await wait("production launch and automatic concealment", seconds: 120) {
        self.recordControlWindows(pid: production.processIdentifier)
        return self.button("Show Items", in: application) != nil
          && self.fixtureOnscreen(pid: fixture.processIdentifier) == false
          && self.fixtureOnscreen(pid: sentinel.processIdentifier) == false
      }
      print("PASS: packaged production AppModel applied the disposable saved layout and concealed the fixture")
      if CommandLine.arguments.contains("--invalid-positions") {
        print("PASS: automatic layout recovered deliberately invalid own saved control positions")
      }
      guard let launcher = find("Open TrayNook", in: application) else {
        throw CheckFailure("Production launcher is not accessible.")
      }
      try press(launcher, description: "production launcher")
      try await wait("actual DropdownView proxy button", seconds: 5) {
        self.button(self.fixtureName, in: application) != nil
      }
      print("PASS: AXPress on the production launcher opened the actual DropdownView")
      let controlsBeforeToggles = ownControlFrames(application)
      guard controlsBeforeToggles.count == 2 else { throw CheckFailure("Could not verify both owned status controls.") }
      for _ in 0..<2 {
        guard let toggle = find("Open TrayNook", in: application) else { throw CheckFailure("Launcher disappeared.") }
        try press(toggle, description: "close dropdown from launcher")
        try await wait("dropdown closed from launcher", seconds: 3) {
          self.button(self.fixtureName, in: application) == nil
        }
        guard fixtureOnscreen(pid: fixture.processIdentifier) == false,
          ownControlFrames(application) == controlsBeforeToggles else {
          throw CheckFailure("Closing the dropdown revealed the fixture or changed separator spacing.")
        }
        try press(toggle, description: "reopen dropdown from launcher")
        try await wait("dropdown reopened from launcher", seconds: 5) {
          self.button(self.fixtureName, in: application) != nil
        }
        guard fixtureOnscreen(pid: fixture.processIdentifier) == false,
          ownControlFrames(application) == controlsBeforeToggles else {
          throw CheckFailure("Reopening the dropdown revealed the fixture or changed separator spacing.")
        }
      }
      print("PASS: two launcher close/reopen cycles retained concealment and identical own control geometry")
      // The real model polls every 3 seconds. Keep its actual popover open across
      // two polls; a popup accidentally counted as a new status item fails here.
      let deadline = Date().addingTimeInterval(7)
      while Date() < deadline {
        guard fixtureOnscreen(pid: fixture.processIdentifier) == false,
          button("Show Items", in: application) != nil else {
          throw CheckFailure("Fixture was revealed while the dropdown was open across a model polling interval.")
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      print("PASS: fixture stayed CG offscreen with the dropdown open for 7 seconds")
      try "".write(to: eventsURL, atomically: true, encoding: .utf8)
      guard let proxy = button(fixtureName, in: application) else {
        throw CheckFailure("Actual fixture proxy disappeared before AXPress.")
      }
      defer { try? FileManager.default.removeItem(at: signal("watch-hidden")) }
      try await armHandoffMonitor()
      let activationStarted = ProcessInfo.processInfo.systemUptime
      try press(proxy, description: "actual DropdownView fixture button")
      try await wait("fixture native menu open and close after proxy action", seconds: 12) {
        let events = self.events()
        return events.contains("action\n") && events.contains("menu-open\n") && events.contains("menu-close\n")
      }
      if let text = try? String(contentsOf: signal("menu-open-uptime"), encoding: .utf8),
        let opened = Double(text), opened >= activationStarted {
        print("Proxy AXPress to native menu-open: \(Int((opened - activationStarted) * 1000)) ms")
      }
      try requireHiddenSentinel()
      try requireSafeMenuGeometry()
      guard events().components(separatedBy: "\n").filter({ $0 == "action" }).count == 1 else {
        throw CheckFailure("The proxy delivered more than one native action.")
      }
      print("PASS: actual proxy AXPress delivered exactly one fixture action and a native NSMenu open/close cycle")
      try await wait("restored concealment after native menu dismissal", seconds: 12) {
        self.fixtureOnscreen(pid: fixture.processIdentifier) == false
          && self.button("Show Items", in: application) != nil
      }
      if let text = try? String(contentsOf: signal("menu-close-uptime"), encoding: .utf8),
        let closed = Double(text) {
        print("Native menu-close to observed restored concealment: \(Int((ProcessInfo.processInfo.systemUptime - closed) * 1000)) ms (150 ms polling)")
      }
      let restoredDeadline = Date().addingTimeInterval(4)
      while Date() < restoredDeadline {
        try requireHiddenSentinel()
        guard fixtureOnscreen(pid: fixture.processIdentifier) == false,
          button("Show Items", in: application) != nil else {
          throw CheckFailure("Restored concealment did not survive the next production inventory poll.")
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      try requireHiddenSentinel()
      try requirePointerBudget()
      try FileManager.default.removeItem(at: signal("watch-hidden"))
      print("PASS: no other-source reveal observed by independent 120Hz sentinel; selected source stayed right of notch and menu stayed fully onscreen")
      print("PASS: production restored concealment after dismissal and retained it through another poll")

      // A second, deliberately longer disposable menu lets Settings interrupt
      // the real production handoff. Only the test fixture reads this control.
      try Data().write(to: directory.appendingPathComponent("hold-menu"))
      try "".write(to: eventsURL, atomically: true, encoding: .utf8)
      guard let toggle = find("Open TrayNook", in: application) else { throw CheckFailure("Launcher disappeared.") }
      try press(toggle, description: "launcher before cancellation check")
      try await wait("proxy before cancellation check", seconds: 5) {
        self.button(self.fixtureName, in: application) != nil
      }
      guard let secondProxy = button(fixtureName, in: application) else { throw CheckFailure("Fixture proxy unavailable.") }
      try await armHandoffMonitor()
      let repeatedActivationStarted = ProcessInfo.processInfo.systemUptime
      try press(secondProxy, description: "fixture proxy before Settings interruption")
      try await wait("held fixture menu opened", seconds: 10) {
        self.events().contains("menu-open\n") && !self.events().contains("menu-close\n")
      }
      try await wait("repeated handoff native menu geometry", seconds: 2) {
        FileManager.default.fileExists(atPath: self.signal("menu-geometry.json").path)
      }
      if let text = try? String(contentsOf: signal("menu-open-uptime"), encoding: .utf8),
        let opened = Double(text), opened >= repeatedActivationStarted {
        print("Repeated proxy AXPress to native menu-open: \(Int((opened - repeatedActivationStarted) * 1000)) ms")
      }
      guard let busyApply = button("Apply Saved Layout", in: application), !isEnabled(busyApply) else {
        throw CheckFailure("The production handoff was not busy while the fixture menu was open.")
      }
      try requireHiddenSentinel()
      try requireSafeMenuGeometry()
      try requirePointerBudget()
      guard !events().contains("menu-close\n"),
        events().components(separatedBy: "\n").filter({ $0 == "action" }).count == 1 else {
        throw CheckFailure("Repeated activation did not retain exactly one live native menu action.")
      }
      print("PASS: repeated proxy activation stayed selective, delivered exactly one action, and retained safe source/menu geometry")
      // Settings deliberately reveals items. End the selective-handoff witness
      // immediately before that explicit user action, not before verification.
      try FileManager.default.removeItem(at: signal("watch-hidden"))
      if let settings = find("Open Settings", in: application, role: kAXMenuItemRole as String) {
        try press(settings, description: "production Open Settings menu item during handoff")
      } else {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        let reopened = try await NSWorkspace.shared.openApplication(
          at: directory.appendingPathComponent("App.app"), configuration: configuration)
        guard reopened.processIdentifier == production.processIdentifier else {
          throw CheckFailure("Reopening Settings created a second production process.")
        }
      }
      try await wait("Settings cancelled the active native handoff", seconds: 6) {
        guard let hide = self.button("Hide Items", in: application) else { return false }
        return self.isEnabled(hide) && self.fixtureOnscreen(pid: fixture.processIdentifier) == true
      }
      guard NSRunningApplication.runningApplications(withBundleIdentifier: appID).count == 1 else {
        throw CheckFailure("Settings reopening created duplicate app instances.")
      }
      try await wait("held native menu dismissed", seconds: 7) { self.events().contains("menu-close\n") }
      let cancelledDeadline = Date().addingTimeInterval(4)
      while Date() < cancelledDeadline {
        guard let hide = button("Hide Items", in: application), isEnabled(hide),
          fixtureOnscreen(pid: fixture.processIdentifier) == true else {
          throw CheckFailure("The cancelled handoff rehides items or leaves Settings disabled after dismissal.")
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      print("PASS: Settings interrupted an active fixture menu, retained one app instance, and prevented later automatic hiding")
      return 0
    } catch {
      print("FAILED: \(error.localizedDescription)")
      if let production, production.isRunning {
        let app = AXUIElementCreateApplication(production.processIdentifier)
        print("Production UI: show-items=\(button("Show Items", in: app) != nil), hide-items=\(button("Hide Items", in: app) != nil), permission-granted=\(find("Granted", in: app) != nil), permission-denied=\(find("Not granted", in: app) != nil)")
        printOwnControlGeometry(app)
        for (index, snapshot) in controlSnapshots.enumerated() {
          print("Own status-window transition \(index): \(snapshot)")
        }
        let ownPreferences = UserDefaults.standard.persistentDomain(forName: appID) ?? [:]
        for name in ["TrayNookLauncher", "TrayNook.HiddenBoundary"] {
          let position = ownPreferences["NSStatusItem Preferred Position \(name)"] as? NSNumber
          print("Own saved position \(name): \(position?.stringValue ?? "unset")")
        }
        let knownErrors = [
          "Grant Accessibility to discover and organize menu-bar items.",
          "Some apps did not respond. Items are revealed; retry when those apps respond.",
          "Menu-bar items changed. Review the layout before hiding again.",
          "An unassigned or protected item is behind the separator. Items have been revealed.",
          "A new, protected, or unassigned item is behind the separator. Keep it on the right before hiding.",
          "macOS could not place the separator safely beside protected items.",
          "This item is unavailable, ambiguous, or outside the visible menu bar. Reveal it manually and refresh.",
          "Another interface covers this item. Close menus or windows and try again.",
          "This item cannot be reached safely at its reported position.",
          "Hold Command and drag the │ separator to the left of the TrayNook tray icon. Keep both on the visible right side of the menu bar.",
          "Release the mouse and keyboard, stop moving the pointer, then try again.",
          "Finish the current item interaction before opening another item.",
          "There is not enough space to show this item safely beside TrayNook. Other hidden items remain hidden.",
          "This item's original position cannot be restored safely. Other hidden items remain hidden.",
          "macOS could not show this item safely. Its return position is retained; other hidden items remain hidden.",
          "The selected item is not safely visible. Other hidden items remain hidden.",
          "The item could not return to its original position. Try restoring it again; other hidden items remain hidden.",
          "This item's native window cannot be identified safely. Other hidden items remain hidden.",
          "The item's native window changed. Other hidden items remain hidden.",
          "Physical input interrupted the action. The selected item can be restored without revealing the section.",
          "The menu bar is still changing. Try again when it has settled.",
          "A complete, fresh menu-bar inventory is unavailable. Refresh and try again.",
          "macOS could not route this item's move. Other hidden items remain hidden.",
          "The native action did not confirm a response. Check the app before trying again.",
          "Applying placements…",
        ]
        for message in knownErrors where find(message, in: app, role: kAXStaticTextRole as String, contains: true) != nil {
          // Print only a known generic message, never a source app name or inventory.
          print("Production message: \(message)")
        }
      }
      if let fixture {
        print("Fixture CG onscreen: \(String(describing: fixtureOnscreen(pid: fixture.processIdentifier)))")
        print("Fixture status windows: \(statusWindowSummary(pid: fixture.processIdentifier))")
        print("Fixture events: action=\(events().contains("action\n")), menu-open=\(events().contains("menu-open\n")), menu-close=\(events().contains("menu-close\n"))")
      }
      if let sentinel {
        print("Hidden sentinel CG onscreen: \(String(describing: fixtureOnscreen(pid: sentinel.processIdentifier)))")
        print("Handoff visibility witnesses: revealed=\(FileManager.default.fileExists(atPath: signal("sentinel-revealed").path)), unobservable=\(FileManager.default.fileExists(atPath: signal("sentinel-unobservable").path))")
      }
      if let data = try? Data(contentsOf: signal("menu-geometry.json")),
        let geometry = try? JSONDecoder().decode(FixtureMenuGeometry.self, from: data) {
        print("Fixture menu geometry: source=\(NSStringFromRect(geometry.source)), menu=\(NSStringFromRect(geometry.menu)), safe-status=\(NSStringFromRect(geometry.safeStatusArea)), display=\(NSStringFromRect(geometry.display))")
      }
      return 1
    }
  }

  private func launch(_ relativePath: String, arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = directory.appendingPathComponent(relativePath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    return process
  }

  private func events() -> String { (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? "" }

  private func armHandoffMonitor() async throws {
    for name in ["watch-hidden", "watch-ready", "sentinel-revealed", "sentinel-unobservable",
      "menu-geometry.json", "unsafe-menu-geometry.json", "menu-open-uptime", "menu-close-uptime",
      "pointer-witness.json"] {
      let url = signal(name)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    guard let pointer = CGEvent(source: nil)?.location else { throw CheckFailure("Pointer unavailable.") }
    try JSONEncoder().encode(pointer).write(to: signal("watch-pointer.json"), options: .atomic)
    try Data().write(to: signal("watch-hidden"))
    try await wait("independent hidden sentinel monitor armed", seconds: 3) {
      FileManager.default.fileExists(atPath: self.signal("watch-ready").path)
    }
    try requireHiddenSentinel()
  }

  private func requirePointerBudget() throws {
    let witness = try JSONDecoder().decode(PointerWitness.self,
      from: Data(contentsOf: signal("pointer-witness.json")))
    print("Pointer witness: \(witness.samples) samples, \(witness.displacedSamples) displaced, maximum \(Int(witness.maximumDistance)) pt, longest excursion \(Int(witness.maximumExcursionSeconds * 1000)) ms")
    guard witness.samples > 0, witness.maximumExcursionSeconds < 0.15,
      let data = try? Data(contentsOf: signal("watch-pointer.json")),
      let expected = try? JSONDecoder().decode(CGPoint.self, from: data),
      let actual = CGEvent(source: nil)?.location,
      hypot(actual.x - expected.x, actual.y - expected.y) <= 2 else {
      throw CheckFailure("Native handoff held the pointer away for 150 ms or failed to return it.")
    }
    if CommandLine.arguments.contains("--require-still-pointer"), witness.displacedSamples != 0 {
      throw CheckFailure("Native handoff displaced the pointer (strict zero-movement acceptance).")
    }
  }

  private func requireSafeMenuGeometry() throws {
    let geometry = try JSONDecoder().decode(FixtureMenuGeometry.self,
      from: Data(contentsOf: signal("menu-geometry.json")))
    guard geometry.isSafe,
      !FileManager.default.fileExists(atPath: signal("unsafe-menu-geometry.json").path) else {
      throw CheckFailure("The selected source or native menu was outside its display's safe visible area.")
    }
  }

  private func requireHiddenSentinel() throws {
    guard !FileManager.default.fileExists(atPath: signal("sentinel-revealed").path) else {
      throw CheckFailure("Proxy handoff transiently revealed the other hidden source (independent sentinel witness).")
    }
    guard !FileManager.default.fileExists(atPath: signal("sentinel-unobservable").path) else {
      throw CheckFailure("The hidden source became unobservable during proxy handoff; concealment cannot be verified.")
    }
    guard let sentinel, sentinel.isRunning, fixtureOnscreen(pid: sentinel.processIdentifier) == false else {
      throw CheckFailure("The hidden sentinel is no longer running and verifiably offscreen.")
    }
  }

  private func wait(_ description: String, seconds: Double, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return }
      if let production, !production.isRunning { throw CheckFailure("Production app exited during \(description).") }
      try await Task.sleep(for: .milliseconds(150))
    }
    throw CheckFailure("Timed out waiting for \(description).")
  }

  /// Read only our disposable fixture's WindowServer metadata, never titles or
  /// screenshots from other applications. nil is not accepted as concealed.
  private func fixtureOnscreen(pid: Int32) -> Bool? {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return nil }
    let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    // One status window per display; judge the main display's menu bar only.
    // Concealed windows keep their row, so the vertical range identifies it.
    let mainDisplay = CGDisplayBounds(CGMainDisplayID())
    let owned = windows.filter {
      guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == statusLevel,
        let bounds = $0[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
      return frame.minY >= mainDisplay.minY && frame.minY < mainDisplay.maxY
    }
    guard owned.count == 1, let window = owned.first else { return nil }
    return (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
  }

  private func statusWindowSummary(pid: Int32) -> String {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return "unavailable" }
    return windows.filter {
      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow))
    }.map { window in
      let bounds = (window[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .null
      return "\(NSStringFromRect(bounds)) onscreen=\((window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)"
    }.joined(separator: "; ")
  }

  private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
  }

  private func visibleStatusWindowPositions() -> [UInt32: CGFloat] {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return [:] }
    var positions: [UInt32: CGFloat] = [:]
    for window in windows {
      guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow)),
        (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
        let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
      positions[id] = frame.minX
    }
    return positions
  }

  private func verifyOriginalState() -> Bool {
    var preserved = true
    if [appID, fixtureID, sentinelID].contains(where: {
      !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
    }) || FileManager.default.fileExists(atPath: supportURL.path) {
      print("FAILED: disposable processes or the isolated layout directory survived cleanup.")
      preserved = false
    }
    if let sourceLayout {
      if (try? Data(contentsOf: sourceLayout.url)) == sourceLayout.data {
        print("PASS: original saved layout is unchanged byte-for-byte")
      } else {
        print("FAILED: original saved layout changed during the test; no original file was written by this runner.")
        preserved = false
      }
    }
    // Compare only surviving source windows visible before and after cleanup.
    // WindowServer's clipped windows do not expose a reliable native order.
    let after = visibleStatusWindowPositions()
    let shared = Set(sourceWindowOrder.keys).intersection(after.keys)
    if shared.count > 1 {
      let beforeOrder = shared.sorted {
        sourceWindowOrder[$0] == sourceWindowOrder[$1] ? $0 < $1 : sourceWindowOrder[$0]! < sourceWindowOrder[$1]!
      }
      let afterOrder = shared.sorted { after[$0] == after[$1] ? $0 < $1 : after[$0]! < after[$1]! }
      if beforeOrder == afterOrder {
        print("PASS: relative native order preserved for all \(shared.count) source windows visible before and after cleanup")
      } else {
        print("FAILED: relative native order changed for pre-existing visible source windows.")
        preserved = false
      }
    } else if !sourceWindowOrder.isEmpty {
      print("FAILED: insufficient surviving visible source windows to verify native order.")
      preserved = false
    }
    return preserved
  }

  private func recordControlWindows(pid: Int32) {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return }
    let owned = windows.filter {
      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow))
    }.compactMap { window -> String? in
      guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
      let visible = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
      return "frame=\(NSStringFromRect(frame)) onscreen=\(visible)"
    }.sorted().joined(separator: "; ")
    if controlSnapshots.last != owned && controlSnapshots.count < 20 { controlSnapshots.append(owned) }
  }

  private func printOwnControlGeometry(_ app: AXUIElement) {
    let frames = ownControlFrames(app)
    if frames.isEmpty { print("Own AX extras menu bar unavailable") }
    for label in frames.keys.sorted() {
      print("Own AX control (\(label)): \(NSStringFromRect(frames[label]!))")
    }
  }

  private func ownControlFrames(_ app: AXUIElement) -> [String: CGRect] {
    guard let extras = attribute(app, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID(),
      let children = attribute(unsafeDowncast(extras, to: AXUIElement.self), kAXChildrenAttribute as String) as? [AXUIElement]
    else { return [:] }
    var result: [String: CGRect] = [:]
    for (index, child) in children.enumerated() {
      var point = CGPoint.zero
      var size = CGSize.zero
      if let value = attribute(child, kAXPositionAttribute as String), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point)
      }
      if let value = attribute(child, kAXSizeAttribute as String), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size)
      }
      // Labels come only from our copied production process, never other apps.
      let label = attribute(child, kAXDescriptionAttribute as String) as? String ?? "unlabelled-\(index)"
      // AXExtrasMenuBar also exposes the live popover as an unlabelled child.
      guard label == "Open TrayNook" || label == "TrayNook hidden section separator" else { continue }
      result[label] = CGRect(origin: point, size: size)
    }
    return result
  }

  private func button(_ label: String, in app: AXUIElement) -> AXUIElement? {
    find(label, in: app, role: kAXButtonRole as String)
  }

  private func find(_ label: String, in app: AXUIElement, role: String? = nil, contains: Bool = false) -> AXUIElement? {
    var queue = [app]
    for key in ["AXExtrasMenuBar", kAXMenuBarAttribute as String] {
      if let menu = attribute(app, key), CFGetTypeID(menu) == AXUIElementGetTypeID() {
        queue.append(unsafeDowncast(menu, to: AXUIElement.self))
      }
    }
    var index = 0
    while index < queue.count && index < 1500 {
      let element = queue[index]
      index += 1
      let matchesRole = role == nil || attribute(element, kAXRoleAttribute as String) as? String == role
      if matchesRole && [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute].contains(where: {
        guard let value = attribute(element, $0 as String) as? String else { return false }
        return contains ? value.contains(label) : value == label
      }) { return element }
      if let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        queue.append(contentsOf: children)
      }
    }
    return nil
  }

  private func press(_ element: AXUIElement, description: String) throws {
    var owner: pid_t = 0
    guard let production, AXUIElementGetPid(element, &owner) == .success,
      owner == production.processIdentifier else {
      throw CheckFailure("Refusing an AX action outside the exact disposable production process.")
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success || result == .cannotComplete else {
      throw CheckFailure("AXPress failed for \(description): \(result.rawValue).")
    }
    // cannotComplete is provisional: subsequent observed UI and fixture events
    // must confirm delivery. Never issue a second press.
  }

  private func isEnabled(_ element: AXUIElement) -> Bool {
    (attribute(element, kAXEnabledAttribute as String) as? NSNumber)?.boolValue == true
  }

  func cleanup() async {
    for id in [appID, fixtureID, sentinelID] {
      let applications = NSRunningApplication.runningApplications(withBundleIdentifier: id)
      applications.forEach { $0.terminate() }
      for _ in 0..<40 {
        if applications.allSatisfy(\.isTerminated) { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      applications.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
      // Wait before removing domains, so a terminating fixture cannot recreate
      // its saved status-item positions after cleanup.
      for _ in 0..<20 {
        if applications.allSatisfy(\.isTerminated) { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      UserDefaults.standard.removePersistentDomain(forName: id)
    }
    UserDefaults.standard.synchronize()
    try? FileManager.default.removeItem(at: supportURL)
    try? await Task.sleep(for: .milliseconds(400))
  }
}

@main
enum DropdownUIRegression {
  @MainActor static func main() {
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let token = CommandLine.arguments[2]
    guard token.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { exit(2) }
    let app = NSApplication.shared
    let delegate = DropdownCheck(directory: URL(fileURLWithPath: CommandLine.arguments[1]), token: token)
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--cleanup") {
      Task { await delegate.cleanup(); exit(0) }
    } else { app.delegate = delegate }
    app.run()
    withExtendedLifetime(delegate) {}
  }
}

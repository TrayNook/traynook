import AppKit
import ApplicationServices

/// A real cross-process Accessibility check. It opens only its own disposable
/// window and menu, generates no pointer input, and creates no status items.
@MainActor final class MenuCheckDelegate: NSObject, NSApplicationDelegate {
  let signal: URL
  private var sourceWindow: NSWindow?
  var succeeded = false
  var isSource: Bool { CommandLine.arguments.contains("--source") }

  init(signal: URL) { self.signal = signal }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if isSource {
      let window = NSWindow(contentRect: NSRect(x: 260, y: 240, width: 360, height: 180),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "TrayNook existing-window fixture"
      window.isReleasedWhenClosed = false
      window.makeKeyAndOrderFront(nil)
      sourceWindow = window
      try? String(window.windowNumber).write(to: signal.appendingPathExtension("window"),
        atomically: true, encoding: .utf8)
      try? Data().write(to: signal.appendingPathExtension("ready"))
      Timer.scheduledTimer(timeInterval: 0.05, target: self,
        selector: #selector(openMenu(_:)), userInfo: nil, repeats: true)
      Timer.scheduledTimer(timeInterval: 10, target: NSApp!,
        selector: #selector(NSApplication.terminate(_:)), userInfo: nil, repeats: false)
    } else {
      Task { await check() }
    }
  }

  @objc private func openMenu(_ timer: Timer) {
    guard FileManager.default.fileExists(atPath: signal.path) else { return }
    timer.invalidate()
    let menu = NSMenu()
    menu.addItem(withTitle: "TrayNook disposable menu check", action: nil, keyEquivalent: "")
    let close = Timer(timeInterval: 0.25, target: menu,
      selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
    RunLoop.main.add(close, forMode: .common)
    menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 100), in: nil)
    try? Data().write(to: signal.appendingPathExtension("closed"))
  }

  private func check() async {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [signal.path, "--source"]
    defer {
      if child.isRunning { child.terminate(); child.waitUntilExit() }
      exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    do {
      guard AXIsProcessTrusted() else {
        print("FAILED: Allow Accessibility for the terminal running this check.")
        return
      }
      try child.run()
      for _ in 0..<60 {
        if FileManager.default.fileExists(atPath: signal.appendingPathExtension("ready").path) { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard let windowID = UInt32(try String(contentsOf: signal.appendingPathExtension("window"), encoding: .utf8)),
        ordinaryWindowIsVisible(windowID, owner: child.processIdentifier) else {
        print("FAILED: Preexisting ordinary window was not visible."); return
      }
      guard let interaction = NativeMenuInteraction(processIdentifier: child.processIdentifier) else {
        print("FAILED: Menu notification registration."); return
      }
      defer { interaction.cancel() }
      try Data().write(to: signal)
      guard await interaction.waitForDismissal(),
        FileManager.default.fileExists(atPath: signal.appendingPathExtension("closed").path),
        ordinaryWindowIsVisible(windowID, owner: child.processIdentifier) else {
        print("FAILED: Menu dismissal was not observed while the existing ordinary window stayed visible."); return
      }
      print("PASS: Menu dismissal was observed while the existing ordinary window stayed visible.")

      guard let noOpen = NativeMenuInteraction(processIdentifier: child.processIdentifier) else {
        print("FAILED: No-open registration."); return
      }
      defer { noOpen.cancel() }
      let started = ContinuousClock.now
      let unexpectedClose = await noOpen.waitForDismissal()
      let elapsed = started.duration(to: .now)
      guard !unexpectedClose, elapsed >= .seconds(1.5), elapsed < .seconds(3) else {
        print("FAILED: No-open fallback."); return
      }
      print("PASS: No menu returns false after about 1.5 seconds.")

      guard let cancellation = NativeMenuInteraction(processIdentifier: child.processIdentifier) else {
        print("FAILED: Cancellation registration."); return
      }
      defer { cancellation.cancel() }
      let waiting = Task { await cancellation.waitForDismissal() }
      try await Task.sleep(for: .milliseconds(100))
      waiting.cancel()
      guard await !waiting.value else { print("FAILED: Cancellation."); return }
      print("PASS: Cancellation returns false and removes observation.")
      succeeded = true
    } catch { print("FAILED: \(error.localizedDescription)") }
  }

  private func ordinaryWindowIsVisible(_ id: UInt32, owner: Int32) -> Bool {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { window in
      (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
        && (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner
        && (window[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.normalWindow))
    }
  }
}

@main enum NativeMenuInteractionCheck {
  @MainActor static func main() {
    guard CommandLine.arguments.count >= 2 else { exit(EXIT_FAILURE) }
    let app = NSApplication.shared
    let delegate = MenuCheckDelegate(signal: URL(fileURLWithPath: CommandLine.arguments[1]))
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
    exit(delegate.succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
  }
}

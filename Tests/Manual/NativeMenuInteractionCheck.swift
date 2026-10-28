import AppKit
import ApplicationServices

/// A real cross-process Accessibility check. It opens only its own disposable
/// menu, generates no pointer input, and creates no status items.
@MainActor final class MenuCheckDelegate: NSObject, NSApplicationDelegate {
  let signal: URL
  var succeeded = false
  var isSource: Bool { CommandLine.arguments.contains("--source") }

  init(signal: URL) { self.signal = signal }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if isSource {
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
  }

  private func check() async {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [signal.path, "--source"]
    defer {
      if child.isRunning { child.terminate(); child.waitUntilExit() }
      NSApp.terminate(nil)
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
      guard let interaction = NativeMenuInteraction(processIdentifier: child.processIdentifier) else {
        print("FAILED: Menu notification registration."); return
      }
      defer { interaction.cancel() }
      try Data().write(to: signal)
      guard await interaction.waitForDismissal() else {
        print("FAILED: No verified menu open/close cycle."); return
      }
      print("PASS: Verified native menu opened and closed.")

      guard let noOpen = NativeMenuInteraction(processIdentifier: child.processIdentifier) else {
        print("FAILED: No-open registration."); return
      }
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
      let waiting = Task { await cancellation.waitForDismissal() }
      try await Task.sleep(for: .milliseconds(100))
      waiting.cancel()
      guard await !waiting.value else { print("FAILED: Cancellation."); return }
      print("PASS: Cancellation returns false and removes observation.")
      succeeded = true
    } catch { print("FAILED: \(error.localizedDescription)") }
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

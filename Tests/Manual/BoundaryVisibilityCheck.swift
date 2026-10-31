import AppKit

func L(_ value: String) -> String { value }

@MainActor
private final class BoundaryVisibilityCheck: NSObject, NSApplicationDelegate {
  private var launcher: NSStatusItem?
  private var native: NativeMenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task {
      let result = await check()
      native?.remove()
      if let launcher { NativeMenuBarController.removePreservingPosition(launcher) }
      if let id = Bundle.main.bundleIdentifier, id.hasPrefix("io.github.mahenzon.TrayNook.BoundaryCheck.") {
        UserDefaults.standard.removePersistentDomain(forName: id)
      }
      exit(result)
    }
  }

  private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "BoundaryVisibilityCheck", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]) }
  }

  private func ownWindowCount() -> Int {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.filter {
      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
        && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow))
    }.count
  }

  private func check() async -> Int32 {
    do {
      try require(Bundle.main.bundleIdentifier?.hasPrefix("io.github.mahenzon.TrayNook.BoundaryCheck.") == true,
        "Run this check through Scripts/test-native-boundary.sh to isolate preferences.")
      for id in ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"] {
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
          "Quit TrayNook before running this isolated status-item check.")
      }
      let defaults = UserDefaults.standard
      let positionKey = "NSStatusItem Preferred Position TrayNook.HiddenBoundary"
      defaults.set(60.0, forKey: positionKey)
      defaults.set(0.0, forKey: "NSStatusItem Preferred Position TrayNookLauncher")
      let item = NSStatusBar.system.statusItem(withLength: 24)
      item.isVisible = false
      item.autosaveName = "TrayNookLauncher"
      item.button?.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Boundary check")
      item.isVisible = true
      launcher = item
      try await Task.sleep(for: .milliseconds(250))
      let baseline = ownWindowCount()
      try require(baseline > 0,
        "The isolated test launcher is not visible; frame: \(String(describing: item.button?.window?.frame)).")
      let controller = NativeMenuBarController(launcher: item)
      native = controller
      try await Task.sleep(for: .milliseconds(250))
      try require(ownWindowCount() == baseline && controller.setupMessage == nil,
        "Initial revealed state allocated an extra native slot or reported a setup warning.")
      for cycle in 1...3 {
        controller.reveal(keepBoundaryVisible: true)
        try await Task.sleep(for: .milliseconds(250))
        let shown = ownWindowCount()
        try require(shown > baseline, "Preparation did not restore the boundary's native slot.")
        controller.reveal()
        try await Task.sleep(for: .milliseconds(250))
        let revealed = ownWindowCount()
        try require(revealed == baseline && controller.setupMessage == nil,
          "Revealing items left a native boundary slot or setup warning.")
        try require((defaults.object(forKey: positionKey) as? NSNumber)?.doubleValue == 60,
          "Toggling boundary visibility changed its saved position.")
        print("PASS: cycle \(cycle), own status windows \(baseline) → \(shown) → \(revealed)")
      }
      print("BOUNDARY_VISIBILITY_CHECK_PASSED")
      return 0
    } catch { print("FAILED: \(error.localizedDescription)"); return 1 }
  }
}

@main
private enum Main {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = BoundaryVisibilityCheck()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    withExtendedLifetime(delegate) {}
  }
}

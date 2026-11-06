import AppKit
import Testing

@testable import TrayNook

@Suite("Native display changes", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct DisplayChangeTests {
  @Test("A screen notification does not reveal or remove the native boundary")
  func screenNotificationPreservesBoundary() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let preferenceKeys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let defaults = UserDefaults.standard
    let previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let native = NativeMenuBarController(launcher: launcher)
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      for key in preferenceKeys {
        if let value = previousPreferences[key] { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
      defaults.synchronize()
    }
    #expect(native.verifyDisplayChangeBehavior(),
      "An expanded boundary, selected handoff, and invalidated operation must survive screen changes.")
    native.reveal(keepBoundaryVisible: true)
    var reveals = 0
    native.onReveal = { reveals += 1 }
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(reveals == 0)
    #expect(native.hasVisibleBoundary)
  }
}

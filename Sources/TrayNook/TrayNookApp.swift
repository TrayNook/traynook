import AppKit
import SwiftUI
import Carbon
import InventoryIdentityCore

@main
enum TrayNookApp {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--diagnose") {
      let snapshot = AccessibilityInventoryScanner().scan()
      print("Accessibility: \(snapshot.permission.rawValue)")
      print("Inventory: \(snapshot.completeness.rawValue)")
      print("Items: \(snapshot.metrics.sourceItemCount)")
      print("Incomplete apps: \(snapshot.metrics.incompleteApplicationCount)")
      print("Scan milliseconds: \(Int(snapshot.metrics.durationMilliseconds))")
      print("Screen Recording: \(ProxyImageCapture.isAuthorized ? "granted" : "not granted")")
      if ProxyImageCapture.isAuthorized {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let status = windows.filter { ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)) }
        var onscreen = 0, captured = 0, offscreenCaptured = 0
        for window in status {
          let isOnscreen = window[kCGWindowIsOnscreen as String] as? Bool == true
          if isOnscreen { onscreen += 1 }
          guard let id = window[kCGWindowNumber as String] as? UInt32,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
          let frame = ItemFrame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
          guard ProxyImageCapture.capture(windowID: id, frame: frame) != nil else { continue }
          captured += 1
          if !isOnscreen { offscreenCaptured += 1 }
        }
        // Offscreen windows are expected to fail: the public API does not composite them.
        print("Status windows: \(status.count) (\(onscreen) onscreen, \(status.count - onscreen) offscreen)")
        print("Captured onscreen: \(captured - offscreenCaptured) of \(onscreen); captured offscreen: \(offscreenCaptured)")
      }
      return
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    withExtendedLifetime(delegate) {}
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
  private var launcher: NSStatusItem!
  private var model: AppModel!
  private var settingsWindow: NSWindow?
  private let popover = NSPopover()
  private var dropdownRequest = 0
  private let smokeTest = CommandLine.arguments.contains("--smoke-test")

  func applicationDidFinishLaunching(_ notification: Notification) {
    launcher = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if !smokeTest { launcher.autosaveName = "TrayNookLauncher" }
    launcher.behavior = []
    launcher.button?.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: L("TrayNook"))
    launcher.button?.image?.isTemplate = true
    launcher.button?.setAccessibilityLabel(L("Open TrayNook"))
    launcher.button?.toolTip = L("TrayNook — click for dropdown, right-click for controls")
    launcher.button?.target = self
    launcher.button?.action = #selector(launcherClicked)
    launcher.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    let native = NativeMenuBarController(launcher: launcher)
    if smokeTest && !AppModel.verifyRecoveryBehavior(native: native) {
      native.remove()
      fputs("TRAYNOOK_MODEL_SMOKE_FAILED\n", stderr)
      exit(1)
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let store = LayoutStore(url: support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.mahenzon.TrayNook.dev")
      .appendingPathComponent("layout.json"))
    model = AppModel(native: native, store: smokeTest ? nil : store)
    model.closeDropdown = { [weak self] in self?.popover.performClose(nil) }
    model.showSettings = { [weak self] in self?.openSettings() }
    installMainMenu()
    popover.behavior = .transient
    popover.delegate = self
    popover.animates = false
    NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    if smokeTest {
      openSettings()
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        guard self.launcher.button?.window != nil, let window = self.settingsWindow,
          window.isVisible, window.contentView != nil, !self.model.native.isConcealed
        else { fputs("TRAYNOOK_SMOKE_FAILED\n", stderr); exit(1) }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
          CommandLine.arguments.indices.contains(index + 1), let view = window.contentView,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
          view.cacheDisplay(in: view.bounds, to: bitmap)
          try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        print("TRAYNOOK_SMOKE_OK")
        NSApp.terminate(nil)
      }
    } else {
      // Settings opens only when something needs the user: a missing
      // permission, nothing hidden yet, or a failed launch restore (AppModel).
      model.start()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model?.stop()
    if let launcher { NativeMenuBarController.removePreservingPosition(launcher) }
    return .terminateNow
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func popoverDidClose(_ notification: Notification) { model.dropdownClosed() }
  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) === settingsWindow else { return }
    NSApp.setActivationPolicy(.accessory)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    modelLog.notice("settings: reopen event")
    openSettings(); return true
  }
  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

  @objc private func environmentChanged(_ notification: Notification) {
    dropdownRequest += 1
    popover.performClose(nil)
    model.reveal()
    model.message = L("Display or session changed. Items are revealed; review your layout before hiding.")
  }

  @objc private func launcherClicked() {
    dropdownRequest += 1
    let request = dropdownRequest
    guard let button = launcher.button else { return }
    if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
      let menu = NSMenu()
      menu.autoenablesItems = false
      addMenuItem(menu, L("Open Settings"), #selector(openSettings), key: ",")
      addMenuItem(menu, model.concealed ? L("Show Items") : L("Hide Items"), #selector(toggleItems))
      menu.items.last?.isEnabled = model.concealed || model.canEdit
      menu.addItem(.separator())
      addMenuItem(menu, L("Reveal All Items"), #selector(revealItems))
      addMenuItem(menu, L("Quit TrayNook"), #selector(quit), key: "q")
      launcher.menu = menu
      button.performClick(nil)
      launcher.menu = nil
      return
    }
    if popover.isShown { popover.performClose(nil); return }
    guard model.permissionGranted else { model.selectedTab = 1; openSettings(); return }
    model.openDropdown { [weak self] in
      guard let self, self.dropdownRequest == request, let button = self.launcher.button else { return }
      let width = min(700, (button.window?.screen?.visibleFrame.width ?? 700) - 40)
      self.popover.contentViewController = NSHostingController(rootView: DropdownView(model: self.model, maximumWidth: width))
      self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
      self.popover.contentViewController?.view.window?.makeKey()
    }
  }

  @objc func openSettings() {
    dropdownRequest += 1
    popover.performClose(nil)
    if model?.busy == true { model.reveal() }
    if settingsWindow == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.title = L("TrayNook Settings")
      window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      if !smokeTest { window.setFrameAutosaveName("TrayNookSettings") }
      settingsWindow = window
    }
    // Visible in Cmd-Tab and the Dock only while Settings is open.
    NSApp.setActivationPolicy(.regular)
    settingsWindow?.deminiaturize(nil)
    settingsWindow?.collectionBehavior.insert(.moveToActiveSpace)
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func toggleItems() { model.toggleConcealment() }
  @objc private func revealItems() { model.reveal() }
  @objc private func quit() { NSApp.terminate(nil) }

  private func installMainMenu() {
    let menu = NSMenu()
    let application = NSMenu()
    addMenuItem(application, L("Open Settings"), #selector(openSettings), key: ",")
    application.addItem(.separator())
    addMenuItem(application, L("Quit TrayNook"), #selector(quit), key: "q")
    let appItem = NSMenuItem(); appItem.submenu = application; menu.addItem(appItem)
    let edit = NSMenu(title: L("Edit"))
    edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
    editItem.submenu = edit; menu.addItem(editItem)
    NSApp.mainMenu = menu
  }

  private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    menu.addItem(item)
  }
}

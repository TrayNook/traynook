import AppKit
import InventoryIdentityCore

@MainActor
private final class BoundaryAppDelegate: NSObject, NSApplicationDelegate,
  NSMenuDelegate
{
  private let expandedWidth: CGFloat
  private let statusBar = NSStatusBar.system
  private var launcher: NSStatusItem?
  private var boundary: NSStatusItem?
  private var toggleItems: [NSMenuItem] = []
  private var isExpanded = false

  init(configuration: BoundaryConfiguration) {
    expandedWidth = configuration.expandedWidth
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installStatusItems()
  }

  func applicationWillTerminate(_ notification: Notification) {
    removeStatusItems()
  }

  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    removeStatusItems()
    return .terminateNow
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    refreshToggleItems()
  }

  private func installStatusItems() {
    let boundary = statusBar.statusItem(
      withLength: NSStatusItem.squareLength
    )
    boundary.button?.title = "│"
    boundary.button?.toolTip = "TrayNook prototype boundary"
    boundary.button?.setAccessibilityLabel(
      "TrayNook prototype boundary"
    )
    boundary.menu = makeMenu()
    self.boundary = boundary

    let launcher = statusBar.statusItem(
      withLength: NSStatusItem.squareLength
    )
    if let image = NSImage(
      systemSymbolName: "tray.full",
      accessibilityDescription: "TrayNook boundary prototype"
    ) {
      image.isTemplate = true
      launcher.button?.image = image
    } else {
      launcher.button?.title = "TN"
    }
    launcher.button?.toolTip = "TrayNook boundary prototype"
    launcher.button?.setAccessibilityLabel(
      "TrayNook boundary prototype"
    )
    launcher.menu = makeMenu()
    self.launcher = launcher
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    let toggle = NSMenuItem(
      title: "Expand Boundary",
      action: #selector(toggleBoundary),
      keyEquivalent: ""
    )
    toggle.target = self
    menu.addItem(toggle)
    toggleItems.append(toggle)

    menu.addItem(.separator())

    let quit = NSMenuItem(
      title: "Quit Boundary Prototype",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quit.target = self
    menu.addItem(quit)
    return menu
  }

  @objc private func toggleBoundary() {
    guard let boundary else {
      return
    }

    guard isExpanded || launcherIsOnVerifiedSafeSide else {
      NSSound.beep()
      return
    }

    isExpanded.toggle()
    boundary.length =
      isExpanded ? expandedWidth : NSStatusItem.squareLength
    refreshToggleItems()

    if isExpanded {
      Task { @MainActor [weak self] in
        await Task.yield()
        self?.verifyLauncherRemainedVisible()
      }
    }
  }

  private var launcherIsOnVerifiedSafeSide: Bool {
    guard
      let boundaryWindow = boundary?.button?.window,
      let launcherWindow = launcher?.button?.window,
      let boundaryScreen = boundaryWindow.screen,
      let launcherScreen = launcherWindow.screen,
      boundaryScreen === launcherScreen
    else {
      return false
    }

    let boundaryFrame = boundaryWindow.frame
    let launcherFrame = launcherWindow.frame
    guard
      !boundaryFrame.isEmpty,
      !boundaryFrame.isNull,
      boundaryFrame.minX.isFinite,
      boundaryFrame.maxX.isFinite,
      !launcherFrame.isEmpty,
      !launcherFrame.isNull,
      launcherFrame.minX.isFinite,
      launcherFrame.maxX.isFinite
    else {
      return false
    }
    return launcherFrame.minX >= boundaryFrame.maxX
  }

  private func refreshToggleItems() {
    let canExpand = launcherIsOnVerifiedSafeSide
    for toggleItem in toggleItems {
      if isExpanded {
        toggleItem.title = "Collapse Boundary"
        toggleItem.isEnabled = true
      } else if canExpand {
        toggleItem.title = "Expand Boundary"
        toggleItem.isEnabled = true
      } else {
        toggleItem.title = "Move Launcher Right of Boundary First"
        toggleItem.isEnabled = false
      }
    }
  }

  private func verifyLauncherRemainedVisible() {
    guard isExpanded else {
      return
    }
    guard
      let launcherWindow = launcher?.button?.window,
      let screen = launcherWindow.screen,
      isUsable(launcherWindow.frame),
      launcherWindow.frame.intersects(screen.frame)
    else {
      boundary?.length = NSStatusItem.squareLength
      isExpanded = false
      refreshToggleItems()
      NSSound.beep()
      return
    }
  }

  private func isUsable(_ frame: CGRect) -> Bool {
    !frame.isEmpty
      && !frame.isNull
      && frame.minX.isFinite
      && frame.maxX.isFinite
      && frame.minY.isFinite
      && frame.maxY.isFinite
  }

  @objc private func quit() {
    removeStatusItems()
    NSApplication.shared.terminate(nil)
  }

  private func removeStatusItems() {
    if let boundary {
      boundary.length = NSStatusItem.squareLength
      statusBar.removeStatusItem(boundary)
      self.boundary = nil
    }
    if let launcher {
      statusBar.removeStatusItem(launcher)
      self.launcher = nil
    }
    isExpanded = false
    toggleItems.removeAll()
  }
}

@main
private enum BoundarySpike {
  @MainActor
  static func main() {
    if CommandLine.arguments.dropFirst().contains("--help") {
      printUsage()
      return
    }

    do {
      let configuration = try BoundaryConfiguration(
        arguments: CommandLine.arguments
      )
      let application = NSApplication.shared
      let delegate = BoundaryAppDelegate(configuration: configuration)
      application.setActivationPolicy(.accessory)
      application.delegate = delegate
      application.run()
      withExtendedLifetime(delegate) {}
    } catch {
      FileHandle.standardError.write(
        Data("error: \(error)\n\n".utf8)
      )
      printUsage()
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func printUsage() {
    print(
      """
      TrayNook disposable menu-bar boundary spike

      Usage:
        traynook-boundary-spike [--expanded-width POINTS]

      The boundary starts collapsed. Command-drag the Launcher to the right of
      the visible separator, place the separator at the test boundary, then
      expand explicitly from either prototype item's menu. Normal Quit removes
      both status items.
      """
    )
  }
}

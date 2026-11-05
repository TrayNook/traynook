import AppKit
import ApplicationServices
import Foundation

/// Watches one native interaction through menu events and transient windows.
@MainActor
final class NativeMenuInteraction {
  private let application: AXUIElement
  private let processIdentifier: Int32
  private let ownerApplication: NSRunningApplication?
  private var dismissalState: DismissalState
  private var observer: AXObserver?
  private var registered: [CFString] = []
  private var openMenus: [AXUIElement] = []
  private var cancelled = false
  var observedWindowIDs: Set<UInt32> { dismissalState.observedWindowIDs }
  var observedInterface: Bool { dismissalState.observedInterface }

  /// Construct before clicking so even a short-lived menu is observed.
  init?(processIdentifier: Int32) {
    guard processIdentifier > 0 else { return nil }
    self.processIdentifier = processIdentifier
    ownerApplication = NSRunningApplication(processIdentifier: processIdentifier)
    dismissalState = DismissalState(windowsBefore: Self.visibleWindowIDs(of: processIdentifier))
    application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.2)
    var created: AXObserver?
    let result = AXObserverCreate(processIdentifier, { _, element, notification, context in
      guard let context else { return }
      let interaction = Unmanaged<NativeMenuInteraction>.fromOpaque(context).takeUnretainedValue()
      // This observer's source is installed only on the main run loop.
      MainActor.assumeIsolated {
        interaction.receive(element, notification: notification)
      }
    }, &created)
    guard result == .success, let created else { return }
    observer = created
    for notification in [kAXMenuOpenedNotification, kAXMenuClosedNotification] {
      guard AXObserverAddNotification(created, application, notification as CFString,
        Unmanaged.passUnretained(self).toOpaque()) == .success else {
        removeMenuObserver()
        return
      }
      registered.append(notification as CFString)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
  }

  /// True requires observed menu/window dismissal, never merely an elapsed timeout.
  func waitForDismissal(retainingObservationOnTimeout: Bool = false) async -> Bool {
    defer { if !retainingObservationOnTimeout || Task.isCancelled { cancel() } }
    let started = ContinuousClock.now
    while !cancelled && !Task.isCancelled {
      let now = ContinuousClock.now
      if dismissalObserved(at: now) { return true }
      // The caller transfers this observer to a background watcher after timeout.
      if started.duration(to: now) >= .seconds(observedInterface ? 60 : 1.5) { return false }
      do { try await Task.sleep(for: .milliseconds(50)) }
      catch { cancel(); return false }
    }
    cancel()
    return false
  }

  func dismissalObserved(at now: ContinuousClock.Instant = .now) -> Bool {
    guard !cancelled else { return false }
    let snapshot = Self.windowSnapshot(of: processIdentifier)
    return dismissalState.dismissed(currentWindows: snapshot?.visibleIDs,
      candidatePanels: snapshot?.panelIDs,
      ownerTerminated: ownerApplication?.isTerminated == true, at: now)
  }

  func cancel() {
    cancelled = true
    removeMenuObserver()
    openMenus.removeAll()
  }

  private func removeMenuObserver() {
    guard let observer else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    for notification in registered {
      AXObserverRemoveNotification(observer, application, notification)
    }
    registered.removeAll()
    self.observer = nil
  }

  /// Existing app windows do not belong to a newly opened menu or popover.
  static func visibleWindowIDs(of pid: Int32) -> Set<UInt32>? {
    windowSnapshot(of: pid)?.visibleIDs
  }

  private static func windowSnapshot(of pid: Int32) -> WindowSnapshot? {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    let rows = NSScreen.screens.compactMap { screen -> CGRect? in
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
      let bounds = CGDisplayBounds(id)
      return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
        height: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
    }
    return windowSnapshot(in: windows, owner: pid, menuBarRows: rows)
  }

  struct WindowSnapshot {
    let visibleIDs: Set<UInt32>
    let panelIDs: Set<UInt32>
  }

  static func windowSnapshot(in windows: [[String: Any]]?, owner pid: Int32,
    menuBarRows: [CGRect]) -> WindowSnapshot? {
    guard let windows else { return nil }
    var visible: Set<UInt32> = []
    var panels: Set<UInt32> = []
    for window in windows {
      guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
      guard owner == pid else { continue }
      guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
      // Once observed, presence is independent of later window shape or level.
      visible.insert(id)
      guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        isPanelWindow(frame: frame, layer: layer, menuBarRows: menuBarRows) else { continue }
      panels.insert(id)
    }
    return WindowSnapshot(visibleIDs: visible, panelIDs: panels)
  }

  static func isPanelWindow(frame: CGRect, layer: Int, menuBarRows: [CGRect]) -> Bool {
    guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { return false }
    guard layer == Int(CGWindowLevelForKey(.statusWindow)) else { return true }
    guard !menuBarRows.isEmpty else { return false }
    return !menuBarRows.contains {
      frame.minY < $0.maxY && frame.maxY > $0.minY && frame.height <= 2 * $0.height
    }
  }

  private func receive(_ menu: AXUIElement, notification: CFString) {
    guard !cancelled else { return }
    if notification as String == kAXMenuOpenedNotification {
      dismissalState.menuOpened()
      if !openMenus.contains(where: { CFEqual($0, menu) }) { openMenus.append(menu) }
    } else if notification as String == kAXMenuClosedNotification,
      let index = openMenus.firstIndex(where: { CFEqual($0, menu) }) {
      openMenus.remove(at: index)
      if openMenus.isEmpty { dismissalState.menusClosed(at: .now) }
    }
  }

  struct DismissalState {
    let windowsBefore: Set<UInt32>?
    private(set) var observedWindowIDs: Set<UInt32> = []
    private var observedMenu = false
    private var menuIsOpen = false
    private var lastMenuClose: ContinuousClock.Instant?
    private var lastWindowClose: ContinuousClock.Instant?

    init(windowsBefore: Set<UInt32>?) { self.windowsBefore = windowsBefore }

    var observedInterface: Bool { observedMenu || !observedWindowIDs.isEmpty }

    mutating func menuOpened() {
      observedMenu = true
      menuIsOpen = true
      lastMenuClose = nil
    }

    mutating func menusClosed(at now: ContinuousClock.Instant) {
      menuIsOpen = false
      lastMenuClose = now
    }

    mutating func dismissed(currentWindows: Set<UInt32>?, candidatePanels: Set<UInt32>? = nil,
      ownerTerminated: Bool = false, at now: ContinuousClock.Instant) -> Bool {
      if ownerTerminated { return true }
      if let windowsBefore, let currentWindows {
        observedWindowIDs.formUnion((candidatePanels ?? currentWindows).subtracting(windowsBefore))
        if !observedWindowIDs.isEmpty, currentWindows.isDisjoint(with: observedWindowIDs) {
          if lastWindowClose == nil { lastWindowClose = now }
        } else { lastWindowClose = nil }
      } else { lastWindowClose = nil }
      guard observedInterface, !menuIsOpen else { return false }
      if observedMenu {
        guard let lastMenuClose, lastMenuClose.duration(to: now) >= .milliseconds(150) else { return false }
      }
      if !observedWindowIDs.isEmpty {
        guard let lastWindowClose, lastWindowClose.duration(to: now) >= .milliseconds(150) else { return false }
      }
      return true
    }
  }
}

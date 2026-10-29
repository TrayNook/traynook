import ApplicationServices
import Foundation

/// Watches one native interaction through menu events and transient windows.
@MainActor
final class NativeMenuInteraction {
  private let application: AXUIElement
  private let processIdentifier: Int32
  private let windowsBefore: Set<UInt32>?
  private var observer: AXObserver?
  private var registered: [CFString] = []
  private var openMenus: [AXUIElement] = []
  private var observedOpen = false
  private var lastClose: ContinuousClock.Instant?
  private var cancelled = false
  private(set) var observedWindowIDs: Set<UInt32> = []
  var observedInterface: Bool { observedOpen || !observedWindowIDs.isEmpty }

  /// Construct before clicking so even a short-lived menu is observed.
  init?(processIdentifier: Int32) {
    guard processIdentifier > 0 else { return nil }
    self.processIdentifier = processIdentifier
    windowsBefore = Self.panelWindows(of: processIdentifier)
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
  func waitForDismissal() async -> Bool {
    defer { cancel() }
    let started = ContinuousClock.now
    var lastWindowClose: ContinuousClock.Instant?
    while !cancelled && !Task.isCancelled {
      let now = ContinuousClock.now
      if let windowsBefore, let current = Self.panelWindows(of: processIdentifier) {
        observedWindowIDs.formUnion(current.subtracting(windowsBefore))
        if !observedWindowIDs.isEmpty, current.isDisjoint(with: observedWindowIDs) {
          if lastWindowClose == nil { lastWindowClose = now }
        } else { lastWindowClose = nil }
      } else { lastWindowClose = nil }
      if observedOpen, openMenus.isEmpty, let lastClose,
        lastClose.duration(to: now) >= .milliseconds(150) { return true }
      if let lastWindowClose, lastWindowClose.duration(to: now) >= .milliseconds(150) { return true }
      if started.duration(to: now) >= .seconds(observedInterface ? 60 : 1.5) { return false }
      do { try await Task.sleep(for: .milliseconds(50)) }
      catch { return false }
    }
    return false
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
  static func panelWindows(of pid: Int32) -> Set<UInt32>? {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    return Set(windows.compactMap { window in
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
        layer != Int(CGWindowLevelForKey(.statusWindow)),
        let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
      return id
    })
  }

  private func receive(_ menu: AXUIElement, notification: CFString) {
    guard !cancelled else { return }
    if notification as String == kAXMenuOpenedNotification {
      observedOpen = true
      lastClose = nil
      if !openMenus.contains(where: { CFEqual($0, menu) }) { openMenus.append(menu) }
    } else if notification as String == kAXMenuClosedNotification,
      let index = openMenus.firstIndex(where: { CFEqual($0, menu) }) {
      openMenus.remove(at: index)
      if openMenus.isEmpty { lastClose = .now }
    }
  }
}

import ApplicationServices
import Foundation

/// Watches one native menu interaction. Custom popovers without menu events
/// deliberately return false so they remain revealed for manual dismissal.
@MainActor
final class NativeMenuInteraction {
  private let application: AXUIElement
  private var observer: AXObserver?
  private var registered: [CFString] = []
  private var openMenus: [AXUIElement] = []
  private var observedOpen = false
  private var lastClose: ContinuousClock.Instant?
  private var cancelled = false

  /// Construct before clicking so even a short-lived menu is observed.
  init?(processIdentifier: Int32) {
    guard processIdentifier > 0 else { return nil }
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
    guard result == .success, let created else { return nil }
    observer = created
    for notification in [kAXMenuOpenedNotification, kAXMenuClosedNotification] {
      guard AXObserverAddNotification(created, application, notification as CFString,
        Unmanaged.passUnretained(self).toOpaque()) == .success else {
        cancel()
        return nil
      }
      registered.append(notification as CFString)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
  }

  /// True requires a matching open/close cycle, never merely an elapsed timeout.
  func waitForDismissal() async -> Bool {
    defer { cancel() }
    let started = ContinuousClock.now
    while !cancelled && !Task.isCancelled {
      let now = ContinuousClock.now
      if observedOpen, openMenus.isEmpty, let lastClose,
        lastClose.duration(to: now) >= .milliseconds(150) { return true }
      if started.duration(to: now) >= .seconds(observedOpen ? 60 : 1.5) { return false }
      do { try await Task.sleep(for: .milliseconds(50)) }
      catch { return false }
    }
    return false
  }

  func cancel() {
    cancelled = true
    guard let observer else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    for notification in registered {
      AXObserverRemoveNotification(observer, application, notification)
    }
    registered.removeAll()
    self.observer = nil
    openMenus.removeAll()
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

import AppKit
import ApplicationServices
import InventoryIdentityCore
import os

/// Native decisions are logged so a failed run can be read back with
/// `log show --predicate 'subsystem BEGINSWITH "io.github.mahenzon.TrayNook"'`.
let nativeLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.mahenzon.TrayNook", category: "native")

private struct MenuBarFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) {
    errorDescription = message
    nativeLog.error("failure: \(message, privacy: .public)")
  }
}

enum NativeMenuActionError: LocalizedError, Equatable {
  // AXPress can stay inside a native menu's tracking loop after delivery.
  // Callers must verify an observed menu cycle, and must never retry the press.
  case responseTimedOut
  case inputNotIdle

  var errorDescription: String? {
    switch self {
    case .responseTimedOut:
      L("The native action did not confirm a response. Check the app before trying again.")
    case .inputNotIdle:
      L("Release the mouse and keyboard, stop moving the pointer, then try again.")
    }
  }
}

private struct MenuBarEnvironment: Equatable {
  let display: UInt32
  let displayWidth: Double
  let displayFrame: ItemFrame
  let safeFrame: ItemFrame
  let occlusionFrame: ItemFrame?
  let boundary: ItemFrame
  let launcher: ItemFrame
}

/// The separator is a real status item. Its right edge separates the two native
/// sections; growing it pushes items on its left out of the menu bar.
@MainActor
final class NativeMenuBarController: NSObject {
  private let launcher: NSStatusItem
  private var separator: NSStatusItem?
  private let compactWidth: CGFloat = 18
  private var generation = 0
  private var pendingRelease: CGEvent?
  /// Persistent identity key → process trusted to own that concealed item.
  private var concealedSourcePIDs: [String: Int32] = [:]
  private var cursorHidden = false
  private(set) var isConcealed = false
  /// The AX menu-bar row follows the display that holds the active app's key
  /// window, so geometry is computed for the display of the latest inventory.
  private var activeDisplay: CGDirectDisplayID?
  private(set) var isBusy = false
  var onReveal: (() -> Void)?
  var onExternalReveal: (() -> Void)?

  /// Status-item reordering needs the real pointer path, so the pointer does
  /// jump during a move. Hiding it makes the jump invisible; the pointer is
  /// warped back and shown again as soon as the synthesized input is done.
  private func hideCursor() {
    guard !cursorHidden else { return }
    // Unverified on device: WindowServer may ignore this for a process that
    // is not frontmost even though the call reports success. The dropdown
    // regression's cursor witness is the check; see docs/HANDOFF.md.
    cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
  }

  private func showCursor() {
    guard cursorHidden else { return }
    cursorHidden = false
    CGDisplayShowCursor(CGMainDisplayID())
  }

  init(launcher: NSStatusItem) {
    self.launcher = launcher
    super.init()
    let smokeTest = CommandLine.arguments.contains("--smoke-test")
    if !smokeTest {
      Self.restorePosition(of: launcher, name: "TrayNookLauncher", fallback: 0)
    }
    let separator = NSStatusBar.system.statusItem(withLength: compactWidth)
    if !smokeTest {
      Self.restorePosition(of: separator, name: "TrayNook.HiddenBoundary", fallback: initialBoundaryPosition)
    }
    separator.button?.title = "│"
    separator.button?.alignment = .right
    separator.button?.toolTip = L("TrayNook separator — Command-drag left of the tray icon")
    separator.button?.setAccessibilityLabel(L("TrayNook hidden section separator"))
    separator.button?.target = self
    separator.button?.action = #selector(separatorClicked)
    self.separator = separator
    NotificationCenter.default.addObserver(
      self, selector: #selector(environmentChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(environmentChanged),
      name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(environmentChanged),
      name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
  }

  var setupMessage: String? {
    if let environment = environment() {
      let edge = ItemFrame(x: environment.boundary.maxX - 2, y: environment.boundary.y,
        width: 2, height: environment.boundary.height)
      if !environment.safeFrame.contains(environment.launcher) || !environment.safeFrame.contains(edge) {
        return L("There is not enough visible menu-bar space for TrayNook's controls. Temporarily quit a menu-bar app to free space, then Command-drag the │ separator to the left of TrayNook's tray icon.")
      }
    }
    guard let environment = environment(),
      Self.launcherIsSafe(environment.launcher, boundary: environment.boundary,
        safeFrame: environment.safeFrame, expanded: isConcealed)
    else {
      return L("Hold Command and drag the │ separator to the left of the TrayNook tray icon. Keep both on the visible right side of the menu bar.")
    }
    return nil
  }

  func reveal() {
    nativeLog.info("reveal (was concealed: \(self.isConcealed))")
    generation += 1
    releasePointer()
    showCursor()
    separator?.length = compactWidth
    isConcealed = false
    concealedSourcePIDs.removeAll()
    pendingActivation = nil
    onReveal?()
  }

  /// A concealed source restarted. Trust its new process for the same identity
  /// so its proxy keeps working without reopening the whole section.
  func adoptProcess(key: String, pid: Int32) {
    guard isConcealed else { return }
    concealedSourcePIDs[key] = pid
  }

  func remove() {
    reveal()
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    if let separator { Self.removePreservingPosition(separator) }
    separator = nil
  }

  /// AppKit restores this position when autosave visibility is attached. Keep
  /// the undocumented defaults key isolated to our own two status items.
  private static func restorePosition(of item: NSStatusItem, name: String, fallback: Double, force: Bool = false) {
    let key = "NSStatusItem Preferred Position \(name)"
    let saved = UserDefaults.standard.object(forKey: key) as? NSNumber
    let position = !force && saved?.doubleValue.isFinite == true && saved!.doubleValue >= 0
      ? saved!.doubleValue : fallback
    item.isVisible = false
    UserDefaults.standard.set(position, forKey: key)
    item.autosaveName = name
    item.isVisible = true
  }

  static func removePreservingPosition(_ item: NSStatusItem) {
    guard let name = item.autosaveName else {
      NSStatusBar.system.removeStatusItem(item)
      return
    }
    let key = "NSStatusItem Preferred Position \(name)"
    let position = UserDefaults.standard.object(forKey: key)
    NSStatusBar.system.removeStatusItem(item)
    if let position { UserDefaults.standard.set(position, forKey: key) }
  }

  private var initialBoundaryPosition: Double {
    let screen = launcher.button?.window?.screen ?? NSScreen.main
    let width = screen?.auxiliaryTopRightArea?.width ?? screen?.frame.width ?? 800
    return min(600, max(1, width - 64))
  }

  /// Establish our controls without asking the user to drag an offscreen item.
  /// Only TrayNook's own status items are repositioned here.
  func prepareLayout(keepingVisible: Set<String> = []) async throws {
    guard !isBusy else { throw MenuBarFailure(L("Another menu-bar action is in progress.")) }
    isBusy = true
    var token = generation
    var didReveal = false
    defer { isBusy = false }
    do {
      try await waitForIdleInput(token: token, checkingKeys: false)
      reveal()
      didReveal = true
      token = generation
      try await pause(0.25, token: token)
      if setupMessage != nil, let separator {
        Self.restorePosition(of: launcher, name: "TrayNookLauncher", fallback: 0, force: true)
        Self.restorePosition(of: separator, name: "TrayNook.HiddenBoundary", fallback: initialBoundaryPosition, force: true)
        try await pause(0.25, token: token)
      }
      let environment = try checkedEnvironment()
      let snapshot = try await freshInventory(token: token)
      // Items that stay visible: protected ones are never dragged, so they
      // must end up right of the separator here. Menu Bar items are only a
      // preference for the position; Apply drags any left behind to the right.
      let keptVisible = snapshot.items.compactMap { item -> (name: String, frame: ItemFrame, fixed: Bool)? in
        guard item.observation.processIdentifier != ProcessInfo.processInfo.processIdentifier,
          item.observation.isOnscreen != false,
          let frame = item.observation.frame, environment.safeFrame.contains(frame) else { return nil }
        let fixed = item.manageability.status == .protected || item.identity.persistentKey == nil
        guard fixed || keepingVisible.contains(item.identity.persistentKey ?? "") else { return nil }
        return (item.observation.applicationName ?? item.observation.bundleIdentifier ?? "?", frame, fixed)
      }
      if let leftmost = keptVisible.map(\.frame).min(by: { $0.minX < $1.minX }),
        leftmost.minX < environment.boundary.maxX, let separator {
        var position = environment.safeFrame.maxX - leftmost.minX + compactWidth / 2 + 16
        var blocking: [(name: String, frame: ItemFrame, fixed: Bool)] = []
        for _ in 0..<3 {
          Self.restorePosition(of: separator, name: "TrayNook.HiddenBoundary", fallback: position, force: true)
          try await pause(0.25, token: token)
          let positioned = try checkedEnvironment()
          blocking = keptVisible.filter { $0.fixed && $0.frame.minX < positioned.boundary.maxX - 1 }
          nativeLog.info("prepareLayout leftmost=\(String(describing: leftmost), privacy: .public) position=\(position, privacy: .public) boundary=\(String(describing: positioned.boundary), privacy: .public) kept=\(keptVisible.count) blocking=\(blocking.count)")
          if blocking.isEmpty { break }
          // In a crowded bar macOS can land the separator one slot right of
          // the requested position. Ask for a slot further left and retry.
          position += 24
        }
        guard blocking.isEmpty else {
          let names = Set(blocking.map(\.name)).sorted().joined(separator: ", ")
          throw MenuBarFailure(String(format: L("macOS could not place the separator to the left of %@. Command-drag them to the right of the │ separator."), names))
        }
      }
    } catch {
      if didReveal || (error as? NativeMenuActionError) != .inputNotIdle { reveal() }
      throw error
    }
  }

  /// nil means the item cannot safely be attributed to this menu-bar row.
  func isBehindBoundary(_ classified: ClassifiedSourceItem) -> Bool? {
    let item = classified.observation
    let key = classified.identity.persistentKey
    guard let environment = environment(), let frame = item.frame,
      Self.launcherIsSafe(environment.launcher, boundary: environment.boundary,
        safeFrame: environment.safeFrame, expanded: isConcealed)
    else { return nil }
    if Self.isClipped(item, boundary: environment.boundary, displayFrame: environment.displayFrame,
      occlusionFrame: environment.occlusionFrame) {
      if let key, concealedSourcePIDs[key] == item.processIdentifier { return true }
      if item.isOnscreen == false || environment.occlusionFrame?.contains(frame) == true { return false }
      // A partially covered, uncached source may still be visible. Its side
      // must be checked normally so an unassigned source cannot stay hidden.
    }
    if Self.outsideDisplay(frame, display: environment.displayFrame) {
      guard let key else { return false }
      return concealedSourcePIDs[key] == item.processIdentifier
    }
    guard let behind = Self.hiddenSide(frame, boundary: environment.boundary) else { return nil }
    if isConcealed && behind {
      guard let key, concealedSourcePIDs[key] == item.processIdentifier else { return nil }
    } else if !environment.safeFrame.contains(frame) {
      return nil
    }
    return behind
  }

  /// True only when the item is fully inside the safe status area, on the
  /// visible side of the boundary, onscreen, and not clipped. "Not behind the
  /// boundary" is weaker: an untrusted offscreen item is also not behind it.
  func isVerifiedVisible(_ classified: ClassifiedSourceItem) -> Bool {
    guard let environment = environment(),
      Self.launcherIsSafe(environment.launcher, boundary: environment.boundary,
        safeFrame: environment.safeFrame, expanded: isConcealed) else { return false }
    return Self.isVerifiedVisible(classified.observation, boundary: environment.boundary,
      safeFrame: environment.safeFrame, displayFrame: environment.displayFrame,
      occlusionFrame: environment.occlusionFrame)
  }

  static func isVerifiedVisible(_ item: RawSourceItemObservation, boundary: ItemFrame,
    safeFrame: ItemFrame, displayFrame: ItemFrame, occlusionFrame: ItemFrame? = nil) -> Bool {
    guard let frame = item.frame, item.isOnscreen != false,
      !isClipped(item, boundary: boundary, displayFrame: displayFrame, occlusionFrame: occlusionFrame)
    else { return false }
    return safeFrame.contains(frame) && hiddenSide(frame, boundary: boundary) == false
  }

  /// Reports sources whose pointer target is clipped by WindowServer or the
  /// camera cutout. Partial cutout overlap still needs assignment validation.
  func isClipped(_ item: RawSourceItemObservation) -> Bool {
    guard let environment = environment() else { return false }
    return Self.isClipped(item, boundary: environment.boundary, displayFrame: environment.displayFrame,
      occlusionFrame: environment.occlusionFrame)
  }

  func conceal(allowedKeys: Set<String>) async throws {
    guard !isBusy else { throw MenuBarFailure(L("Another menu-bar action is in progress.")) }
    isBusy = true
    reveal()
    let token = generation
    defer { isBusy = false }
    do {
      try await pause(0.25, token: token)
      try await waitForIdleInput(token: token, checkingKeys: false)
      let before = try checkedEnvironment()
      let snapshot = try await freshInventory(token: token)
      let items = snapshot.items.filter {
        $0.observation.processIdentifier != ProcessInfo.processInfo.processIdentifier
      }
      guard Self.canConceal(items, allowedKeys: allowedKeys,
        boundary: before.boundary, safeFrame: before.safeFrame, displayFrame: before.displayFrame,
        occlusionFrame: before.occlusionFrame) else {
        throw MenuBarFailure(L("A new, protected, or unassigned item is behind the separator. Keep it on the right before hiding."))
      }
      try requireIdleInput(checkingKeys: false)
      guard try checkedEnvironment() == before else {
        throw MenuBarFailure(L("The menu bar changed. Try hiding again."))
      }
      concealedSourcePIDs = Dictionary(items.compactMap { item in
        guard let key = item.identity.persistentKey, let bundle = item.observation.bundleIdentifier,
          let frame = item.observation.frame,
          allowedKeys.contains(key), !bundle.hasPrefix("com.apple."),
          item.manageability.status != .protected,
          Self.isClipped(item.observation, boundary: before.boundary, displayFrame: before.displayFrame,
            occlusionFrame: before.occlusionFrame)
            || (before.safeFrame.contains(frame) && Self.hiddenSide(frame, boundary: before.boundary) == true)
        else { return nil }
        return (key, item.observation.processIdentifier)
      }, uniquingKeysWith: { first, _ in first })
      // Hidden items must leave every menu bar, so grow to the widest display.
      let widestDisplay = NSScreen.screens.map { Double($0.frame.width) }.max() ?? before.displayWidth
      separator?.length = max(before.displayWidth, widestDisplay) + compactWidth
      nativeLog.info("conceal allowed=\(allowedKeys.count) sources=\(self.concealedSourcePIDs.count) displayWidth=\(before.displayWidth, privacy: .public) widest=\(widestDisplay, privacy: .public) screens=\(NSScreen.screens.map { Double($0.frame.width) }.description, privacy: .public) length=\(self.separator?.length ?? 0, privacy: .public)")
      isConcealed = true
      try await pause(0.25, token: token)
      guard let after = environment(), before.display == after.display,
        before.safeFrame == after.safeFrame,
        Self.launcherIsSafe(after.launcher, boundary: after.boundary,
          safeFrame: after.safeFrame, expanded: true),
        abs(after.launcher.x - before.launcher.x) <= 1,
        abs(after.boundary.maxX - before.boundary.maxX) <= 1
      else {
        throw MenuBarFailure(L("macOS could not hide this section while keeping TrayNook accessible. The section has been revealed."))
      }
      try requirePermission()
    } catch {
      reveal()
      throw error
    }
  }

  private struct StatusWindowBinding: Equatable {
    let id: UInt32
    let pid: Int32
    let bundle: String?
  }

  private struct PendingActivation {
    let source: ClassifiedSourceItem
    let sourceWindow: StatusWindowBinding
    let returnWindow: StatusWindowBinding
    let originalGap: Double
  }

  private var pendingActivation: PendingActivation?
  private var pendingReleasePID: Int32?
  private var activeEventRelay: TargetedMenuBarEventRelay?
  var hasPendingActivation: Bool { pendingActivation != nil }

  /// Promote just this source while the separator remains expanded. A return
  /// record is retained until its original neighbour is verified again.
  func prepareActivation(_ original: ClassifiedSourceItem) async throws -> ClassifiedSourceItem {
    guard !isBusy, pendingActivation == nil else {
      throw MenuBarFailure(L("Finish the current item interaction before opening another item."))
    }
    isBusy = true
    defer { isBusy = false }
    let token = generation
    var prepared = try await stableTarget(original, token: token,
      allowingClipped: true, allowingConcealed: true)
    if prepared.environment.safeFrame.contains(prepared.item.observation.frame!),
      prepared.item.observation.isOnscreen != false {
      return prepared.item
    }
    if !Self.physicalInputIsIdle(recentMovement: true) {
      try await waitForIdleInput(token: token)
      // An actual input wait can outlive the snapshot used for capacity checks.
      prepared = try await stableTarget(original, token: token,
        allowingClipped: true, allowingConcealed: true)
    }
    let source = prepared.item.observation
    let identity = prepared.item.identity
    let environment = prepared.environment
    let sourceFrame = source.frame!
    let sourceWindow = try statusWindow(for: source)
    let ownPID = ProcessInfo.processInfo.processIdentifier
    guard let launcherWindow = launcher.button?.window,
      let separatorWindow = separator?.button?.window else {
      throw MenuBarFailure(L("TrayNook's native controls are unavailable."))
    }
    let anchor = StatusWindowBinding(id: UInt32(launcherWindow.windowNumber), pid: ownPID,
      bundle: Bundle.main.bundleIdentifier)
    let boundaryBinding = StatusWindowBinding(id: UInt32(separatorWindow.windowNumber), pid: ownPID,
      bundle: Bundle.main.bundleIdentifier)
    let anchorFrame = try statusWindowFrame(anchor)
    let boundaryFrame = try statusWindowFrame(boundaryBinding)
    let sourceOuterFrame = try statusWindowFrame(sourceWindow)
    let width = sourceOuterFrame.width
    guard anchorFrame.minX - width >= environment.safeFrame.minX,
      environment.boundary.maxX - width >= environment.safeFrame.minX + 2,
      prepared.snapshot.items.allSatisfy({ item in
        guard item.observation.runtimeID != source.runtimeID,
          item.observation.isOnscreen != false, let frame = item.observation.frame,
          environment.safeFrame.contains(frame), frame.maxX <= environment.launcher.minX else { return true }
        return frame.minX - width >= environment.safeFrame.minX
      }) else {
      throw MenuBarFailure(L("There is not enough space to show this item safely beside TrayNook. Other hidden items remain hidden."))
    }
    var returnBinding: StatusWindowBinding?
    var returnFrame: ItemFrame?
    if boundaryFrame.minX > sourceOuterFrame.minX {
      returnBinding = boundaryBinding
      returnFrame = boundaryFrame
    }
    for item in prepared.snapshot.items {
      guard item.observation.runtimeID != source.runtimeID,
        let frame = item.observation.frame, frame.isUsable,
        frame.minX > sourceFrame.minX, frame.y < sourceFrame.maxY, frame.maxY > sourceFrame.y,
        returnFrame == nil || frame.minX < returnFrame!.minX else { continue }
      let binding = try statusWindow(for: item.observation)
      let outerFrame = try statusWindowFrame(binding)
      if outerFrame.minX > sourceOuterFrame.minX,
        returnFrame == nil || outerFrame.minX < returnFrame!.minX {
        returnBinding = binding
        returnFrame = outerFrame
      }
    }
    guard let returnBinding, let returnFrame else {
      throw MenuBarFailure(L("This item's original position cannot be restored safely. Other hidden items remain hidden."))
    }
    pendingActivation = PendingActivation(source: prepared.item, sourceWindow: sourceWindow,
      returnWindow: returnBinding, originalGap: returnFrame.minX - sourceOuterFrame.maxX)
    let windowBindings = statusWindows().map(\.binding).sorted { $0.id < $1.id }
    do {
      try await moveTargeted(source: sourceWindow, before: anchor,
        fallbackBefore: returnBinding, token: token)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
      while ContinuousClock.now < deadline {
        try checkOperation(token)
        let current = try checkedEnvironment(allowingExpanded: true)
        guard current.display == environment.display, current.displayFrame == environment.displayFrame,
          current.safeFrame == environment.safeFrame, current.occlusionFrame == environment.occlusionFrame,
          statusWindows().map(\.binding).sorted(by: { $0.id < $1.id }) == windowBindings else {
          throw MenuBarFailure(L("The item's native window changed. Other hidden items remain hidden."))
        }
        // Siblings of one app share the AX tree; the moved item is the one
        // overlapping its bound window's current frame. AX geometry can lag
        // WindowServer briefly, so no match yet just means "not yet".
        let windowFrame = try statusWindowFrame(sourceWindow)
        guard let (_, frame) = try? accessibilityTarget(source, token: token, expectedFrame: windowFrame)
        else {
          try await pause(0.02, token: token)
          continue
        }
        let moved = RawSourceItemObservation(runtimeID: source.runtimeID,
          processIdentifier: source.processIdentifier, bundleIdentifier: source.bundleIdentifier,
          applicationName: source.applicationName, role: source.role, subrole: source.subrole,
          frame: frame, actions: source.actions, metadata: source.metadata,
          observedOrder: source.observedOrder, isOnscreen: true,
          statusWindowIdentifier: source.statusWindowIdentifier)
        if current.safeFrame.contains(frame),
          let window = try? statusWindow(for: moved, requiringOnscreen: true), window.id == sourceWindow.id {
          return ClassifiedSourceItem(observation: moved, identity: identity,
            manageability: prepared.item.manageability)
        }
        try await pause(0.02, token: token)
      }
      throw MenuBarFailure(L("macOS could not show this item safely. Its return position is retained; other hidden items remain hidden."))
    } catch {
      releasePointer()
      throw error
    }
  }

  /// Deliver one action to the prepared, visible source. Never reveal the
  /// section and never retry an AX action with uncertain delivery.
  func activatePrepared(_ prepared: ClassifiedSourceItem, secondary: Bool) async throws {
    guard !isBusy else { throw MenuBarFailure(L("Another menu-bar action is in progress.")) }
    let original = prepared.observation
    if let pendingActivation {
      guard pendingActivation.source.observation.processIdentifier == original.processIdentifier,
        pendingActivation.source.identity.persistentKey == prepared.identity.persistentKey else {
        throw MenuBarFailure(L("Finish the current item interaction before opening another item."))
      }
    }
    isBusy = true
    defer { isBusy = false }
    let token = generation
    let useAX = Self.offersAccessibilityAction(original, secondary: secondary)
    try await waitForIdleInput(token: token, checkingPointer: !useAX)
    if useAX {
      try checkOperation(token)
      let environment = try checkedEnvironment(allowingExpanded: true)
      guard let bundle = original.bundleIdentifier, !bundle.hasPrefix("com.apple."),
        original.processIdentifier != ProcessInfo.processInfo.processIdentifier,
        let frame = original.frame, frame.isUsable, environment.safeFrame.contains(frame),
        original.isOnscreen != false else {
        throw MenuBarFailure(L("The selected item is not safely visible. Other hidden items remain hidden."))
      }
      let window = try statusWindow(for: original, requiringOnscreen: true)
      if let pendingActivation, window.id != pendingActivation.sourceWindow.id {
        throw MenuBarFailure(L("The item's native window changed. Other hidden items remain hidden."))
      }
      // Preparation already checked the full inventory. Rebind this exact AX
      // source, frame and action immediately before delivery instead of scanning
      // every other application twice again.
      try performAccessibilityAction(original, secondary: secondary, token: token)
      return
    }
    let stable = try await stableTarget(prepared, token: token, allowingConcealed: true)
    guard stable.environment.safeFrame.contains(stable.item.observation.frame!),
      stable.item.observation.isOnscreen != false else {
      throw MenuBarFailure(L("The selected item is not safely visible. Other hidden items remain hidden."))
    }
    try verifyHitTarget(stable.item.observation)
    let frame = stable.item.observation.frame!
    let point = CGPoint(x: frame.midX, y: frame.midY)
    try await post([(.mouseMoved, point, false),
      (secondary ? .rightMouseDown : .leftMouseDown, point, false),
      (secondary ? .rightMouseUp : .leftMouseUp, point, false)], secondary: secondary, token: token)
  }

  func restoreActivation() async throws {
    guard let pending = pendingActivation else { return }
    guard !isBusy else { throw MenuBarFailure(L("Another menu-bar action is in progress.")) }
    isBusy = true
    defer { isBusy = false }
    let token = generation
    _ = try await stableTarget(pending.source, token: token,
      allowingClipped: true, allowingConcealed: true)
    func restored() throws -> Bool {
      let source = try statusWindowFrame(pending.sourceWindow)
      let anchor = try statusWindowFrame(pending.returnWindow)
      return abs(anchor.minX - source.maxX - pending.originalGap) <= 2
        && source.minX < anchor.minX
    }
    if try !restored() {
      try await waitForIdleInput(token: token)
      try await moveTargeted(source: pending.sourceWindow, before: pending.returnWindow,
        fallbackBefore: pending.returnWindow, token: token)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
      while ContinuousClock.now < deadline {
        try checkOperation(token)
        if try restored() { break }
        try await pause(0.02, token: token)
      }
    }
    guard try restored() else {
      throw MenuBarFailure(L("The item could not return to its original position. Try restoring it again; other hidden items remain hidden."))
    }
    pendingActivation = nil
  }

  /// Runtime window identity and bounds for proxy capture. nil when the item's
  /// native window cannot be identified unambiguously.
  func statusWindowGeometry(for item: RawSourceItemObservation) -> (id: UInt32, frame: ItemFrame)? {
    guard let binding = try? statusWindow(for: item),
      let frame = try? statusWindowFrame(binding) else { return nil }
    return (binding.id, frame)
  }

  private func statusWindow(for item: RawSourceItemObservation,
    requiringOnscreen: Bool = false) throws -> StatusWindowBinding {
    guard let frame = item.frame, frame.isUsable else {
      throw MenuBarFailure(L("Item geometry is unavailable."))
    }
    // Status-level panels (DockDoor's preview spans the display) are not row windows.
    let matches = statusWindows().filter {
      $0.binding.pid == item.processIdentifier && $0.frame.height <= 2 * frame.height
        && $0.frame.x < frame.maxX && $0.frame.maxX > frame.x
        && $0.frame.y < frame.maxY && $0.frame.maxY > frame.y
    }
    guard matches.count == 1, let match = matches.first,
      match.binding.bundle == item.bundleIdentifier,
      !requiringOnscreen || match.isOnscreen else {
      nativeLog.info("no window for \(item.bundleIdentifier ?? "?", privacy: .public) frame=\(String(describing: frame), privacy: .public) matches=\(matches.map { String(describing: $0.frame) }.joined(separator: " "), privacy: .public)")
      throw MenuBarFailure(L("This item's native window cannot be identified safely. Other hidden items remain hidden."))
    }
    return match.binding
  }

  private func statusWindows() -> [(binding: StatusWindowBinding, frame: ItemFrame, isOnscreen: Bool)] {
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { window in
      guard (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
        let id = window[kCGWindowNumber as String] as? UInt32,
        let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
      let frame = ItemFrame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
      guard frame.isUsable else { return nil }
      return (StatusWindowBinding(id: id, pid: pid,
        bundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier), frame,
        window[kCGWindowIsOnscreen as String] as? Bool == true)
    }
  }

  private func statusWindowFrame(_ binding: StatusWindowBinding) throws -> ItemFrame {
    guard NSRunningApplication(processIdentifier: binding.pid)?.bundleIdentifier == binding.bundle,
      let window = statusWindows().first(where: { $0.binding.id == binding.id && $0.binding.pid == binding.pid }) else {
      throw MenuBarFailure(L("The item's native window changed. Other hidden items remain hidden."))
    }
    return window.frame
  }

  private func targetedEvent(_ type: NSEvent.EventType, at point: CGPoint,
    window: StatusWindowBinding, sourcePID: Int32) throws -> CGEvent {
    // NSEvent's public windowNumber constructor preserves the intended native
    // window during CGEvent conversion, including when that window is offscreen.
    guard let event = NSEvent.mouseEvent(with: type, location: point,
      modifierFlags: type == .leftMouseDown ? .command : [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(window.id),
      context: nil, eventNumber: 1, clickCount: 1,
      pressure: type == .leftMouseDown ? 1 : 0)?.cgEvent else {
      throw MenuBarFailure(L("macOS could not create a pointer event."))
    }
    event.location = point
    event.flags = type == .leftMouseDown ? [.maskCommand] : []
    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(sourcePID))
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
    return event
  }

  private func moveTargeted(source: StatusWindowBinding, before anchor: StatusWindowBinding,
    fallbackBefore fallback: StatusWindowBinding, token: Int) async throws {
    try checkOperation(token)
    try requireIdleInput()
    let original = try statusWindowFrame(source)
    let destination = try statusWindowFrame(anchor)
    let recovery = try statusWindowFrame(fallback)
    guard let pointer = CGEvent(source: nil)?.location else {
      throw MenuBarFailure(L("macOS could not create a pointer event."))
    }
    let downPoint = CGPoint(x: original.midX, y: original.midY)
    let endPoint = CGPoint(x: destination.minX, y: destination.midY)
    let down = try targetedEvent(.leftMouseDown, at: downPoint, window: source, sourcePID: source.pid)
    let up = try targetedEvent(.leftMouseUp, at: endPoint, window: anchor, sourcePID: source.pid)
    let recoveryUp = try targetedEvent(.leftMouseUp,
      at: CGPoint(x: recovery.minX, y: recovery.midY), window: fallback, sourcePID: source.pid)
    let display = environment()?.displayFrame
    func expectedPointer(at point: CGPoint) -> CGPoint {
      guard let display else { return point }
      return CGPoint(x: min(max(point.x, display.minX), display.maxX - 1),
        y: min(max(point.y, display.y), display.maxY - 1))
    }
    var lastPointer = pointer
    hideCursor()
    defer {
      releasePointer()
      if let current = CGEvent(source: nil)?.location, Self.near(current, lastPointer),
        Self.physicalInputIsIdle(recentMovement: false) { CGWarpMouseCursorPosition(pointer) }
      showCursor()
    }
    lastPointer = expectedPointer(at: downPoint)
    try await sendTargeted(down, pid: source.pid, onPosting: {
      guard token == self.generation, let current = CGEvent(source: nil)?.location,
        Self.near(current, pointer), Self.physicalInputIsIdle(recentMovement: false) else { return false }
      self.pendingRelease = recoveryUp
      self.pendingReleasePID = source.pid
      return true
    })
    // Stop borrowing the pointer while the source processes its down event.
    // Never return it over a newer user position.
    if let current = CGEvent(source: nil)?.location, Self.near(current, lastPointer),
      Self.physicalInputIsIdle(recentMovement: false) {
      CGWarpMouseCursorPosition(pointer)
      lastPointer = pointer
    }
    // ponytail: forwarding is not app processing; zero dwell loses reorders.
    // Keep the macOS 15-tested 50 ms until a processing acknowledgment exists.
    try await pause(0.05, token: token)
    guard let current = CGEvent(source: nil)?.location, Self.near(current, lastPointer) else {
      throw MenuBarFailure(L("Physical input interrupted the action. The selected item can be restored without revealing the section."))
    }
    try requireIdleInput(checkingPointer: false)
    lastPointer = expectedPointer(at: endPoint)
    try await sendTargeted(up, pid: source.pid, onPosting: {
      guard token == self.generation, let latest = CGEvent(source: nil)?.location,
        Self.near(latest, current), Self.physicalInputIsIdle(recentMovement: false) else { return false }
      return true
    }, onDelivered: {
      self.pendingRelease = nil
      self.pendingReleasePID = nil
    })
    try checkOperation(token)
  }

  private func sendTargeted(_ event: CGEvent, pid: Int32,
    onPosting: (() -> Bool)? = nil, onDelivered: (() -> Void)? = nil) async throws {
    let relay = TargetedMenuBarEventRelay(event: event, pid: pid,
      onPosting: onPosting, onDelivered: onDelivered)
    activeEventRelay = relay
    defer { if activeEventRelay === relay { activeEventRelay = nil } }
    try await relay.send()
  }

  func move(_ item: ClassifiedSourceItem, toHidden: Bool) async throws {
    try await interact(with: item, movingToHidden: toHidden, secondary: false)
  }

  func activate(_ item: ClassifiedSourceItem, secondary: Bool) async throws {
    let prepared = try await prepareActivation(item)
    try await activatePrepared(prepared, secondary: secondary)
  }

  /// Readiness is checked before preparation changes the visible menu bar.
  func waitForActivationReadiness(_ item: ClassifiedSourceItem, secondary: Bool) async throws {
    guard !isBusy else { throw MenuBarFailure(L("Another menu-bar action is in progress.")) }
    let token = generation
    try checkOperation(token)
    try await waitForIdleInput(token: token,
      checkingPointer: !Self.offersAccessibilityAction(item.observation, secondary: secondary))
    try checkOperation(token)
  }

  private static func offersAccessibilityAction(_ item: RawSourceItemObservation, secondary: Bool) -> Bool {
    item.actions.contains(secondary ? kAXShowMenuAction as String : kAXPressAction as String)
  }

  private func interact(
    with original: ClassifiedSourceItem, movingToHidden: Bool?, secondary: Bool
  ) async throws {
    guard !isBusy else { throw MenuBarFailure(L("Another menu-bar action is in progress.")) }
    isBusy = true
    var token = generation
    var didReveal = false
    let accessibilityAction = movingToHidden == nil
      && Self.offersAccessibilityAction(original.observation, secondary: secondary)
    defer { isBusy = false }
    do {
      try await waitForIdleInput(token: token, checkingPointer: !accessibilityAction)
      reveal()
      didReveal = true
      token = generation
      NSApp.deactivate()
      try await pause(0.25, token: token)
      let prepared = try await stableTarget(original, token: token, allowingClipped: movingToHidden == nil)
      let target = prepared.item
      let environment = prepared.environment
      let frame = target.observation.frame!
      nativeLog.info("interact \(original.identity.persistentKey ?? "?", privacy: .public) toHidden=\(String(describing: movingToHidden), privacy: .public) frame=\(String(describing: frame), privacy: .public) boundary=\(String(describing: environment.boundary), privacy: .public)")
      try requireIdleInput(checkingPointer: !accessibilityAction)
      if movingToHidden == nil && (accessibilityAction || Self.isClipped(target.observation,
        boundary: environment.boundary, displayFrame: environment.displayFrame,
        occlusionFrame: environment.occlusionFrame)) {
        try performAccessibilityAction(target.observation, secondary: secondary, token: token)
        return
      }
      try verifyHitTarget(target.observation)
      guard try checkedEnvironment() == environment else {
        throw MenuBarFailure(L("The menu bar changed before the action. Try again."))
      }
      let source = CGPoint(x: frame.midX, y: frame.midY)
      let events: [(CGEventType, CGPoint, Bool)]
      if let toHidden = movingToHidden {
        guard let alreadyHidden = Self.hiddenSide(frame, boundary: environment.boundary) else {
          throw MenuBarFailure(L("This item's position overlaps the separator. Move it manually first."))
        }
        if alreadyHidden == toHidden { return }
        if toHidden {
          let destination = CGPoint(x: environment.boundary.minX + 1, y: environment.boundary.midY)
          events = Self.dragEvents(from: source, to: destination)
        } else {
          let disposition = try SafeDefaultCorrectionPlanner().plan(
            target: target.identity.provisionalKey!, in: prepared.snapshot.items,
            boundaryFrame: environment.boundary, launcherFrame: environment.launcher,
            safeMenuBarFrame: environment.safeFrame)
          guard case .move(let plan) = disposition else { return }
          events = plan.events.map { event in
            let type: CGEventType
            switch event.kind {
            case .move: type = .mouseMoved
            case .leftMouseDown: type = .leftMouseDown
            case .leftMouseDragged: type = .leftMouseDragged
            case .leftMouseUp: type = .leftMouseUp
            }
            return (type, CGPoint(x: event.location.x, y: event.location.y), event.commandOnly)
          }
        }
      } else {
        events = [(.mouseMoved, source, false),
          (secondary ? .rightMouseDown : .leftMouseDown, source, false),
          (secondary ? .rightMouseUp : .leftMouseUp, source, false)]
      }
      try await post(events, secondary: secondary, token: token)
      nativeLog.info("posted \(events.count) events for \(original.identity.persistentKey ?? "?", privacy: .public)")
      if let toHidden = movingToHidden {
        try await pause(0.25, token: token)
        // In a crowded bar the hidden side is under the notch, so an item
        // dragged there is clipped. Clipped on the hidden side is success.
        let result = try await stableTarget(original, token: token, allowingClipped: toHidden)
        guard Self.hiddenSide(result.item.observation.frame!, boundary: result.environment.boundary) == toHidden else {
          throw MenuBarFailure(L("macOS did not move this item across the separator. Hold Command and drag it manually, then refresh."))
        }
      }
    } catch {
      if didReveal || (error as? NativeMenuActionError) != .inputNotIdle { reveal() }
      throw error
    }
  }

  private func stableTarget(_ original: ClassifiedSourceItem, token: Int, allowingClipped: Bool = false,
    allowingConcealed: Bool = false) async throws
    -> (item: ClassifiedSourceItem, environment: MenuBarEnvironment, snapshot: InventorySnapshot)
  {
    for _ in 0..<4 {
      let before = statusWindows().sorted { $0.binding.id < $1.binding.id }
      let beforeEnvironment = try checkedEnvironment(allowingExpanded: allowingConcealed)
      let snapshot = try await freshInventory(token: token)
      let environment = try checkedEnvironment(allowingExpanded: allowingConcealed)
      guard let bundle = original.observation.bundleIdentifier, !bundle.hasPrefix("com.apple."),
        let key = original.identity.persistentKey,
        original.observation.processIdentifier != ProcessInfo.processInfo.processIdentifier
      else { throw MenuBarFailure(L("System items and TrayNook's own items cannot be controlled.")) }
      let matches = snapshot.items.filter { $0.identity.persistentKey == key }
      guard matches.count == 1, let item = matches.first,
        item.observation.processIdentifier == original.observation.processIdentifier,
        item.observation.metadata.identifierCandidate == original.observation.metadata.identifierCandidate,
        item.identity.status != .ambiguous, item.identity.provisionalKey != nil,
        item.manageability.status != .protected,
        let frame = item.observation.frame, frame.isUsable,
        environment.safeFrame.contains(frame) || (allowingClipped && Self.isClipped(item.observation,
          boundary: environment.boundary, displayFrame: environment.displayFrame,
          occlusionFrame: environment.occlusionFrame))
          || (allowingConcealed && isConcealed && concealedSourcePIDs[key] == item.observation.processIdentifier
            && Self.hiddenSide(frame, boundary: environment.boundary) == true),
        frame.y < environment.boundary.maxY, frame.maxY > environment.boundary.y
      else {
        throw MenuBarFailure(L("This item is unavailable, ambiguous, or outside the visible menu bar. Reveal it manually and refresh."))
      }
      // One complete AX inventory, bracketed by fresh WindowServer observations.
      // Any window/process/geometry/visibility or display change invalidates it.
      // No inventory is cached across actions; AX identity is rebound at delivery.
      let after = statusWindows().sorted { $0.binding.id < $1.binding.id }
      if environment == beforeEnvironment, before.elementsEqual(after, by: {
        $0.binding == $1.binding && $0.frame == $1.frame && $0.isOnscreen == $1.isOnscreen
      }) {
        return (item, environment, snapshot)
      }
      try await pause(0.02, token: token)
    }
    throw MenuBarFailure(L("The menu bar is still changing. Try again when it has settled."))
  }

  /// A crowded source can remain clipped even after revealing the section.
  /// Rebind its native AX item and use only the action it explicitly offers.
  /// When the app owns several items, the one overlapping `expectedFrame`
  /// (the item's last known frame by default) is the target.
  private func accessibilityTarget(_ item: RawSourceItemObservation, token: Int,
    expectedFrame: ItemFrame? = nil) throws
    -> (element: AXUIElement, frame: ItemFrame) {
    let failure = MenuBarFailure(L("The clipped item's native Accessibility action is unavailable. Free menu-bar space and try again."))
    guard NSRunningApplication(processIdentifier: item.processIdentifier)?.bundleIdentifier == item.bundleIdentifier else {
      throw failure
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    func value(_ attribute: CFString, of element: AXUIElement, optional: Bool = false) throws -> CFTypeRef? {
      try checkOperation(token)
      guard ContinuousClock.now < deadline,
        AXUIElementSetMessagingTimeout(element, 0.2) == .success else { throw failure }
      var result: CFTypeRef?
      let error = AXUIElementCopyAttributeValue(element, attribute, &result)
      if optional && (error == .attributeUnsupported || error == .noValue) { return nil }
      guard error == .success else { throw failure }
      return result
    }
    let application = AXUIElementCreateApplication(item.processIdentifier)
    guard let extrasValue = try value(kAXExtrasMenuBarAttribute as CFString, of: application),
      CFGetTypeID(extrasValue) == AXUIElementGetTypeID() else { throw failure }
    let extras = unsafeDowncast(extrasValue, to: AXUIElement.self)
    var queue: [(AXUIElement, Int)] = [(extras, 0)]
    var candidates: [AXUIElement] = []
    var index = 0
    while index < queue.count {
      let (element, depth) = queue[index]
      index += 1
      if try value(kAXRoleAttribute as CFString, of: element) as? String == kAXMenuBarItemRole as String {
        candidates.append(element)
      }
      let childrenValue = try value(kAXChildrenAttribute as CFString, of: element, optional: true)
      guard childrenValue == nil || childrenValue as? [AXUIElement] != nil else { throw failure }
      for child in childrenValue as? [AXUIElement] ?? [] {
        if queue.contains(where: { CFEqual($0.0, child) }) { continue }
        guard depth < 5, queue.count < 128 else { throw failure }
        queue.append((child, depth + 1))
      }
    }
    func geometry(of target: AXUIElement) throws -> ItemFrame {
      guard let positionValue = try value(kAXPositionAttribute as CFString, of: target),
        let sizeValue = try value(kAXSizeAttribute as CFString, of: target),
        CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
      else { throw failure }
      let position = unsafeDowncast(positionValue, to: AXValue.self)
      let size = unsafeDowncast(sizeValue, to: AXValue.self)
      var point = CGPoint.zero
      var dimensions = CGSize.zero
      var pid: pid_t = 0
      guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
        AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions),
        AXUIElementGetPid(target, &pid) == .success, pid == item.processIdentifier
      else { throw failure }
      let frame = ItemFrame(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
      guard frame.isUsable else { throw failure }
      return frame
    }
    let matching = try candidates.filter { candidate in
      try value(kAXIdentifierAttribute as CFString, of: candidate, optional: true) as? String
        == item.metadata.identifierCandidate
    }
    if matching.count == 1, let target = matching.first {
      return (target, try geometry(of: target))
    }
    guard let expected = expectedFrame ?? item.frame, expected.isUsable else { throw failure }
    let located = try matching.map { ($0, try geometry(of: $0)) }.filter { _, frame in
      frame.x < expected.maxX && frame.maxX > expected.x && frame.y < expected.maxY && frame.maxY > expected.y
    }
    guard located.count == 1, let target = located.first else { throw failure }
    return target
  }

  private func performAccessibilityAction(_ item: RawSourceItemObservation, secondary: Bool, token: Int) throws {
    let failure = MenuBarFailure(L("The clipped item's native Accessibility action is unavailable. Free menu-bar space and try again."))
    let (target, frame) = try accessibilityTarget(item, token: token)
    guard frame == item.frame else { throw failure }
    var actionNames: CFArray?
    let action = secondary ? kAXShowMenuAction as String : kAXPressAction as String
    guard AXUIElementCopyActionNames(target, &actionNames) == .success,
      (actionNames as? [String])?.contains(action) == true else {
      throw MenuBarFailure(secondary
        ? L("This clipped item does not provide a native secondary action. Use Open, or free menu-bar space first.")
        : failure.localizedDescription)
    }
    try checkOperation(token)
    try requireIdleInput(checkingPointer: false)
    let result = AXUIElementPerformAction(target, action as CFString)
    if result == .cannotComplete { throw NativeMenuActionError.responseTimedOut }
    guard result == .success else { throw failure }
  }

  private func freshInventory(token: Int) async throws -> InventorySnapshot {
    try requirePermission()
    let snapshot = await Task.detached(priority: .userInitiated) {
      AccessibilityInventoryScanner().scan(promptForPermission: false)
    }.value
    try checkOperation(token)
    guard snapshot.permission == .granted, snapshot.completeness == .complete,
      Date().timeIntervalSince(snapshot.capturedAt) <= 3
    else { throw MenuBarFailure(L("A complete, fresh menu-bar inventory is unavailable. Refresh and try again.")) }
    noteInventory(snapshot)
    return snapshot
  }

  private func post(_ specifications: [(CGEventType, CGPoint, Bool)], secondary: Bool, token: Int) async throws {
    guard let eventSource = CGEventSource(stateID: .privateState),
      let originalPointer = CGEvent(source: nil)?.location
    else { throw MenuBarFailure(L("macOS could not create a pointer event.")) }
    eventSource.localEventsSuppressionInterval = 0
    let button: CGMouseButton = secondary ? .right : .left
    // Build every event before pressing a button, including the emergency release.
    let events = try specifications.map { type, point, command in
      guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
        mouseCursorPosition: point, mouseButton: button)
      else { throw MenuBarFailure(L("macOS could not create a pointer event.")) }
      event.flags = command ? [.maskCommand] : []
      event.setIntegerValueField(.mouseEventClickState, value: 1)
      return event
    }
    guard let release = CGEvent(mouseEventSource: eventSource,
      mouseType: secondary ? .rightMouseUp : .leftMouseUp,
      mouseCursorPosition: originalPointer, mouseButton: button)
    else { throw MenuBarFailure(L("macOS could not prepare the pointer release.")) }
    var lastPoint = originalPointer
    hideCursor()
    defer {
      releasePointer()
      if let current = CGEvent(source: nil)?.location,
        Self.near(current, lastPoint), Self.physicalInputIsIdle(recentMovement: false) {
        CGWarpMouseCursorPosition(originalPointer)
      }
      showCursor()
    }
    for event in events {
      try checkOperation(token)
      guard Self.physicalInputIsIdle(recentMovement: false),
        let current = CGEvent(source: nil)?.location, Self.near(current, lastPoint)
      else { throw MenuBarFailure(L("Physical input interrupted the action. The section remains revealed.")) }
      if event.type == .leftMouseDown || event.type == .rightMouseDown { pendingRelease = release }
      event.post(tap: .cgSessionEventTap)
      if event.type == .leftMouseUp || event.type == .rightMouseUp { pendingRelease = nil }
      lastPoint = event.location
      try await pause(0.025, token: token)
    }
  }

  private func releasePointer() {
    activeEventRelay?.cancel()
    activeEventRelay = nil
    guard let release = pendingRelease else { return }
    if let pid = pendingReleasePID {
      release.flags = []
      // End the session button state at the current pointer. The bound source
      // still receives its recovery destination; cancellation must not warp input.
      if let sessionRelease = release.copy(), let pointer = CGEvent(source: nil)?.location {
        sessionRelease.location = pointer
        sessionRelease.post(tap: .cgSessionEventTap)
      }
      release.postToPid(pid)
    } else {
      release.location = CGEvent(source: nil)?.location ?? release.location
      release.flags = []
      release.post(tap: .cgSessionEventTap)
    }
    pendingRelease = nil
    pendingReleasePID = nil
  }

  private func verifyHitTarget(_ item: RawSourceItemObservation) throws {
    guard let frame = item.frame else { throw MenuBarFailure(L("Item geometry is unavailable.")) }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.2)
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(frame.midX), Float(frame.midY), &element) == .success,
      let element
    else { throw MenuBarFailure(L("This item cannot be reached safely at its reported position.")) }
    var pid: pid_t = 0
    var role: CFTypeRef?
    guard AXUIElementGetPid(element, &pid) == .success, pid == item.processIdentifier,
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
      role as? String == kAXMenuBarItemRole as String
    else { throw MenuBarFailure(L("Another interface covers this item. Close menus or windows and try again.")) }
  }

  private func requirePermission() throws {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
      throw MenuBarFailure(L("Allow TrayNook in System Settings → Privacy & Security → Accessibility, then try again."))
    }
  }

  private func requireIdleInput(checkingKeys: Bool = true, checkingPointer: Bool = true) throws {
    guard Self.physicalInputIsIdle(recentMovement: checkingKeys && checkingPointer, checkingKeys: checkingKeys) else {
      throw NativeMenuActionError.inputNotIdle
    }
  }

  /// Waits at most one second for buttons, modifiers, and keys to be released.
  /// A long wait made the dropdown feel dead; a short one just reports it.
  private func waitForIdleInput(token: Int, checkingKeys: Bool = true, checkingPointer: Bool = true) async throws {
    for _ in 0..<10 {
      try checkOperation(token)
      if Self.physicalInputIsIdle(recentMovement: checkingKeys && checkingPointer, checkingKeys: checkingKeys) { return }
      try await pause(0.1, token: token)
    }
    try requireIdleInput(checkingKeys: checkingKeys, checkingPointer: checkingPointer)
  }

  private static func physicalInputIsIdle(recentMovement: Bool, checkingKeys: Bool = true) -> Bool {
    for button in [CGMouseButton.left, .right, .center] {
      if CGEventSource.buttonState(.hidSystemState, button: button) { return false }
    }
    let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    guard CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else { return false }
    if !checkingKeys { return true }
    for key in CGKeyCode(0)..<CGKeyCode(128) {
      if CGEventSource.keyState(.hidSystemState, key: key) { return false }
    }
    if recentMovement {
      // Physical motion between our down and up still corrupts the drag even
      // with the pointer hidden; keep the macOS 15-tested settle window.
      for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown] {
        if CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type) < 0.2 { return false }
      }
    }
    return true
  }

  private func checkOperation(_ token: Int) throws {
    try Task.checkCancellation()
    guard token == generation, separator != nil else { throw MenuBarFailure(L("The menu-bar action was cancelled. All items remain revealed.")) }
    try requirePermission()
  }

  private func pause(_ seconds: Double, token: Int) async throws {
    try await Task.sleep(for: .seconds(seconds))
    try checkOperation(token)
  }

  private func checkedEnvironment(allowingExpanded: Bool = false) throws -> MenuBarEnvironment {
    guard let environment = environment(),
      Self.launcherIsSafe(environment.launcher, boundary: environment.boundary,
        safeFrame: environment.safeFrame, expanded: allowingExpanded && isConcealed)
    else {
      if let environment = environment() {
        nativeLog.error("unsafe geometry launcher=\(String(describing: environment.launcher), privacy: .public) boundary=\(String(describing: environment.boundary), privacy: .public) safe=\(String(describing: environment.safeFrame), privacy: .public)")
      }
      throw MenuBarFailure(setupMessage ?? L("The menu-bar geometry is unavailable."))
    }
    return environment
  }

  /// Records which display the inventory's AX row is on. Items pushed behind
  /// the expanded separator lie outside every display, so onscreen items decide.
  func noteInventory(_ snapshot: InventorySnapshot) {
    let frames = snapshot.items.map(\.observation)
      .sorted { ($0.isOnscreen == true ? 0 : 1) < ($1.isOnscreen == true ? 0 : 1) }
      .compactMap(\.frame).filter(\.isUsable)
    guard let sample = frames.first else { return }
    let point = CGPoint(x: sample.midX, y: sample.midY)
    for screen in NSScreen.screens {
      guard let display = Self.displayID(of: screen), CGDisplayBounds(display).contains(point) else { continue }
      if activeDisplay != display { nativeLog.info("menu-bar row now on display \(display)") }
      activeDisplay = display
      return
    }
  }

  private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  /// AppKit shows each status item in one status window per display. Our
  /// button lives in the home display's window; on another display the
  /// mirror is the only other status window of ours with the same width.
  private static func mirroredButtonRect(of window: NSWindow, button: CGRect, on screen: NSScreen) -> CGRect? {
    let mirrors = NSApp.windows.filter {
      $0 !== window && $0.screen === screen && $0.isVisible
        && String(describing: type(of: $0)) == "NSStatusBarWindow"
        && abs($0.frame.width - window.frame.width) < 0.5
    }
    guard mirrors.count == 1, let mirror = mirrors.first else { return nil }
    return CGRect(x: mirror.frame.minX + (button.minX - window.frame.minX),
      y: mirror.frame.midY - button.height / 2, width: button.width, height: button.height)
  }

  private func environment() -> MenuBarEnvironment? {
    guard let boundaryButton = separator?.button, let boundaryWindow = boundaryButton.window,
      let launcherButton = launcher.button, let launcherWindow = launcherButton.window,
      let homeScreen = boundaryWindow.screen,
      launcherWindow.screen === homeScreen
    else { return nil }
    let screen = NSScreen.screens.first { Self.displayID(of: $0) == activeDisplay } ?? homeScreen
    guard let display = Self.displayID(of: screen) else { return nil }
    var launcherRect = launcherWindow.convertToScreen(launcherButton.convert(launcherButton.bounds, to: nil))
    var boundaryRect = boundaryWindow.convertToScreen(boundaryButton.convert(boundaryButton.bounds, to: nil))
    if screen !== homeScreen {
      guard let mirroredLauncher = Self.mirroredButtonRect(of: launcherWindow, button: launcherRect, on: screen),
        let mirroredBoundary = Self.mirroredButtonRect(of: boundaryWindow, button: boundaryRect, on: screen)
      else { return nil }
      launcherRect = mirroredLauncher
      boundaryRect = mirroredBoundary
    }
    let bounds = CGDisplayBounds(display)
    func converted(_ frame: CGRect) -> ItemFrame {
      ItemFrame(x: bounds.minX + frame.minX - screen.frame.minX,
        y: bounds.minY + screen.frame.maxY - frame.maxY,
        width: frame.width, height: frame.height)
    }
    let safe = screen.auxiliaryTopRightArea ?? CGRect(
      x: screen.frame.minX, y: screen.frame.maxY - NSStatusBar.system.thickness,
      width: screen.frame.width, height: NSStatusBar.system.thickness)
    let rawSafe = converted(safe)
    var occlusionFrame: ItemFrame?
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
      left.maxX < right.minX {
      let bottom = max(left.minY, right.minY)
      let top = min(left.maxY, right.maxY)
      if bottom < top {
        occlusionFrame = converted(CGRect(x: left.maxX, y: bottom,
          width: right.minX - left.maxX, height: top - bottom))
      }
    }
    return MenuBarEnvironment(display: display, displayWidth: bounds.width,
      displayFrame: ItemFrame(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
      safeFrame: ItemFrame(x: rawSafe.x, y: rawSafe.y - 1,
        width: rawSafe.width, height: rawSafe.height + 2),
      occlusionFrame: occlusionFrame,
      // Status windows include padding outside the usable menu-bar row on
      // current macOS. The actual button rect is the public clickable geometry.
      boundary: converted(boundaryRect),
      launcher: converted(launcherRect))
  }

  static func launcherIsSafe(_ launcher: ItemFrame, boundary: ItemFrame,
    safeFrame: ItemFrame, expanded: Bool) -> Bool {
    guard launcher.isUsable, boundary.isUsable, safeFrame.isUsable,
      safeFrame.contains(launcher), launcher.minX >= boundary.maxX - 1,
      boundary.y < launcher.maxY, boundary.maxY > launcher.y
    else { return false }
    let visibleBoundary = expanded
      ? ItemFrame(x: boundary.maxX - 2, y: boundary.y, width: 2, height: boundary.height)
      : boundary
    return safeFrame.contains(visibleBoundary)
  }

  static func hiddenSide(_ frame: ItemFrame, boundary: ItemFrame) -> Bool? {
    guard frame.isUsable, boundary.isUsable,
      frame.y < boundary.maxY, frame.maxY > boundary.y else { return nil }
    if frame.maxX <= boundary.minX + 1 { return true }
    if frame.minX >= boundary.maxX - 1 { return false }
    return nil
  }

  static func canConceal(_ items: [ClassifiedSourceItem],
    allowedKeys: Set<String>, boundary: ItemFrame, safeFrame: ItemFrame,
    displayFrame: ItemFrame? = nil, occlusionFrame: ItemFrame? = nil) -> Bool {
    items.allSatisfy { item in
      let clipped = displayFrame.map {
        isClipped(item.observation, boundary: boundary, displayFrame: $0, occlusionFrame: occlusionFrame)
      } ?? false
      if clipped, let frame = item.observation.frame,
        item.observation.isOnscreen == false || occlusionFrame?.contains(frame) == true {
        return true
      }
      if let frame = item.observation.frame, let displayFrame,
        outsideDisplay(frame, display: displayFrame) { return true }
      guard let frame = item.observation.frame,
        let behind = hiddenSide(frame, boundary: boundary),
        safeFrame.contains(frame) || (clipped && behind) else { return false }
      guard behind else { return true }
      guard let bundle = item.observation.bundleIdentifier, let key = item.identity.persistentKey,
        !bundle.hasPrefix("com.apple."), allowedKeys.contains(key),
        item.manageability.status != .protected
      else { return false }
      return true
    }
  }

  static func outsideDisplay(_ frame: ItemFrame, display: ItemFrame) -> Bool {
    frame.isUsable && display.isUsable && (frame.maxX <= display.minX || frame.minX >= display.maxX
      || frame.maxY <= display.y || frame.y >= display.maxY)
  }

  static func isClipped(_ item: RawSourceItemObservation, boundary: ItemFrame,
    displayFrame: ItemFrame, occlusionFrame: ItemFrame? = nil) -> Bool {
    guard let frame = item.frame,
      frame.isUsable, boundary.isUsable, displayFrame.isUsable,
      frame.y < boundary.maxY, frame.maxY > boundary.y,
      displayFrame.contains(frame)
    else { return false }
    if item.isOnscreen == false { return true }
    // WindowServer can report a window as onscreen while the physical camera
    // cutout covers all or part of its pointer target.
    guard let occlusionFrame, displayFrame.contains(occlusionFrame) else { return false }
    return frame.minX < occlusionFrame.maxX && frame.maxX > occlusionFrame.minX
      && frame.y < occlusionFrame.maxY && frame.maxY > occlusionFrame.y
  }

  private static func near(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
    abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
  }

  private static func dragEvents(from source: CGPoint, to destination: CGPoint) -> [(CGEventType, CGPoint, Bool)] {
    var result: [(CGEventType, CGPoint, Bool)] = [(.mouseMoved, source, false), (.leftMouseDown, source, true)]
    for step in 1...8 {
      let progress = Double(step) / 8
      result.append((.leftMouseDragged, CGPoint(x: source.x + (destination.x - source.x) * progress,
        y: source.y + (destination.y - source.y) * progress), true))
    }
    result.append((.leftMouseUp, destination, true))
    return result
  }

  @objc private func separatorClicked() { reveal(); onExternalReveal?() }
  @objc private func environmentChanged(_ notification: Notification) { reveal(); onExternalReveal?() }
}

/// Short-lived public event taps route only our tagged move events. Unrelated
/// physical events pass unchanged and are never recorded or suppressed.
@MainActor
private final class TargetedMenuBarEventRelay {
  let event: CGEvent
  let pid: Int32
  let tag = Int64.random(in: 1...Int64.max)
  private var processTap: CFMachPort?
  private var sessionTap: CFMachPort?
  private var delivered = false
  private var cancelled = false
  private let onPosting: (() -> Bool)?
  private let onDelivered: (() -> Void)?

  init(event: CGEvent, pid: Int32, onPosting: (() -> Bool)? = nil,
    onDelivered: (() -> Void)? = nil) {
    self.event = event
    self.pid = pid
    self.onPosting = onPosting
    self.onDelivered = onDelivered
  }

  func cancel() {
    cancelled = true
    if let processTap { CFMachPortInvalidate(processTap) }
    if let sessionTap { CFMachPortInvalidate(sessionTap) }
  }

  func send() async throws {
    try Task.checkCancellation()
    event.setIntegerValueField(.eventSourceUserData, value: tag)
    let context = Unmanaged.passUnretained(self).toOpaque()
    processTap = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap,
      options: .defaultTap, eventsOfInterest: 1, callback: { _, type, incoming, context in
        guard let context else { return Unmanaged.passUnretained(incoming) }
        let consumed = MainActor.assumeIsolated {
          let relay = Unmanaged<TargetedMenuBarEventRelay>.fromOpaque(context).takeUnretainedValue()
          guard !relay.cancelled, type == .null,
            incoming.getIntegerValueField(.eventSourceUserData) == relay.tag else { return false }
          if let tap = relay.processTap { CGEvent.tapEnable(tap: tap, enable: false) }
          guard relay.onPosting?() != false else { return true }
          relay.event.post(tap: .cgSessionEventTap)
          return true
        }
        return consumed ? nil : Unmanaged.passUnretained(incoming)
      }, userInfo: context)
    sessionTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
      options: .listenOnly, eventsOfInterest: 1 << event.type.rawValue, callback: { _, type, incoming, context in
        guard let context else { return Unmanaged.passUnretained(incoming) }
        MainActor.assumeIsolated {
          let relay = Unmanaged<TargetedMenuBarEventRelay>.fromOpaque(context).takeUnretainedValue()
          // WindowServer rewrites the routing PID at this tap. Match our tag
          // and window fields, then forward the stored event to the bound PID.
          guard !relay.cancelled, !relay.delivered, type == relay.event.type,
            incoming.getIntegerValueField(.eventSourceUserData) == relay.tag,
            incoming.getIntegerValueField(.mouseEventWindowUnderMousePointer)
              == relay.event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            incoming.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
              == relay.event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
          else { return }
          if let tap = relay.sessionTap { CGEvent.tapEnable(tap: tap, enable: false) }
          relay.event.postToPid(relay.pid)
          relay.delivered = true
          relay.onDelivered?()
        }
        return Unmanaged.passUnretained(incoming)
      }, userInfo: context)
    defer {
      if let processTap { CFMachPortInvalidate(processTap) }
      if let sessionTap { CFMachPortInvalidate(sessionTap) }
    }
    let failure = MenuBarFailure(L("macOS could not route this item's move. Other hidden items remain hidden."))
    guard let processTap, let sessionTap,
      let processSource = CFMachPortCreateRunLoopSource(nil, processTap, 0),
      let sessionSource = CFMachPortCreateRunLoopSource(nil, sessionTap, 0),
      let marker = CGEvent(source: nil) else { throw failure }
    CFRunLoopAddSource(CFRunLoopGetMain(), processSource, .commonModes)
    CFRunLoopAddSource(CFRunLoopGetMain(), sessionSource, .commonModes)
    defer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), processSource, .commonModes)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), sessionSource, .commonModes)
    }
    marker.type = .null
    marker.setIntegerValueField(.eventSourceUserData, value: tag)
    marker.postToPid(pid)
    for _ in 0..<25 {
      if delivered { return }
      guard !cancelled else { throw CancellationError() }
      try Task.checkCancellation()
      do { try await Task.sleep(for: .milliseconds(10)) }
      catch {
        if delivered { return }
        throw error
      }
    }
    throw failure
  }
}

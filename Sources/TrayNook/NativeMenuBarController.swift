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
  case inputInterrupted
  case placementInterrupted
  case inventoryUnavailable

  var errorDescription: String? {
    switch self {
    case .responseTimedOut:
      L("The native action did not confirm a response. Check the app before trying again.")
    case .inputNotIdle:
      L("Release the mouse and keyboard, stop moving the pointer, then try again.")
    case .inputInterrupted:
      L("Physical input interrupted the action. The selected item can be restored without revealing the section.")
    case .placementInterrupted:
      L("Physical input interrupted the action. The section remains revealed.")
    case .inventoryUnavailable:
      L("A complete, fresh menu-bar inventory is unavailable. Refresh and try again.")
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
  let boundaryWindowID: UInt32
  let launcherWindowID: UInt32
}

private struct MenuBarEnvironmentSeed: Equatable, Sendable {
  struct Screen: Equatable, Sendable {
    let display: UInt32
    let bounds: CGRect
    let row: CGRect
    let safeFrame: ItemFrame
    let occlusionFrame: ItemFrame?
  }
  struct Control: Equatable, Sendable {
    let id: UInt32
    let appKitFrame: CGRect
  }
  let generation: Int
  let inspectionRevision: Int
  let isConcealed: Bool
  let concealedSourcePIDs: [String: Int32]
  let activeDisplay: UInt32?
  let ownPID: Int32
  let screens: [Screen]
  let controls: [Control]
  let boundaryID: UInt32
  let launcherID: UInt32
  let boundarySize: CGSize
  let launcherSize: CGSize

  var windowIDs: [UInt32] { controls.map(\.id) }
}

/// The separator is a real status item. Its right edge separates the two native
/// sections; growing it pushes items on its left out of the menu bar.
@MainActor
final class NativeMenuBarController: NSObject {
  private let launcher: NSStatusItem
  private let metadataReader: WindowMetadataReader
  private var separator: NSStatusItem?
  // Two points keep the drag target and safety edge usable without an empty icon slot.
  private let compactWidth: CGFloat = 2
  private var generation = 0
  private var pendingRelease: CGEvent?
  /// Persistent identity key → process trusted to own that concealed item.
  private var concealedSourcePIDs: [String: Int32] = [:]
  private var cursorHidden = false
  private(set) var isConcealed = false
  /// The AX menu-bar row follows the display that holds the active app's key
  /// window, so geometry is computed for the display of the latest inventory.
  private var activeDisplay: CGDirectDisplayID?
  private var inspectionRevision = 0
  private(set) var isBusy = false {
    didSet {
      if isBusy && !oldValue {
        inspectionRevision += 1
        metadataReader.cancelAll()
      }
    }
  }
  var onReveal: (() -> Void)?
  var onExternalReveal: (() -> Void)?
  var onMenuBarRowChange: (() -> Void)?

  struct ItemInspection: Equatable {
    let behindBoundary: Bool?
    let isClipped: Bool
    let isVerifiedVisible: Bool
  }

  struct Inspection: Equatable {
    let setupMessage: String?
    let items: [String: ItemInspection]
  }

  var hasVisibleBoundary: Bool { separator?.isVisible == true }

  /// Polling and presentation share one geometry read; native actions still query afresh.
  func inspect(_ items: [ClassifiedSourceItem]) -> Inspection {
    inspect(items, in: environment())
  }

  /// Observational reads may wait off-main; input actions never consume this result.
  func inspectLatest(_ items: [ClassifiedSourceItem]) async -> Inspection? {
    guard !isBusy, !Task.isCancelled else { return nil }
    guard let seed = environmentSeed() else { return inspect(items, in: nil) }
    let sourceIDs = items.compactMap(\.observation.statusWindowIdentifier)
    let requestedIDs = Array(Set(seed.windowIDs + sourceIDs)).sorted()
    guard let windows = await metadataReader.read(requestedIDs), !Task.isCancelled,
      !isBusy, environmentSeed() == seed, Self.preservesWindowBindings(of: items, in: windows) else { return nil }
    return inspect(items, in: environment(seed: seed, metadata: windows))
  }

  static func preservesWindowBindings(of items: [ClassifiedSourceItem], in windows: [WindowMetadata]) -> Bool {
    let byID = Dictionary(grouping: windows, by: \.id)
    return items.allSatisfy { item in
      guard let id = item.observation.statusWindowIdentifier else { return true }
      guard let matches = byID[id], matches.count == 1 else { return false }
      return matches[0].pid == item.observation.processIdentifier
    }
  }

  private func inspect(_ items: [ClassifiedSourceItem], in environment: MenuBarEnvironment?) -> Inspection {
    let inspected = items.reduce(into: [String: ItemInspection]()) { result, item in
      result[item.observation.runtimeID] = ItemInspection(
        behindBoundary: isBehindBoundary(item, in: environment),
        isClipped: isClipped(item.observation, in: environment),
        isVerifiedVisible: isVerifiedVisible(item, in: environment))
    }
    return Inspection(setupMessage: setupMessage(in: environment), items: inspected)
  }

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

  init(launcher: NSStatusItem, metadataReader: WindowMetadataReader = WindowMetadataReader()) {
    self.launcher = launcher
    self.metadataReader = metadataReader
    super.init()
    let smokeTest = CommandLine.arguments.contains("--smoke-test")
    if !smokeTest {
      Self.restorePosition(of: launcher, name: "TrayNookLauncher", fallback: 0)
    }
    let separator = NSStatusBar.system.statusItem(withLength: compactWidth)
    separator.isVisible = false
    if !smokeTest {
      Self.restorePosition(of: separator, name: "TrayNook.HiddenBoundary", fallback: initialBoundaryPosition,
        visible: false)
    }
    // Allocate the boundary's native slot only while arranging or concealing items.
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
    setupMessage(in: environment())
  }

  private func setupMessage(in environment: MenuBarEnvironment?) -> String? {
    guard separator?.isVisible == true else { return nil }
    if let environment {
      let edge = ItemFrame(x: environment.boundary.maxX - 2, y: environment.boundary.y,
        width: 2, height: environment.boundary.height)
      if !environment.safeFrame.contains(environment.launcher) || !environment.safeFrame.contains(edge) {
        return L("There is not enough visible menu-bar space for TrayNook's controls. Temporarily quit a menu-bar app to free space, then choose Apply Saved Layout.")
      }
    }
    guard let environment,
      Self.launcherIsSafe(environment.launcher, boundary: environment.boundary,
        safeFrame: environment.safeFrame, expanded: isConcealed)
    else {
      return L("Choose Apply Saved Layout to position TrayNook's controls automatically. Keep the tray icon on the visible right side of the menu bar.")
    }
    return nil
  }

  func reveal(keepBoundaryVisible: Bool = false) {
    nativeLog.notice("reveal (was concealed: \(self.isConcealed))")
    generation += 1
    metadataReader.cancelAll()
    releasePointer()
    showCursor()
    separator?.length = compactWidth
    if let separator { Self.setVisiblePreservingPosition(separator, visible: keepBoundaryVisible) }
    isConcealed = false
    concealedSourcePIDs.removeAll()
    pendingActivation = nil
    onReveal?()
  }

  func screenParametersChanged() {
    generation += 1
    inspectionRevision += 1
    metadataReader.cancelAll()
    releasePointer()
    showCursor()
    activeDisplay = nil
    guard isConcealed, let separator else { return }
    let widths = NSScreen.screens.compactMap { Self.displayID(of: $0) }
      .map { CGDisplayBounds($0).width }
    // Keep the expanded length while mirrors are recreated, including on removal.
    separator.length = Self.concealmentLength(current: separator.length, displayWidths: widths)
  }

  static func concealmentLength(current: CGFloat, displayWidths: [CGFloat]) -> CGFloat {
    max(current, (displayWidths.filter { $0.isFinite && $0 > 0 }.max() ?? 0) + 2)
  }

  /// Packaged smoke uses only our controls and synthetic bindings, never native input.
  func verifyDisplayChangeBehavior(afterScreenChange: () -> Bool = { true }) -> Bool {
    guard !isBusy, !isConcealed, pendingActivation == nil, let separator else { return false }
    let previousLength = separator.length
    let previousVisibility = separator.isVisible
    let previousDisplay = activeDisplay
    let previousOwners = concealedSourcePIDs
    let previousOnReveal = onReveal
    defer {
      isBusy = false
      isConcealed = false
      pendingActivation = nil
      concealedSourcePIDs = previousOwners
      activeDisplay = previousDisplay
      separator.length = previousLength
      Self.setVisiblePreservingPosition(separator, visible: previousVisibility)
      onReveal = previousOnReveal
    }
    let pid = ProcessInfo.processInfo.processIdentifier
    let source = IdentityAssessor().classify([RawSourceItemObservation(runtimeID: "display-change-fixture",
      processIdentifier: pid, bundleIdentifier: "example.display-change", applicationName: "Display fixture",
      role: kAXMenuBarItemRole as String, frame: ItemFrame(x: 0, y: 0, width: 24, height: 24),
      actions: [kAXPressAction as String], metadata: LiveAccessibilityMetadata(), observedOrder: 0)])[0]
    let binding = StatusWindowBinding(id: 1, pid: pid, bundle: source.observation.bundleIdentifier)
    pendingActivation = PendingActivation(source: source, sourceWindow: binding, returnWindow: binding, originalGap: 0)
    concealedSourcePIDs = ["example.display-change": pid]
    separator.length = 6000
    Self.setVisiblePreservingPosition(separator, visible: true)
    isConcealed = true
    isBusy = true
    var revealed = false
    onReveal = { revealed = true }
    let token = generation
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    let preserved = !revealed && isConcealed && separator.isVisible && separator.length >= 6000
      && concealedSourcePIDs == ["example.display-change": pid] && pendingActivation?.sourceWindow == binding
      && pendingActivation?.returnWindow == binding && pendingActivation?.source == source && afterScreenChange()
    do { try checkOperation(token); return false }
    catch { return preserved && (error as? NativeMenuActionError) == .inventoryUnavailable }
  }

  /// A concealed source restarted. Trust its new process for the same identity
  /// so its proxy keeps working without reopening the whole section.
  func adoptProcess(key: String, pid: Int32) {
    guard isConcealed else { return }
    concealedSourcePIDs[key] = pid
  }

  func remove() {
    reveal()
    metadataReader.shutdown()
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    if let separator { Self.removePreservingPosition(separator) }
    separator = nil
  }

  /// AppKit restores this position when autosave visibility is attached. Keep
  /// the undocumented defaults key isolated to our own two status items.
  private static func restorePosition(of item: NSStatusItem, name: String, fallback: Double, force: Bool = false,
    visible: Bool = true) {
    let key = "NSStatusItem Preferred Position \(name)"
    let saved = UserDefaults.standard.object(forKey: key) as? NSNumber
    let position = !force && saved?.doubleValue.isFinite == true && saved!.doubleValue >= 0
      ? saved!.doubleValue : fallback
    item.isVisible = false
    UserDefaults.standard.set(position, forKey: key)
    item.autosaveName = name
    item.isVisible = visible
    UserDefaults.standard.set(position, forKey: key)
  }

  private static func setVisiblePreservingPosition(_ item: NSStatusItem, visible: Bool) {
    guard item.isVisible != visible else { return }
    guard let name = item.autosaveName else { item.isVisible = visible; return }
    let key = "NSStatusItem Preferred Position \(name)"
    let position = UserDefaults.standard.object(forKey: key)
    item.isVisible = visible
    if let position { UserDefaults.standard.set(position, forKey: key) }
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
      reveal(keepBoundaryVisible: true)
      didReveal = true
      token = generation
      try await pause(0.25, token: token)
      if setupMessage != nil, let separator {
        Self.restorePosition(of: launcher, name: "TrayNookLauncher", fallback: 0, force: true)
        Self.restorePosition(of: separator, name: "TrayNook.HiddenBoundary", fallback: initialBoundaryPosition, force: true)
        try await pause(0.25, token: token)
      }
      let snapshot = try await freshInventory(token: token)
      let environment = try checkedEnvironment()
      // Items that stay visible: protected ones are never dragged, so they
      // must end up right of the separator here. Menu Bar items are only a
      // preference for the position; Apply drags any left behind to the right.
      func keptVisible(_ snapshot: InventorySnapshot, _ environment: MenuBarEnvironment)
        -> [(name: String, frame: ItemFrame, fixed: Bool)] {
        snapshot.items.compactMap { item in
          guard item.observation.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            item.observation.isOnscreen != false,
            let frame = item.observation.frame, environment.safeFrame.contains(frame) else { return nil }
          let fixed = item.manageability.status == .protected || item.identity.persistentKey == nil
          guard fixed || keepingVisible.contains(item.identity.persistentKey ?? "") else { return nil }
          return (item.observation.applicationName ?? item.observation.bundleIdentifier ?? "?", frame, fixed)
        }
      }
      let kept = keptVisible(snapshot, environment)
      if let leftmost = kept.map(\.frame).min(by: { $0.minX < $1.minX }),
        leftmost.minX < environment.boundary.maxX, let separator {
        let firstPosition = environment.safeFrame.maxX - leftmost.minX + compactWidth / 2 + 16
        var position = firstPosition
        var blocking: [String] = []
        var placed = false
        for attempt in 0..<3 {
          Self.restorePosition(of: separator, name: "TrayNook.HiddenBoundary", fallback: position, force: true)
          try await pause(0.25, token: token)
          // Items shift when the separator is inserted; judge fresh frames.
          let positioned: MenuBarEnvironment
          do { positioned = try checkedEnvironment() }
          catch let error as NativeMenuActionError { throw error }
          catch {
            // Shifted off the safe area (under the notch): put it back and report.
            if attempt > 0 {
              Self.restorePosition(of: separator, name: "TrayNook.HiddenBoundary", fallback: firstPosition, force: true)
              try await pause(0.25, token: token)
            }
            break
          }
          let now = try await freshInventory(token: token)
          blocking = keptVisible(now, positioned)
            .filter { $0.fixed && $0.frame.minX < positioned.boundary.maxX - 1 }.map(\.name)
          nativeLog.notice("prepareLayout leftmost=\(String(describing: leftmost), privacy: .public) position=\(position, privacy: .public) boundary=\(String(describing: positioned.boundary), privacy: .public) kept=\(kept.count) blocking=\(blocking.count)")
          if blocking.isEmpty { placed = true; break }
          // A crowded bar can land the separator one slot right of the
          // requested position. Ask for a slot further left and retry.
          position += 24
        }
        guard placed else {
          let names = Set(blocking).sorted().joined(separator: ", ")
          throw MenuBarFailure(String(format: L("macOS could not keep %@ visible. Command-drag these items to the right of TrayNook's tray icon, then choose Apply Saved Layout."), names))
        }
      }
    } catch {
      if (token == generation || !isConcealed),
        didReveal || !isConcealed || (error as? NativeMenuActionError) != .inputNotIdle { reveal() }
      throw error
    }
  }

  /// nil means the item cannot safely be attributed to this menu-bar row.
  func isBehindBoundary(_ classified: ClassifiedSourceItem) -> Bool? {
    isBehindBoundary(classified, in: environment())
  }

  private func isBehindBoundary(_ classified: ClassifiedSourceItem,
    in environment: MenuBarEnvironment?) -> Bool? {
    if separator?.isVisible != true, !isConcealed { return false }
    let item = classified.observation
    let key = classified.identity.persistentKey
    guard let environment, let frame = item.frame,
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
    if !behind { return Self.visibleSideIsSafe(frame, safeFrame: environment.safeFrame) ? false : nil }
    if isConcealed {
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
    isVerifiedVisible(classified, in: environment())
  }

  private func isVerifiedVisible(_ classified: ClassifiedSourceItem,
    in environment: MenuBarEnvironment?) -> Bool {
    guard let environment,
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
    isClipped(item, in: environment())
  }

  private func isClipped(_ item: RawSourceItemObservation, in environment: MenuBarEnvironment?) -> Bool {
    if let environment {
      return Self.isClipped(item, boundary: environment.boundary, displayFrame: environment.displayFrame,
        occlusionFrame: environment.occlusionFrame)
    }
    guard !isConcealed, separator?.isVisible == false, let frame = item.frame, frame.isUsable,
      let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == activeDisplay })
        ?? launcher.button?.window?.screen,
      let display = Self.displayID(of: screen) else { return false }
    let bounds = CGDisplayBounds(display)
    let displayFrame = ItemFrame(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
    let cutout = Self.cameraOcclusion(left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea,
      screenFrame: screen.frame, displayBounds: bounds)
    // No window target is needed to read physical clipping while the boundary is absent.
    return Self.isClipped(item, boundary: frame, displayFrame: displayFrame, occlusionFrame: cutout)
  }

  func conceal(allowedKeys: Set<String>) async throws {
    guard !isBusy else { throw MenuBarFailure(L("Another menu-bar action is in progress.")) }
    isBusy = true
    reveal(keepBoundaryVisible: true)
    let token = generation
    defer { isBusy = false }
    do {
      try await pause(0.25, token: token)
      try await waitForIdleInput(token: token, checkingKeys: false)
      let snapshot = try await freshInventory(token: token)
      let before = try checkedEnvironment()
      let items = snapshot.items.filter {
        $0.observation.processIdentifier != ProcessInfo.processInfo.processIdentifier
      }
      guard Self.canConceal(items, allowedKeys: allowedKeys,
        boundary: before.boundary, safeFrame: before.safeFrame, displayFrame: before.displayFrame,
        occlusionFrame: before.occlusionFrame) else {
        for item in items where !Self.canConceal([item], allowedKeys: allowedKeys,
          boundary: before.boundary, safeFrame: before.safeFrame, displayFrame: before.displayFrame,
          occlusionFrame: before.occlusionFrame) {
          nativeLog.error("conceal blocked: \(item.identity.persistentKey ?? item.observation.runtimeID, privacy: .public) frame=\(String(describing: item.observation.frame), privacy: .public) onscreen=\(String(describing: item.observation.isOnscreen), privacy: .public) boundary=\(String(describing: before.boundary), privacy: .public)")
        }
        throw MenuBarFailure(L("A new, protected, or unassigned item would be hidden. Choose Apply Saved Layout to keep it visible before hiding."))
      }
      try requireIdleInput(checkingKeys: false)
      guard try checkedEnvironment() == before else {
        throw NativeMenuActionError.inventoryUnavailable
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
      let displayWidths = NSScreen.screens.compactMap { Self.displayID(of: $0) }
        .map { CGDisplayBounds($0).width }.filter { $0.isFinite && $0 > 0 }
      let widestDisplay = displayWidths.max() ?? CGFloat(before.displayWidth)
      separator?.length = Self.concealmentLength(current: CGFloat(before.displayWidth) + compactWidth,
        displayWidths: displayWidths)
      nativeLog.notice("conceal allowed=\(allowedKeys.count) sources=\(self.concealedSourcePIDs.count) displayWidth=\(before.displayWidth, privacy: .public) widest=\(widestDisplay, privacy: .public) screens=\(displayWidths.description, privacy: .public) length=\(self.separator?.length ?? 0, privacy: .public)")
      isConcealed = true
      try await pause(0.25, token: token)
      // Mirrored status windows can apply a length change on different run-loop turns.
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      var afterConcealment: MenuBarEnvironment?
      var settled = false
      repeat {
        try checkOperation(token)
        afterConcealment = environment()
        if let after = afterConcealment, before.display == after.display,
          before.safeFrame == after.safeFrame,
          Self.launcherIsSafe(after.launcher, boundary: after.boundary,
            safeFrame: after.safeFrame, expanded: true),
          abs(after.launcher.x - before.launcher.x) <= 1,
          abs(after.boundary.maxX - before.boundary.maxX) <= 1 {
          settled = true
          break
        }
        try await pause(0.02, token: token)
      } while ContinuousClock.now < deadline
      guard settled else {
        nativeLog.error("conceal geometry did not settle: boundary=\(String(describing: afterConcealment?.boundary), privacy: .public) launcher=\(String(describing: afterConcealment?.launcher), privacy: .public)")
        throw NativeMenuActionError.inventoryUnavailable
      }
      try requirePermission()
    } catch {
      if token == generation || !isConcealed { reveal() }
      throw error
    }
  }

  struct StatusWindowBinding: Equatable {
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
  var pendingActivationBundleIdentifier: String? { pendingActivation?.source.observation.bundleIdentifier }

  enum VisiblePlacement {
    case leftmost
    case before(ClassifiedSourceItem)
    case beforeLauncher
  }

  static func visiblePlacementAnchor(for placement: VisiblePlacement,
    in items: [ClassifiedSourceItem], excluding runtimeID: String,
    boundary: ItemFrame, safeFrame: ItemFrame, displayFrame: ItemFrame,
    occlusionFrame: ItemFrame? = nil) throws -> ClassifiedSourceItem? {
    switch placement {
    case .leftmost:
      return leftmostVisibleSource(in: items, excluding: runtimeID, boundary: boundary,
        safeFrame: safeFrame, displayFrame: displayFrame, occlusionFrame: occlusionFrame)
    case .beforeLauncher:
      return nil
    case .before(let original):
      let matches = items.filter { $0.identity.persistentKey == original.identity.persistentKey }
      guard original.identity.persistentKey != nil, matches.count == 1, let current = matches.first,
        current.observation.runtimeID != runtimeID,
        preservesSourceIdentity(original: original, current: current),
        let window = original.observation.statusWindowIdentifier,
        current.observation.statusWindowIdentifier == window,
        isVerifiedVisible(current.observation, boundary: boundary, safeFrame: safeFrame,
          displayFrame: displayFrame, occlusionFrame: occlusionFrame) else {
        throw MenuBarFailure(L("The menu-bar items changed or are not safely visible. Refresh, then retry their order."))
      }
      return current
    }
  }

  static func leftmostVisibleSource(in items: [ClassifiedSourceItem], excluding runtimeID: String,
    boundary: ItemFrame, safeFrame: ItemFrame, displayFrame: ItemFrame,
    occlusionFrame: ItemFrame? = nil) -> ClassifiedSourceItem? {
    items.filter {
      $0.observation.runtimeID != runtimeID
        && isVerifiedVisible($0.observation, boundary: boundary, safeFrame: safeFrame,
          displayFrame: displayFrame, occlusionFrame: occlusionFrame)
    }.min {
      let left = $0.observation.frame!.minX, right = $1.observation.frame!.minX
      return left == right ? $0.observation.runtimeID < $1.observation.runtimeID : left < right
    }
  }

  static func canShowWhileConcealed(sourceWidth: Double, anchor: ItemFrame,
    boundary: ItemFrame, safeFrame: ItemFrame) -> Bool {
    sourceWidth.isFinite && sourceWidth > 0 && anchor.isUsable && boundary.isUsable && safeFrame.isUsable
      && anchor.minX - sourceWidth >= safeFrame.minX
      && boundary.maxX - sourceWidth >= safeFrame.minX + 2
  }

  /// Hide only this source without collapsing the expanded boundary.
  func hideWhileConcealed(_ original: ClassifiedSourceItem) async throws -> ClassifiedSourceItem {
    guard !isBusy, pendingActivation == nil else {
      throw MenuBarFailure(L("Finish the current item interaction before opening another item."))
    }
    guard isConcealed else { throw NativeMenuActionError.placementInterrupted }
    isBusy = true
    defer { isBusy = false }
    let token = generation
    do {
      try await waitForIdleInput(token: token)
      let prepared = try await stableTarget(original, token: token,
        allowingClipped: true, allowingConcealed: true)
      if isBehindBoundary(prepared.item) == true { return prepared.item }
      let before = prepared.environment
      let source = prepared.item.observation
      guard isConcealed, let key = prepared.item.identity.persistentKey,
        Self.isVerifiedVisible(source, boundary: before.boundary, safeFrame: before.safeFrame,
          displayFrame: before.displayFrame, occlusionFrame: before.occlusionFrame) else {
        throw MenuBarFailure(L("The selected item is not safely visible. Other hidden items remain hidden."))
      }
      guard try checkedEnvironment(allowingExpanded: true) == before else {
        throw MenuBarFailure(L("The menu bar changed before the action. Try again."))
      }
      let sourceWindow = try statusWindow(for: source, requiringOnscreen: true)
      let ownPID = ProcessInfo.processInfo.processIdentifier
      let boundaryWindow = StatusWindowBinding(id: before.boundaryWindowID, pid: ownPID,
        bundle: Bundle.main.bundleIdentifier)
      let launcherWindow = StatusWindowBinding(id: before.launcherWindowID, pid: ownPID,
        bundle: Bundle.main.bundleIdentifier)
      try checkOperation(token)
      // Authorize the requested identity before delivery so a partial move remains recognized as hidden.
      concealedSourcePIDs[key] = source.processIdentifier
      try await moveTargeted(source: sourceWindow, before: boundaryWindow,
        fallbackBefore: launcherWindow, token: token)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
      while ContinuousClock.now < deadline {
        let verified = try await stableTarget(prepared.item, token: token,
          allowingClipped: true, allowingConcealed: true)
        let after = verified.environment
        guard isConcealed, after.display == before.display, after.displayFrame == before.displayFrame,
          after.safeFrame == before.safeFrame, after.occlusionFrame == before.occlusionFrame,
          after.boundaryWindowID == before.boundaryWindowID,
          after.launcherWindowID == before.launcherWindowID, after.boundary.width == before.boundary.width else {
          throw MenuBarFailure(L("The item's native window changed. Other hidden items remain hidden."))
        }
        let boundaryFrame = try statusWindowFrame(boundaryWindow)
        guard let moved = statusWindows().first(where: { $0.binding == sourceWindow }) else {
          throw MenuBarFailure(L("The item's native window changed. Other hidden items remain hidden."))
        }
        if !moved.isOnscreen, moved.frame.maxX <= boundaryFrame.minX + 2,
          moved.frame.y < boundaryFrame.maxY, moved.frame.maxY > boundaryFrame.y,
          (try? statusWindow(for: verified.item.observation)) == sourceWindow,
          isBehindBoundary(verified.item) == true {
          return verified.item
        }
        try await pause(0.02, token: token)
      }
      throw MenuBarFailure(L("macOS did not move this item to its saved section. Command-drag it to the right of the tray icon, then retry."))
    } catch {
      releasePointer()
      throw error
    }
  }

  /// Permanently show only this source, keeping the expanded separator and other hidden sources in place.
  func showWhileConcealed(_ original: ClassifiedSourceItem,
    placement: VisiblePlacement = .leftmost) async throws -> ClassifiedSourceItem {
    guard !isBusy, pendingActivation == nil else {
      throw MenuBarFailure(L("Finish the current item interaction before opening another item."))
    }
    guard isConcealed else { throw NativeMenuActionError.placementInterrupted }
    isBusy = true
    defer { isBusy = false }
    let token = generation
    do {
      try await waitForIdleInput(token: token)
      let prepared = try await stableTarget(original, token: token,
        allowingClipped: true, allowingConcealed: true)
      let before = prepared.environment
      let source = prepared.item.observation
      guard isConcealed, let key = prepared.item.identity.persistentKey else {
        throw NativeMenuActionError.placementInterrupted
      }
      let alreadyVisible = Self.isVerifiedVisible(source, boundary: before.boundary, safeFrame: before.safeFrame,
        displayFrame: before.displayFrame, occlusionFrame: before.occlusionFrame)
      if alreadyVisible, case .leftmost = placement {
        _ = try statusWindow(for: source, requiringOnscreen: true)
        concealedSourcePIDs.removeValue(forKey: key)
        return prepared.item
      }
      guard alreadyVisible || isBehindBoundary(prepared.item) == true else {
        throw MenuBarFailure(L("The selected item is not safely visible. Other hidden items remain hidden."))
      }
      let sourceWindow = try statusWindow(for: source)
      let ownPID = ProcessInfo.processInfo.processIdentifier
      let boundaryWindow = StatusWindowBinding(id: before.boundaryWindowID, pid: ownPID,
        bundle: Bundle.main.bundleIdentifier)
      let anchorItem = try Self.visiblePlacementAnchor(for: placement, in: prepared.snapshot.items,
        excluding: source.runtimeID, boundary: before.boundary, safeFrame: before.safeFrame,
        displayFrame: before.displayFrame, occlusionFrame: before.occlusionFrame)
      let anchor = try anchorItem.map { try statusWindow(for: $0.observation, requiringOnscreen: true) }
        ?? StatusWindowBinding(id: before.launcherWindowID, pid: ownPID, bundle: Bundle.main.bundleIdentifier)
      let anchorFrame = try statusWindowFrame(anchor)
      let sourceFrame = try statusWindowFrame(sourceWindow)
      guard alreadyVisible || Self.canShowWhileConcealed(sourceWidth: sourceFrame.width,
        anchor: anchorFrame, boundary: before.boundary, safeFrame: before.safeFrame) else {
        throw MenuBarFailure(L("There is not enough space to show this item safely beside TrayNook. Other hidden items remain hidden."))
      }
      let visible = prepared.snapshot.items.filter {
        $0.observation.runtimeID != source.runtimeID
          && Self.isVerifiedVisible($0.observation, boundary: before.boundary, safeFrame: before.safeFrame,
            displayFrame: before.displayFrame, occlusionFrame: before.occlusionFrame)
      }
      let anchorX = anchorItem?.observation.frame?.minX ?? before.launcher.minX
      let predecessor = try visible.filter { $0.observation.frame!.minX < anchorX }
        .max { $0.observation.frame!.minX < $1.observation.frame!.minX }
        .map { try statusWindow(for: $0.observation, requiringOnscreen: true) }
      let fallback: StatusWindowBinding
      if alreadyVisible {
        fallback = try visible.filter { $0.observation.frame!.minX > source.frame!.minX }
          .min { $0.observation.frame!.minX < $1.observation.frame!.minX }
          .map { try statusWindow(for: $0.observation, requiringOnscreen: true) }
          ?? StatusWindowBinding(id: before.launcherWindowID, pid: ownPID, bundle: Bundle.main.bundleIdentifier)
      } else { fallback = boundaryWindow }
      let windowBindings = statusWindows().map(\.binding).sorted { $0.id < $1.id }
      guard try checkedEnvironment(allowingExpanded: true) == before else {
        throw MenuBarFailure(L("The menu bar changed before the action. Try again."))
      }
      try await moveTargeted(source: sourceWindow, before: anchor,
        fallbackBefore: fallback, token: token)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
      while ContinuousClock.now < deadline {
        try checkOperation(token)
        let after = try checkedEnvironment(allowingExpanded: true)
        guard isConcealed, after.display == before.display, after.displayFrame == before.displayFrame,
          after.safeFrame == before.safeFrame, after.occlusionFrame == before.occlusionFrame,
          after.boundaryWindowID == before.boundaryWindowID,
          after.launcherWindowID == before.launcherWindowID, after.boundary.width == before.boundary.width,
          statusWindows().map(\.binding).sorted(by: { $0.id < $1.id }) == windowBindings else {
          throw MenuBarFailure(L("The item's native window changed. Other hidden items remain hidden."))
        }
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
          observedOrder: source.observedOrder, isOnscreen: true, statusWindowIdentifier: sourceWindow.id)
        if Self.isVerifiedVisible(moved, boundary: after.boundary, safeFrame: after.safeFrame,
          displayFrame: after.displayFrame, occlusionFrame: after.occlusionFrame),
          frame.maxX <= (try statusWindowFrame(anchor)).minX + 2,
          try predecessor.map({ frame.minX >= (try statusWindowFrame($0)).maxX - 2 }) ?? true,
          (try? statusWindow(for: moved, requiringOnscreen: true)) == sourceWindow {
          concealedSourcePIDs.removeValue(forKey: key)
          return ClassifiedSourceItem(observation: moved, identity: prepared.item.identity,
            manageability: prepared.item.manageability)
        }
        try await pause(0.02, token: token)
      }
      throw MenuBarFailure(L("macOS did not move this item to its saved section. Command-drag it to the right of the tray icon, then retry."))
    } catch {
      releasePointer()
      throw error
    }
  }

  /// Promote just this source while the separator remains expanded. A return
  /// record is retained until its original neighbour is verified again.
  func prepareActivation(_ original: ClassifiedSourceItem) async throws -> ClassifiedSourceItem {
    guard !isBusy, pendingActivation == nil else {
      throw MenuBarFailure(L("Finish the current item interaction before opening another item."))
    }
    isBusy = true
    var preparedForActivation = false
    defer {
      isBusy = false
      if !preparedForActivation && !isConcealed && pendingActivation == nil, let separator {
        Self.setVisiblePreservingPosition(separator, visible: false)
      }
    }
    let token = generation
    if let separator, !separator.isVisible {
      Self.setVisiblePreservingPosition(separator, visible: true)
      try await pause(0.25, token: token)
    }
    var prepared = try await stableTarget(original, token: token,
      allowingClipped: true, allowingConcealed: true)
    if prepared.environment.safeFrame.contains(prepared.item.observation.frame!),
      prepared.item.observation.isOnscreen != false {
      preparedForActivation = true
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
    let anchor = StatusWindowBinding(id: environment.launcherWindowID, pid: ownPID,
      bundle: Bundle.main.bundleIdentifier)
    let boundaryBinding = StatusWindowBinding(id: environment.boundaryWindowID, pid: ownPID,
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
          preparedForActivation = true
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
    defer {
      isBusy = false
      if !isConcealed && pendingActivation == nil, let separator {
        Self.setVisiblePreservingPosition(separator, visible: false)
      }
    }
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
    defer {
      isBusy = false
      if !isConcealed && pendingActivation == nil, let separator {
        Self.setVisiblePreservingPosition(separator, visible: false)
      }
    }
    let token = generation
    for attempt in 0..<3 {
      do {
        try checkOperation(token)
        let initialBindings = try restorationBindings()
        if !initialBindings.contains(where: { $0.id == pending.sourceWindow.id }) {
          pendingActivation = nil
          return
        }
        guard initialBindings.contains(pending.sourceWindow) else {
          throw NativeMenuActionError.inventoryUnavailable
        }
        let prepared = try await stableTarget(pending.source, token: token,
          allowingClipped: true, allowingConcealed: true)
        guard prepared.item.observation.statusWindowIdentifier == pending.sourceWindow.id,
          try statusWindow(for: prepared.item.observation) == pending.sourceWindow else {
          throw NativeMenuActionError.inventoryUnavailable
        }
        let boundary = isConcealed
          ? StatusWindowBinding(id: prepared.environment.boundaryWindowID,
            pid: ProcessInfo.processInfo.processIdentifier, bundle: Bundle.main.bundleIdentifier)
          : nil
        let bindings = try restorationBindings()
        let preferredIsHidden: Bool
        if isConcealed, pending.returnWindow != boundary, bindings.contains(pending.returnWindow) {
          preferredIsHidden = Self.hiddenSide(try statusWindowFrame(pending.returnWindow),
            boundary: prepared.environment.boundary) == true
        } else { preferredIsHidden = true }
        guard let anchor = try Self.restorationAnchor(source: pending.sourceWindow,
          preferred: pending.returnWindow, boundary: boundary, current: bindings,
          preferredIsHidden: preferredIsHidden) else {
          pendingActivation = nil
          return
        }
        let usingBoundary = anchor != pending.returnWindow
        func restored() throws -> Bool {
          let source = try statusWindowFrame(pending.sourceWindow)
          let destination = try statusWindowFrame(anchor)
          let boundary = isConcealed ? try checkedEnvironment(allowingExpanded: true).boundary : nil
          return Self.restorationVerified(source: source, destination: destination,
            boundary: boundary, originalGap: usingBoundary ? nil : pending.originalGap)
        }
        if try !restored() {
          try await waitForIdleInput(token: token)
          guard try checkedEnvironment(allowingExpanded: true) == prepared.environment else {
            throw NativeMenuActionError.inventoryUnavailable
          }
          try await moveTargeted(source: pending.sourceWindow, before: anchor,
            fallbackBefore: anchor, token: token)
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
        return
      } catch let error as NativeMenuActionError where [.inputNotIdle, .inputInterrupted].contains(error) {
        guard attempt < 2 else { throw error }
        // The click dismissing a menu can overlap its return; retry only the move.
        nativeLog.notice("return interrupted; waiting for idle input")
        try await pause(0.3, token: token)
      }
    }
  }

  static func restorationAnchor(source: StatusWindowBinding, preferred: StatusWindowBinding,
    boundary: StatusWindowBinding?, current: [StatusWindowBinding],
    preferredIsHidden: Bool = true) throws -> StatusWindowBinding? {
    let sources = current.filter { $0.id == source.id }
    guard !sources.isEmpty else { return nil }
    guard sources == [source] else { throw NativeMenuActionError.inventoryUnavailable }
    let preferredMatches = current.filter { $0.id == preferred.id }
    if !preferredMatches.isEmpty {
      guard preferredMatches == [preferred] else { throw NativeMenuActionError.inventoryUnavailable }
      if preferredIsHidden { return preferred }
    }
    guard let boundary, current.filter({ $0.id == boundary.id }) == [boundary] else {
      throw NativeMenuActionError.inventoryUnavailable
    }
    return boundary
  }

  static func restorationVerified(source: ItemFrame, destination: ItemFrame,
    boundary: ItemFrame?, originalGap: Double?) -> Bool {
    guard source.isUsable, destination.isUsable,
      source.y < destination.maxY, source.maxY > destination.y else { return false }
    if let boundary, hiddenSide(source, boundary: boundary) != true { return false }
    if let originalGap {
      return abs(destination.minX - source.maxX - originalGap) <= 2
        && source.minX < destination.minX
    }
    return source.maxX <= destination.minX + 2
  }

  static func retrySelectedReturn(isPending: () -> Bool,
    restore: () async throws -> Void,
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
    while isPending() {
      try Task.checkCancellation()
      do {
        try await restore()
        try Task.checkCancellation()
        guard !isPending() else { throw NativeMenuActionError.inventoryUnavailable }
      } catch where shouldRetrySelectedReturn(after: error) {
        try await sleep(.seconds(3))
      }
    }
  }

  static func shouldRetrySelectedReturn(after error: Error) -> Bool {
    guard let error = error as? NativeMenuActionError else { return false }
    return [.inventoryUnavailable, .inputNotIdle, .inputInterrupted, .placementInterrupted].contains(error)
  }

  private func restorationBindings() throws -> [StatusWindowBinding] {
    guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
      throw NativeMenuActionError.inventoryUnavailable
    }
    return try windows.compactMap { window in
      guard let layer = window[kCGWindowLayer as String] as? Int else {
        throw NativeMenuActionError.inventoryUnavailable
      }
      guard layer == Int(CGWindowLevelForKey(.statusWindow)) else { return nil }
      guard let id = window[kCGWindowNumber as String] as? UInt32,
        let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
        throw NativeMenuActionError.inventoryUnavailable
      }
      return StatusWindowBinding(id: id, pid: pid,
        bundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }
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
    var matches = statusWindows().filter {
      $0.binding.pid == item.processIdentifier && $0.frame.height <= 2 * frame.height
        && $0.frame.x < frame.maxX && $0.frame.maxX > frame.x
        && $0.frame.y < frame.maxY && $0.frame.maxY > frame.y
    }
    // Some apps keep a stale offscreen duplicate at the same spot after a
    // display change; the onscreen window is the one the user sees.
    if matches.count > 1 { matches = matches.filter(\.isOnscreen) }
    guard matches.count == 1, let match = matches.first,
      match.binding.bundle == item.bundleIdentifier,
      !requiringOnscreen || match.isOnscreen else {
      nativeLog.notice("no window for \(item.bundleIdentifier ?? "?", privacy: .public) frame=\(String(describing: frame), privacy: .public) matches=\(matches.map { String(describing: $0.frame) }.joined(separator: " "), privacy: .public)")
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
      throw NativeMenuActionError.inventoryUnavailable
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
      throw NativeMenuActionError.inputInterrupted
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

  /// Reorder visible sources without revealing or moving anything in the hidden section.
  func reorderMenuBarItems(_ ordered: [ClassifiedSourceItem]) async throws {
    guard ordered.count > 1 else { return }
    guard !isBusy, pendingActivation == nil else {
      throw MenuBarFailure(L("Finish the current item interaction before changing item order."))
    }
    var failure: MenuBarFailure {
      MenuBarFailure(L("The menu-bar items changed or are not safely visible. Refresh, then retry their order."))
    }
    let keys = ordered.compactMap(\.identity.persistentKey)
    guard keys.count == ordered.count, Set(keys).count == keys.count,
      ordered.allSatisfy({ item in
        guard let bundle = item.observation.bundleIdentifier else { return false }
        return !bundle.hasPrefix("com.apple.") && bundle != Bundle.main.bundleIdentifier
          && item.observation.processIdentifier != ProcessInfo.processInfo.processIdentifier
          && item.identity.status != .ambiguous && item.identity.provisionalKey != nil
          && item.manageability.status != .protected
      }) else { throw failure }
    let wasConcealed = isConcealed
    let boundaryWasVisible = separator?.isVisible == true
    defer {
      if !boundaryWasVisible && !isConcealed, let separator {
        Self.setVisiblePreservingPosition(separator, visible: false)
      }
    }
    if !wasConcealed && !boundaryWasVisible { try await prepareLayout(keepingVisible: Set(keys)) }
    isBusy = true
    defer { releasePointer(); isBusy = false }
    let token = generation
    try await waitForIdleInput(token: token)

    func readOrder() async throws
      -> (items: [ClassifiedSourceItem], visible: [ClassifiedSourceItem], environment: MenuBarEnvironment) {
      for _ in 0..<4 {
        let beforeEnvironment = try checkedEnvironment(allowingExpanded: true)
        let beforeWindows = stableStatusWindows(in: beforeEnvironment).sorted { $0.binding.id < $1.binding.id }
        let snapshot = try await freshInventory(token: token)
        let environment = try checkedEnvironment(allowingExpanded: true)
        let afterWindows = stableStatusWindows(in: environment).sorted { $0.binding.id < $1.binding.id }
        guard environment == beforeEnvironment, beforeWindows.elementsEqual(afterWindows, by: {
          $0.binding == $1.binding && $0.frame == $1.frame && $0.isOnscreen == $1.isOnscreen
        }) else { try await pause(0.02, token: token); continue }
        let current = try ordered.map { original in
          let matches = snapshot.items.filter { $0.identity.persistentKey == original.identity.persistentKey }
          guard matches.count == 1, let item = matches.first,
            Self.preservesSourceIdentity(original: original, current: item),
            item.observation.bundleIdentifier == original.observation.bundleIdentifier,
            item.identity.status != .ambiguous, item.identity.provisionalKey != nil,
            item.manageability.status != .protected else { throw failure }
          _ = try statusWindow(for: item.observation)
          return item
        }
        guard let visibleKeys = Self.visibleMenuBarOrderKeys(current, boundary: environment.boundary,
          safeFrame: environment.safeFrame, displayFrame: environment.displayFrame,
          occlusionFrame: environment.occlusionFrame) else { throw failure }
        let visible = current.filter { visibleKeys.contains($0.identity.persistentKey!) }
          .sorted { $0.observation.frame!.minX < $1.observation.frame!.minX }
        for item in visible { _ = try statusWindow(for: item.observation, requiringOnscreen: true) }
        return (current, visible, environment)
      }
      throw NativeMenuActionError.inventoryUnavailable
    }

    var current = try await readOrder()
    let visibleKeys = Set(current.visible.compactMap(\.identity.persistentKey))
    let desired = keys.filter { visibleKeys.contains($0) }
    guard desired.count > 1 else { return }
    let before = current.environment
    let bindings = try Dictionary(uniqueKeysWithValues: current.items.map {
      ($0.identity.persistentKey!, try statusWindow(for: $0.observation))
    })
    let windowBindings = stableStatusWindows(in: current.environment).map(\.binding).sorted { $0.id < $1.id }
    func requireUnchangedRow(_ environment: MenuBarEnvironment) throws {
      guard isConcealed == wasConcealed, environment.display == before.display,
        environment.displayFrame == before.displayFrame, environment.safeFrame == before.safeFrame,
        environment.occlusionFrame == before.occlusionFrame, environment.boundary == before.boundary,
        environment.boundaryWindowID == before.boundaryWindowID,
        environment.launcherWindowID == before.launcherWindowID,
        Set(current.visible.compactMap(\.identity.persistentKey)) == visibleKeys,
        stableStatusWindows(in: environment).map(\.binding).sorted(by: { $0.id < $1.id }) == windowBindings else { throw failure }
      for item in current.items {
        guard try statusWindow(for: item.observation,
          requiringOnscreen: visibleKeys.contains(item.identity.persistentKey!))
          == bindings[item.identity.persistentKey!] else { throw failure }
      }
    }

    for _ in 0..<desired.count {
      let currentKeys = current.visible.compactMap(\.identity.persistentKey)
      if currentKeys == desired { return }
      guard let move = Self.nextMenuBarOrderMove(desired: desired, current: currentKeys),
        let source = bindings[move.source], let anchor = bindings[move.anchor] else { throw failure }
      try checkOperation(token)
      try requireUnchangedRow(checkedEnvironment(allowingExpanded: true))
      var expected = currentKeys.filter { $0 != move.source }
      guard let index = expected.firstIndex(of: move.anchor) else { throw failure }
      expected.insert(move.source, at: index)
      try await moveTargeted(source: source, before: anchor, fallbackBefore: anchor, token: token)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
      var verified = false
      repeat {
        current = try await readOrder()
        try requireUnchangedRow(current.environment)
        if current.visible.compactMap(\.identity.persistentKey) == expected {
          verified = true
          break
        }
        try await pause(0.02, token: token)
      } while ContinuousClock.now < deadline
      guard verified else {
        throw MenuBarFailure(L("macOS did not accept the saved item order. Keep the pointer still, then retry."))
      }
    }
    throw failure
  }

  /// Leave conclusively clipped sources in place; incomplete geometry is never an omission.
  static func visibleMenuBarOrderKeys(_ items: [ClassifiedSourceItem], boundary: ItemFrame,
    safeFrame: ItemFrame, displayFrame: ItemFrame, occlusionFrame: ItemFrame? = nil) -> Set<String>? {
    var visible = Set<String>()
    for item in items {
      guard let key = item.identity.persistentKey, let frame = item.observation.frame, frame.isUsable,
        frame.y < boundary.maxY, frame.maxY > boundary.y else { return nil }
      if Self.isVerifiedVisible(item.observation, boundary: boundary, safeFrame: safeFrame,
        displayFrame: displayFrame, occlusionFrame: occlusionFrame) {
        visible.insert(key)
      } else if !Self.isClipped(item.observation, boundary: boundary,
        displayFrame: displayFrame, occlusionFrame: occlusionFrame)
        && !(item.observation.isOnscreen == false && Self.outsideDisplay(frame, display: displayFrame)) {
        return nil
      }
    }
    return visible
  }

  /// Inserting at the first mismatch preserves the relative order of unrelated sources.
  static func nextMenuBarOrderMove(desired: [String], current: [String]) -> (source: String, anchor: String)? {
    guard desired.count == current.count, Set(desired).count == desired.count,
      Set(current) == Set(desired), let index = desired.indices.first(where: { desired[$0] != current[$0] })
    else { return nil }
    return (desired[index], current[index])
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
      reveal(keepBoundaryVisible: true)
      didReveal = true
      token = generation
      if movingToHidden == nil { NSApp.deactivate() }
      try await pause(0.25, token: token)
      let prepared = try await stableTarget(original, token: token, allowingClipped: movingToHidden == nil)
      let target = prepared.item
      let environment = prepared.environment
      let frame = target.observation.frame!
      nativeLog.notice("interact \(original.identity.persistentKey ?? "?", privacy: .public) toHidden=\(String(describing: movingToHidden), privacy: .public) frame=\(String(describing: frame), privacy: .public) boundary=\(String(describing: environment.boundary), privacy: .public)")
      try requireIdleInput(checkingPointer: !accessibilityAction)
      if movingToHidden == nil && (accessibilityAction || Self.isClipped(target.observation,
        boundary: environment.boundary, displayFrame: environment.displayFrame,
        occlusionFrame: environment.occlusionFrame)) {
        try performAccessibilityAction(target.observation, secondary: secondary, token: token)
        return
      }
      // Window-addressed placement verifies its exact PID/window instead of the pointer hit target.
      if movingToHidden != true { try verifyHitTarget(target.observation) }
      guard try checkedEnvironment() == environment else {
        throw MenuBarFailure(L("The menu bar changed before the action. Try again."))
      }
      let source = CGPoint(x: frame.midX, y: frame.midY)
      let events: [(CGEventType, CGPoint, Bool)]?
      if let toHidden = movingToHidden {
        let alreadyHidden = try Self.checkedHiddenSide(frame, boundary: environment.boundary)
        if alreadyHidden == toHidden { return }
        if toHidden {
          let sourceWindow = try statusWindow(for: target.observation, requiringOnscreen: true)
          let ownPID = ProcessInfo.processInfo.processIdentifier
          let boundaryWindow = StatusWindowBinding(id: environment.boundaryWindowID, pid: ownPID,
            bundle: Bundle.main.bundleIdentifier)
          let launcherWindow = StatusWindowBinding(id: environment.launcherWindowID, pid: ownPID,
            bundle: Bundle.main.bundleIdentifier)
          // Address the native window directly; the invisible boundary is too narrow for pointer hit-testing.
          try await moveTargeted(source: sourceWindow, before: boundaryWindow,
            fallbackBefore: launcherWindow, token: token)
          events = nil
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
      if let events {
        try await post(events, secondary: secondary, token: token)
        nativeLog.notice("posted \(events.count) events for \(original.identity.persistentKey ?? "?", privacy: .public)")
      }
      if let toHidden = movingToHidden {
        try await pause(0.25, token: token)
        // In a crowded bar the hidden side is under the notch, so an item
        // dragged there is clipped. Clipped on the hidden side is success.
        let result = try await stableTarget(original, token: token, allowingClipped: toHidden)
        guard Self.hiddenSide(result.item.observation.frame!, boundary: result.environment.boundary) == toHidden else {
          throw MenuBarFailure(L("macOS did not move this item to its saved section. Command-drag it to the right of the tray icon, then retry."))
        }
      }
    } catch {
      if (token == generation || !isConcealed),
        didReveal || !isConcealed || (error as? NativeMenuActionError) != .inputNotIdle { reveal() }
      throw error
    }
  }

  private func stableTarget(_ original: ClassifiedSourceItem, token: Int, allowingClipped: Bool = false,
    allowingConcealed: Bool = false) async throws
    -> (item: ClassifiedSourceItem, environment: MenuBarEnvironment, snapshot: InventorySnapshot)
  {
    for _ in 0..<4 {
      let beforeEnvironment = try checkedEnvironment(allowingExpanded: allowingConcealed)
      let before = stableStatusWindows(in: beforeEnvironment).sorted { $0.binding.id < $1.binding.id }
      let snapshot = try await freshInventory(token: token)
      let environment = try checkedEnvironment(allowingExpanded: allowingConcealed)
      guard let bundle = original.observation.bundleIdentifier, !bundle.hasPrefix("com.apple."),
        let key = original.identity.persistentKey,
        original.observation.processIdentifier != ProcessInfo.processInfo.processIdentifier
      else { throw MenuBarFailure(L("System items and TrayNook's own items cannot be controlled.")) }
      let matches = snapshot.items.filter { $0.identity.persistentKey == key }
      guard matches.count == 1, let item = matches.first,
        Self.preservesSourceIdentity(original: original, current: item),
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
      // Any source-row window/process/geometry/visibility or display change invalidates it.
      // No inventory is cached across actions; AX identity is rebound at delivery.
      let after = stableStatusWindows(in: environment).sorted { $0.binding.id < $1.binding.id }
      if environment == beforeEnvironment, before.elementsEqual(after, by: {
        $0.binding == $1.binding && $0.frame == $1.frame && $0.isOnscreen == $1.isOnscreen
      }) {
        return (item, environment, snapshot)
      }
      try await pause(0.02, token: token)
    }
    throw NativeMenuActionError.inventoryUnavailable
  }

  private func stableStatusWindows(in environment: MenuBarEnvironment)
    -> [(binding: StatusWindowBinding, frame: ItemFrame, isOnscreen: Bool)] {
    statusWindows().filter { Self.isStatusWindowOnRow($0.frame, row: environment.safeFrame) }
  }

  static func isStatusWindowOnRow(_ frame: ItemFrame, row: ItemFrame) -> Bool {
    // Unknown geometry remains relevant; only conclusively unrelated panels are omitted.
    guard frame.isUsable, row.isUsable else { return true }
    return frame.height <= 2 * row.height && frame.y < row.maxY && frame.maxY > row.y
  }

  /// Ranked sibling keys can be reassigned when one window disappears. A
  /// stale proxy must not activate the sibling that inherited its old rank.
  static func preservesSourceIdentity(original: ClassifiedSourceItem, current: ClassifiedSourceItem) -> Bool {
    guard let key = original.identity.persistentKey, current.identity.persistentKey == key,
      current.observation.processIdentifier == original.observation.processIdentifier,
      current.observation.metadata.identifierCandidate == original.observation.metadata.identifierCandidate
    else { return false }
    guard key.contains("#w") else { return true }
    guard let originalWindow = original.observation.statusWindowIdentifier else { return false }
    return current.observation.statusWindowIdentifier == originalWindow
  }

  /// A crowded source can remain clipped even after revealing the section.
  /// Rebind its native AX item and use only the action it explicitly offers.
  /// When the app owns several items, the one overlapping `expectedFrame`
  /// (the item's last known frame by default) is the target.
  private func accessibilityTarget(_ item: RawSourceItemObservation, token: Int,
    expectedFrame: ItemFrame? = nil) throws
    -> (element: AXUIElement, frame: ItemFrame) {
    // Built only when thrown: constructing a failure logs it.
    var failure: MenuBarFailure { MenuBarFailure(L("The clipped item's native Accessibility action is unavailable. Free menu-bar space and try again.")) }
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
    // Built only when thrown: constructing a failure logs it.
    var failure: MenuBarFailure { MenuBarFailure(L("The clipped item's native Accessibility action is unavailable. Free menu-bar space and try again.")) }
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
    guard snapshot.permission == .granted else {
      throw MenuBarFailure(L("Allow TrayNook in System Settings → Privacy & Security → Accessibility, then try again."))
    }
    guard snapshot.completeness == .complete,
      Date().timeIntervalSince(snapshot.capturedAt) <= 3
    else { throw NativeMenuActionError.inventoryUnavailable }
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
      else { throw NativeMenuActionError.placementInterrupted }
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
    guard token == generation, separator != nil else { throw NativeMenuActionError.inventoryUnavailable }
    try requirePermission()
  }

  private func pause(_ seconds: Double, token: Int) async throws {
    try await Task.sleep(for: .seconds(seconds))
    try checkOperation(token)
  }

  private func checkedEnvironment(allowingExpanded: Bool = false) throws -> MenuBarEnvironment {
    guard let environment = environment() else { throw NativeMenuActionError.inventoryUnavailable }
    guard Self.launcherIsSafe(environment.launcher, boundary: environment.boundary,
        safeFrame: environment.safeFrame, expanded: allowingExpanded && isConcealed)
    else {
      nativeLog.error("unsafe geometry launcher=\(String(describing: environment.launcher), privacy: .public) boundary=\(String(describing: environment.boundary), privacy: .public) safe=\(String(describing: environment.safeFrame), privacy: .public)")
      throw MenuBarFailure(setupMessage ?? L("The menu-bar geometry is unavailable."))
    }
    return environment
  }

  /// Records which display the inventory's AX row is on. Items pushed behind
  /// the expanded separator lie outside every display, so onscreen items decide.
  @discardableResult
  func noteInventory(_ snapshot: InventorySnapshot) -> Bool {
    let screens = NSScreen.screens.compactMap { screen -> (id: UInt32, bounds: CGRect)? in
      guard let id = Self.displayID(of: screen) else { return nil }
      return (id, CGDisplayBounds(id))
    }
    guard let display = Self.inventoryDisplay(for: snapshot.items.map(\.observation), screens: screens)
    else { return false }
    let changed = activeDisplay != nil && activeDisplay != display
    if activeDisplay != display { nativeLog.notice("menu-bar row now on display \(display)") }
    if changed { screenParametersChanged() }
    activeDisplay = display
    if changed { onMenuBarRowChange?() }
    return changed
  }

  static func inventoryDisplay(for observations: [RawSourceItemObservation],
    screens: [(id: UInt32, bounds: CGRect)]) -> UInt32? {
    let frames = observations.filter { $0.role == kAXMenuBarItemRole as String && $0.isOnscreen == true }
      .compactMap(\.frame).filter(\.isUsable)
    let displays = frames.compactMap { frame -> UInt32? in
      let point = CGPoint(x: frame.midX, y: frame.midY)
      let matches = screens.filter { $0.bounds.contains(point) }
      return matches.count == 1 ? matches[0].id : nil
    }
    guard displays.count == frames.count, let display = displays.first,
      displays.allSatisfy({ $0 == display }) else { return nil }
    return display
  }

  private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  struct ControlWindow {
    let id: UInt32
    let display: UInt32
    let frame: CGRect
    let isVisible: Bool
  }

  /// An expanded status window stretches left of its display; its right edge stays in the menu bar.
  static func controlDisplay(for frame: CGRect, menuBarRows: [(display: UInt32, frame: CGRect)]) -> UInt32? {
    guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { return nil }
    let matches = menuBarRows.filter { row in
      frame.maxX >= row.frame.minX && frame.maxX <= row.frame.maxX
        && frame.midY >= row.frame.minY && frame.midY <= row.frame.maxY
    }
    return matches.count == 1 ? matches.first?.display : nil
  }

  /// AppKit can retain compact frames while WindowServer has already expanded the status item.
  static func controlButtonFrame(in window: CGRect, width: CGFloat, height: CGFloat) -> CGRect? {
    guard window.minX.isFinite, window.minY.isFinite, window.width.isFinite, window.height.isFinite,
      width.isFinite, height.isFinite, width > 0, height > 0,
      window.width >= width, window.height > 0 else { return nil }
    let height = min(height, window.height)
    return CGRect(x: window.midX - width / 2, y: window.midY - height / 2,
      width: width, height: height)
  }

  /// Keep the window identity and button rect together: targeted moves must
  /// use the same display's control that was used for safe-area validation.
  /// Expanded separators can report offscreen while their recovery edge remains visible.
  static func controlGeometry(home: ControlWindow, button: CGRect, on display: UInt32,
    statusWindows: [ControlWindow], allowingOffscreen: Bool = false) -> (windowID: UInt32, button: CGRect)? {
    if home.display == display {
      guard home.isVisible || allowingOffscreen else { return nil }
      return (home.id, button)
    }
    let mirrors = statusWindows.filter {
      $0.id != home.id && $0.display == display && ($0.isVisible || allowingOffscreen)
        && abs($0.frame.width - home.frame.width) < 0.5
    }
    guard mirrors.count == 1, let mirror = mirrors.first else { return nil }
    // A 24 pt external bar is shorter than the home bar's button; clamp.
    let height = min(button.height, mirror.frame.height)
    return (mirror.id, CGRect(x: mirror.frame.minX + (button.minX - home.frame.minX),
      y: mirror.frame.midY - height / 2, width: button.width, height: height))
  }

  private func environment() -> MenuBarEnvironment? {
    guard let seed = environmentSeed() else { return nil }
    return environment(seed: seed, metadata: WindowMetadata.read(ids: seed.windowIDs))
  }

  private func environmentSeed() -> MenuBarEnvironmentSeed? {
    guard let separator, separator.isVisible,
      let boundaryButton = separator.button, let boundaryWindow = boundaryButton.window,
      let launcherButton = launcher.button, let launcherWindow = launcherButton.window,
      let boundaryID = UInt32(exactly: boundaryWindow.windowNumber),
      let launcherID = UInt32(exactly: launcherWindow.windowNumber)
    else { return nil }
    let screens = NSScreen.screens.compactMap { screen -> MenuBarEnvironmentSeed.Screen? in
      guard let display = Self.displayID(of: screen) else { return nil }
      let bounds = CGDisplayBounds(display)
      let height = screen.auxiliaryTopRightArea?.height ?? NSStatusBar.system.thickness
      guard bounds.width > 0, height > 0 else { return nil }
      let safe = screen.auxiliaryTopRightArea ?? CGRect(
        x: screen.frame.minX, y: screen.frame.maxY - NSStatusBar.system.thickness,
        width: screen.frame.width, height: NSStatusBar.system.thickness)
      let safeFrame = ItemFrame(x: bounds.minX + safe.minX - screen.frame.minX,
        y: bounds.minY + screen.frame.maxY - safe.maxY, width: safe.width, height: safe.height)
      return MenuBarEnvironmentSeed.Screen(display: display, bounds: bounds,
        row: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height),
        safeFrame: safeFrame, occlusionFrame: Self.cameraOcclusion(left: screen.auxiliaryTopLeftArea,
          right: screen.auxiliaryTopRightArea, screenFrame: screen.frame, displayBounds: bounds))
    }
    let controls = NSApp.windows.compactMap { window -> MenuBarEnvironmentSeed.Control? in
      guard String(describing: type(of: window)) == "NSStatusBarWindow",
        let id = UInt32(exactly: window.windowNumber) else { return nil }
      return MenuBarEnvironmentSeed.Control(id: id, appKitFrame: window.frame)
    }.sorted { $0.id < $1.id }
    return MenuBarEnvironmentSeed(generation: generation, inspectionRevision: inspectionRevision, isConcealed: isConcealed,
      concealedSourcePIDs: concealedSourcePIDs, activeDisplay: activeDisplay,
      ownPID: ProcessInfo.processInfo.processIdentifier, screens: screens, controls: controls,
      boundaryID: boundaryID, launcherID: launcherID,
      boundarySize: CGSize(width: separator.length, height: boundaryButton.bounds.height),
      launcherSize: launcherButton.bounds.size)
  }

  private func environment(seed: MenuBarEnvironmentSeed, metadata: [WindowMetadata]) -> MenuBarEnvironment? {
    let rows = seed.screens.map { (display: $0.display, frame: $0.row) }
    let statusWindowIDs = Set(seed.windowIDs)
    let windows = metadata.compactMap { window -> ControlWindow? in
      guard window.pid == seed.ownPID, statusWindowIDs.contains(window.id),
        let display = Self.controlDisplay(for: window.frame, menuBarRows: rows) else { return nil }
      return ControlWindow(id: window.id, display: display, frame: window.frame, isVisible: window.isVisible)
    }
    guard let boundaryHome = windows.first(where: { $0.id == seed.boundaryID }),
      let launcherHome = windows.first(where: { $0.id == seed.launcherID }),
      let target = seed.screens.first(where: { $0.display == seed.activeDisplay })
        ?? seed.screens.first(where: { $0.display == launcherHome.display }),
      let boundaryFrame = Self.controlButtonFrame(in: boundaryHome.frame,
        width: seed.boundarySize.width, height: seed.boundarySize.height),
      let launcherFrame = Self.controlButtonFrame(in: launcherHome.frame,
        width: seed.launcherSize.width, height: seed.launcherSize.height)
    else { return nil }
    let display = target.display
    guard let launcherGeometry = Self.controlGeometry(home: launcherHome, button: launcherFrame,
      on: display, statusWindows: windows),
      let boundaryGeometry = Self.controlGeometry(home: boundaryHome, button: boundaryFrame,
        on: display, statusWindows: windows, allowingOffscreen: seed.isConcealed),
      let rowWindow = windows.first(where: { $0.id == launcherGeometry.windowID }) else {
      nativeLog.error("no unambiguous mirrored controls on display \(display)")
      return nil
    }
    let bounds = target.bounds
    return MenuBarEnvironment(display: display, displayWidth: bounds.width,
      displayFrame: ItemFrame(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
      safeFrame: Self.menuBarSafeFrame(horizontalArea: target.safeFrame, controlWindow: rowWindow.frame),
      occlusionFrame: target.occlusionFrame,
      boundary: ItemFrame(x: boundaryGeometry.button.minX, y: boundaryGeometry.button.minY,
        width: boundaryGeometry.button.width, height: boundaryGeometry.button.height),
      launcher: ItemFrame(x: launcherGeometry.button.minX, y: launcherGeometry.button.minY,
        width: launcherGeometry.button.width, height: launcherGeometry.button.height),
      boundaryWindowID: boundaryGeometry.windowID,
      launcherWindowID: launcherGeometry.windowID)
  }

  static func cameraOcclusion(left: CGRect?, right: CGRect?, screenFrame: CGRect,
    displayBounds: CGRect) -> ItemFrame? {
    guard let left, let right, left.maxX < right.minX else { return nil }
    let bottom = max(left.minY, right.minY)
    let top = min(left.maxY, right.maxY)
    guard bottom < top else { return nil }
    return ItemFrame(x: displayBounds.minX + left.maxX - screenFrame.minX,
      y: displayBounds.minY + screenFrame.maxY - top,
      width: right.minX - left.maxX, height: top - bottom)
  }

  static func menuBarSafeFrame(horizontalArea: ItemFrame, controlWindow: CGRect) -> ItemFrame {
    // The global status-bar thickness and auxiliary notch area can both be
    // shorter than this row's actual controls. Keep the notch's horizontal
    // limits, but measure the vertical band from the bound native window.
    ItemFrame(x: horizontalArea.x, y: controlWindow.minY - 1,
      width: horizontalArea.width, height: controlWindow.height + 2)
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

  static func checkedHiddenSide(_ frame: ItemFrame, boundary: ItemFrame) throws -> Bool {
    guard let behind = hiddenSide(frame, boundary: boundary) else {
      // Unknown geometry must retain recovery without authorizing a native move.
      throw NativeMenuActionError.inventoryUnavailable
    }
    return behind
  }

  static func visibleSideIsSafe(_ frame: ItemFrame, safeFrame: ItemFrame) -> Bool {
    // Concealment grows left; a right-side system window may extend past the screen edge.
    frame.isUsable && safeFrame.isUsable
      && frame.minX >= safeFrame.minX && frame.minX < safeFrame.maxX
      && frame.y >= safeFrame.y && frame.maxY <= safeFrame.maxY
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
        let behind = hiddenSide(frame, boundary: boundary) else { return false }
      guard behind else { return visibleSideIsSafe(frame, safeFrame: safeFrame) }
      guard safeFrame.contains(frame) || clipped else { return false }
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

  @objc private func separatorClicked() { reveal(); onExternalReveal?() }
  @objc private func environmentChanged(_ notification: Notification) {
    if notification.name == NSApplication.didChangeScreenParametersNotification {
      screenParametersChanged()
    } else { reveal() }
  }
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
  private var postingRejected = false
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
          guard relay.onPosting?() != false else { relay.postingRejected = true; return true }
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
    // Built only when thrown: constructing a failure logs it.
    var failure: MenuBarFailure { MenuBarFailure(L("macOS could not route this item's move. Other hidden items remain hidden.")) }
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
      if postingRejected { throw NativeMenuActionError.inputInterrupted }
      do { try await Task.sleep(for: .milliseconds(10)) }
      catch {
        if delivered { return }
        throw error
      }
    }
    throw failure
  }
}

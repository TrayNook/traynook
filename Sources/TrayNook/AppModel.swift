import AppKit
import ApplicationServices
import Combine
import InventoryIdentityCore
import ServiceManagement
import os

let modelLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.mahenzon.TrayNook", category: "model")

@MainActor
final class AppModel: ObservableObject {
  @Published var layout = SavedLayout()
  @Published var items: [ClassifiedSourceItem] = []
  @Published var permissionGranted = false
  @Published var scanComplete = false
  @Published var scanning = false
  @Published var busy = false
  @Published var concealed = false
  @Published var message: String?
  @Published var recoveryRequired = false
  private var incompleteScans = 0
  private var unsafeScans = 0
  @Published var selectedTab = 0
  @Published var loginEnabled = SMAppService.mainApp.status == .enabled
  @Published var screenRecordingGranted = ProxyImageCapture.isAuthorized
  /// Keyed by persistent identity. Session-only cache of each dropdown item's
  /// last onscreen capture; cleared when Screen Recording is unavailable.
  @Published var proxyImages: [String: ProxyImage] = [:]
  let native: NativeMenuBarController
  let undoManager = UndoManager()
  var closeDropdown: (() -> Void)?
  var showSettings: (() -> Void)?
  private let store: LayoutStore?
  private var scanTask: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var scanGeneration = 0
  private var attemptedLaunchRestore = false
  private var launchRestoreRunning = false
  private var panelWatch: Task<Void, Never>?
  /// True while the dropdown is open; a promoted item waits until it closes.
  var dropdownShown = false

  func dropdownClosed() {
    dropdownShown = false
    guard native.hasPendingActivation, !busy else { return }
    modelLog.notice("dropdown closed; returning the promoted item")
    runOperation(restoreSettingsFocus: false, revealOnFailure: false) {
      try await self.native.restoreActivation()
      self.message = nil
    }
  }
  /// A tray click that arrived while an operation ran; honored when it ends.
  private var queuedDropdown: (@MainActor () -> Void)?
  private var hasAcceptedSnapshot = false
  private var previousItems: [ClassifiedSourceItem] = []

  init(native: NativeMenuBarController, store: LayoutStore?) {
    self.native = native
    self.store = store
    do { layout = try store?.load() ?? SavedLayout() }
    catch { recoveryRequired = true; message = L("Saved layout cannot be read safely. Reset Layout to start again; the original file is preserved until then.") }
    native.onReveal = { [weak self] in
      self?.concealed = false
    }
    native.onExternalReveal = { [weak self] in
      self?.attemptedLaunchRestore = true
      self?.operationTask?.cancel()
    }
  }

  var canEdit: Bool { permissionGranted && scanComplete && !busy && !recoveryRequired }
  var ownBundle: String { Bundle.main.bundleIdentifier ?? "io.github.mahenzon.TrayNook.dev" }
  var dropdownItems: [ClassifiedSourceItem] {
    layout.items.filter { $0.placement == .dropdown }.compactMap { liveItem($0.id) }
  }

  /// Saved identities are `bundle` or `bundle#discriminator`; see IdentityAssessor.
  static func bundle(ofKey key: String) -> String {
    String(key.prefix { $0 != "#" })
  }

  func liveItem(_ key: String) -> ClassifiedSourceItem? {
    let matches = items.filter { $0.identity.persistentKey == key }
    return matches.count == 1 ? matches.first : nil
  }

  func isManageable(_ item: ClassifiedSourceItem) -> Bool {
    guard let bundle = item.observation.bundleIdentifier, let key = item.identity.persistentKey,
      bundle != ownBundle, !bundle.hasPrefix("com.apple."),
      liveItem(key) != nil else { return false }
    return item.manageability.status != .protected
  }

  /// Siblings of one app are named by their runtime AX text for display only.
  func name(for key: String) -> String {
    let bundle = Self.bundle(ofKey: key)
    let appName = liveItem(key)?.observation.applicationName
      ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?
        .deletingPathExtension().lastPathComponent ?? bundle
    guard key != bundle else { return appName }
    let metadata = liveItem(key)?.observation.metadata
    let detail = [metadata?.label, metadata?.title, metadata?.help]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty && $0.count <= 40 }
    return "\(appName) · \(detail ?? String(key.dropFirst(bundle.count + 1)))"
  }

  func icon(for key: String) -> NSImage {
    let bundle = Self.bundle(ofKey: key)
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
  }

  /// Capture the real menu-bar pixels of every dropdown item that is onscreen
  /// right now: at launch and during Apply (all revealed), and while one item
  /// is promoted. Hidden items keep their last capture. Without Screen
  /// Recording the cache is cleared and views fall back to app icons.
  func refreshProxyImages() {
    let authorized = ProxyImageCapture.isAuthorized
    if authorized != screenRecordingGranted { screenRecordingGranted = authorized }
    guard authorized else {
      if !proxyImages.isEmpty { proxyImages = [:] }
      return
    }
    // Never interleave window-list reads and captures with a native operation.
    guard !busy, !native.isBusy else { return }
    let dropdownKeys = Set(layout.items.filter { $0.placement == .dropdown }.map(\.id))
    var next = proxyImages.filter { dropdownKeys.contains($0.key) }
    var changed = next.count != proxyImages.count
    for item in dropdownItems where item.observation.isOnscreen == true {
      guard let key = item.identity.persistentKey,
        let window = native.statusWindowGeometry(for: item.observation),
        let captured = ProxyImageCapture.capture(windowID: window.id, frame: window.frame)
      else { continue }
      next[key] = captured
      changed = true
    }
    if changed { proxyImages = next }
  }

  func requestScreenRecording() {
    ProxyImageCapture.request()
    message = L("After granting Screen Recording, quit and reopen TrayNook so macOS applies it.")
  }

  func openScreenRecordingSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }

  func status(for saved: SavedItem) -> String {
    guard let item = liveItem(saved.id) else {
      let bundle = Self.bundle(ofKey: saved.id)
      if items.contains(where: { $0.observation.bundleIdentifier == bundle && $0.identity.persistentKey == nil }) {
        return L("Multiple items — kept visible")
      }
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) == nil
        ? L("App not found") : L("Not running")
    }
    if !isManageable(item) { return L("Protected — kept visible") }
    if saved.placement == .menuBar && native.isClipped(item.observation) {
      return L("Offscreen — menu bar is full")
    }
    if saved.placement != .menuBar && native.isBehindBoundary(item) != true {
      return L("Currently in Menu Bar — retry placement")
    }
    if saved.placement != .menuBar && concealed {
      return saved.placement == .dropdown ? L("Hidden — available in dropdown") : L("Hidden")
    }
    return L("Running")
  }

  func start() {
    refresh()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, let self else { return }
        if !self.busy { self.refresh() }
      }
    }
  }

  func stop() {
    pollTask?.cancel(); scanTask?.cancel(); operationTask?.cancel(); panelWatch?.cancel()
    native.remove()
  }

  func refresh() {
    guard !scanning, !busy else { return }
    scanning = true
    scanGeneration += 1
    let generation = scanGeneration
    scanTask = Task { [weak self] in
      let deadline = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, let self, self.scanGeneration == generation,
          self.scanning, self.concealed, !self.busy else { return }
        self.reveal(cancelLaunchRestore: false)
        self.message = L("Discovery is taking too long. Items are revealed until a fresh scan completes.")
        modelLog.error("revealed: discovery exceeded 3 s")
      }
      defer { deadline.cancel() }
      let snapshot = await Task.detached(priority: .utility) {
        AccessibilityInventoryScanner().scan()
      }.value
      guard !Task.isCancelled, let self else { return }
      self.accept(snapshot)
      self.scanning = false
      if !self.attemptedLaunchRestore && self.canEdit {
        self.attemptedLaunchRestore = true
        if self.layout.items.contains(where: { $0.placement != .menuBar }) {
          self.launchRestoreRunning = true
          self.applySavedLayout()
        } else {
          modelLog.notice("settings: nothing hidden in the saved layout")
          self.showSettings?() // nothing to hide yet: let the user arrange
        }
      }
    }
  }

  func accept(_ snapshot: InventorySnapshot) {
    native.noteInventory(snapshot)
    let wasGranted = permissionGranted
    let firstSnapshot = !hasAcceptedSnapshot
    hasAcceptedSnapshot = true
    loginEnabled = SMAppService.mainApp.status == .enabled
    screenRecordingGranted = ProxyImageCapture.isAuthorized
    concealed = native.isConcealed
    permissionGranted = snapshot.permission == .granted
    scanComplete = snapshot.completeness == .complete
    // One app answering Accessibility late (a launching app, a busy main
    // thread) makes a scan incomplete every few minutes on a crowded bar.
    // Nothing moved, so the section stays hidden through a few such scans;
    // the next complete scan diffs against the last complete one.
    if permissionGranted, !scanComplete, concealed, !busy, incompleteScans < 3 {
      incompleteScans += 1
      modelLog.notice("incomplete scan \(self.incompleteScans) of 3 while concealed: \(snapshot.warnings.joined(separator: " | "), privacy: .public)")
      return
    }
    incompleteScans = 0
    guard permissionGranted, scanComplete else {
      // A preparation error must reach the operation's completion UI. Only an
      // external reveal cancels that task; failing its own scan is an error.
      if busy { native.reveal(); concealed = false }
      else { reveal(cancelLaunchRestore: false) }
      modelLog.error("revealed: scan permission=\(snapshot.permission.rawValue, privacy: .public) completeness=\(snapshot.completeness.rawValue, privacy: .public) warnings=\(snapshot.warnings.joined(separator: " | "), privacy: .public)")
      guard !recoveryRequired else { return }
      if !permissionGranted {
        if firstSnapshot || wasGranted { selectedTab = 1; modelLog.notice("settings: accessibility not granted (first=\(firstSnapshot))"); showSettings?() }
        message = L("Grant Accessibility to discover and organize menu-bar items.")
      } else {
        message = L("Some apps did not respond. Items are revealed; retry when those apps respond.")
      }
      return
    }
    if !wasGranted && !recoveryRequired { selectedTab = 0; message = nil }
    let observed = snapshot.items.filter { $0.observation.bundleIdentifier != ownBundle }
    // ponytail: polling diff. A restarted or relaunched known source keeps the
    // section hidden and just rebinds its process; only an unknown bundle or an
    // ambiguous group change reveals. Add AX observers only if idle cost demands.
    if concealed {
      let changes = Self.keyedChanges(from: previousItems, to: observed)
      let known = Set(layout.items.map(\.id))
      let hidden = Set(layout.items.filter { $0.placement != .menuBar }.map(\.id))
      let verifiedVisible = Set(observed.compactMap { item in
        native.isVerifiedVisible(item) ? item.identity.persistentKey : nil
      })
      for change in changes where Self.rebindsProcess(change, hidden: hidden) {
        if let key = change.key,
          let item = observed.first(where: { $0.observation.runtimeID == change.change.currentRuntimeID }) {
          native.adoptProcess(key: key, pid: item.observation.processIdentifier)
        }
      }
      if Self.inventoryRequiresReveal(changes, known: known, hidden: hidden, verifiedVisible: verifiedVisible) {
        reveal()
        message = L("Menu-bar items changed. Review the layout before hiding again.")
        modelLog.notice("inventory change revealed: \(changes.map { "\($0.change.kind):\($0.key ?? "nil")" }.joined(separator: " "), privacy: .public)")
      }
    }
    previousItems = observed
    items = observed
    refreshProxyImages()
    if !recoveryRequired {
      let known = Set(layout.items.map(\.id))
      let additions = observed.compactMap { $0.identity.persistentKey }
        .filter { !known.contains($0) }
      var added = Set<String>()
      for key in additions where added.insert(key).inserted {
        layout.items.append(SavedItem(id: key))
      }
      // System items are never manageable; a transient one (Control Centre's
      // camera indicator) is forgotten as soon as it is gone.
      let stale = layout.items.filter { Self.bundle(ofKey: $0.id).hasPrefix("com.apple.") && liveItem($0.id) == nil }
      layout.items.removeAll { saved in stale.contains { $0.id == saved.id } }
      if !added.isEmpty || !stale.isEmpty { persist() }
    }
    if concealed && !canSafelyConceal() {
      // Diagnose before revealing: reveal() resets the geometry these depend on.
      let unsafe = items.compactMap { item -> String? in
        let behind = native.isBehindBoundary(item)
        let assigned = isManageable(item) && layout.items.contains { $0.id == item.identity.persistentKey && $0.placement != .menuBar }
        guard behind == nil || (behind == true && !assigned) else { return nil }
        let frame = item.observation.frame.map { "\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))" } ?? "no frame"
        return "\(item.identity.persistentKey ?? "nil")[\(frame) on=\(String(describing: item.observation.isOnscreen))] behind=\(String(describing: behind)) assigned=\(assigned)"
      }
      // One poll can catch the bar mid-relayout (Control Centre's Now Playing
      // changes width), leaving a frame across the separator edge. Reveal only
      // when the next scan still finds the section unsafe.
      unsafeScans += 1
      guard unsafeScans >= 2 else {
        modelLog.notice("unsafe once, waiting for the next scan: \(unsafe.joined(separator: " ; "), privacy: .public)")
        return
      }
      modelLog.error("revealed: unsafe items: \(unsafe.joined(separator: " ; "), privacy: .public)")
      reveal()
      message = L("An unassigned or protected item is behind the separator. Items have been revealed.")
    } else {
      unsafeScans = 0
    }
  }

  /// An inventory change together with the persistent key it concerns.
  struct KeyedChange {
    let change: SnapshotChange
    let key: String?
    /// Same identity, same process, different status window: a ranked
    /// sibling may have taken over another sibling's key.
    let windowReplaced: Bool
    /// A removed sibling left fewer than two items, so the survivor's key
    /// collapses to the plain bundle identifier without a visible change.
    let survivorsRekeyed: Bool

    var isSibling: Bool { key?.contains("#") == true }
    var isRankedSibling: Bool { key?.contains("#w") == true }
  }

  static func keyedChanges(from previous: [ClassifiedSourceItem], to current: [ClassifiedSourceItem]) -> [KeyedChange] {
    SnapshotDiffer().changes(from: previous, to: current).map { change in
      let before = previous.first { $0.observation.runtimeID == change.previousRuntimeID }
      let after = current.first { $0.observation.runtimeID == change.currentRuntimeID }
      let bundle = before?.observation.bundleIdentifier
      return KeyedChange(change: change, key: (after ?? before)?.identity.persistentKey,
        windowReplaced: before != nil && after != nil
          && before!.observation.processIdentifier == after!.observation.processIdentifier
          && before!.observation.statusWindowIdentifier != after!.observation.statusWindowIdentifier,
        survivorsRekeyed: change.kind == .removed && bundle != nil
          && current.contains { $0.observation.bundleIdentifier == bundle && $0.identity.persistentKey == bundle })
    }
  }

  /// A source the user placed outside Menu Bar may restart or relaunch without
  /// reopening the hidden section; the controller just adopts its new process.
  static func rebindsProcess(_ change: KeyedChange, hidden: Set<String>) -> Bool {
    guard let key = change.key, hidden.contains(key), !change.windowReplaced else { return false }
    switch change.change.kind {
    case .processReplaced, .created: return true
    default: return false
    }
  }

  /// Reveal when something could be hidden that the user did not place there:
  /// an unknown source, a Menu Bar source that is not verified visible, an
  /// ambiguous group change, a sibling leaving, or a ranked sibling's window
  /// changing. Ranks are assumed stable across a relaunch (ADR 0009).
  static func inventoryRequiresReveal(_ changes: [KeyedChange], known: Set<String>,
    hidden: Set<String>, verifiedVisible: Set<String>) -> Bool {
    changes.contains { change in
      if change.change.kind == .ambiguousInventoryChanged { return true }
      guard let key = change.key else { return false } // runtime-only window rows
      // A ranked sibling leaving re-keys the survivors, and its window changing
      // within one process can swap ranks. Identifier-keyed siblings keep their
      // keys (Control Centre's camera indicator comes and goes); when one of
      // them is re-keyed to the plain bundle, that key shows up as created.
      if change.isRankedSibling && (change.change.kind == .removed || change.windowReplaced) { return true }
      if change.isSibling && change.change.kind == .removed && change.survivorsRekeyed { return true }
      switch change.change.kind {
      case .created: return !known.contains(key) || (!hidden.contains(key) && !verifiedVisible.contains(key))
      case .processReplaced: return !hidden.contains(key) && !verifiedVisible.contains(key)
      case .removed, .orderChanged, .runtimeMetadataChanged, .ambiguousInventoryChanged: return false
      }
    }
  }

  func reveal(cancelLaunchRestore: Bool = true) {
    if cancelLaunchRestore { attemptedLaunchRestore = true }
    operationTask?.cancel(); native.reveal(); concealed = false
  }

  private func canSafelyConceal() -> Bool {
    items.allSatisfy { item in
      guard let behind = native.isBehindBoundary(item) else { return false }
      guard behind else { return true }
      return isManageable(item) && layout.items.contains {
        $0.id == item.identity.persistentKey && $0.placement != .menuBar
      }
    }
  }

  func toggleConcealment() {
    if concealed { reveal(); return }
    applySavedLayout()
  }

  func openDropdown(_ show: @escaping @MainActor () -> Void) {
    modelLog.notice("tray click: busy=\(self.busy) pending=\(self.native.hasPendingActivation) concealed=\(self.concealed)")
    // A click during an activation or return is not lost: the dropdown opens
    // as soon as the running operation ends.
    guard !busy else { queuedDropdown = show; return }
    if native.hasPendingActivation {
      // Show at once; the promoted item returns when the dropdown closes.
      dropdownShown = true
      show()
      return
    }
    guard !concealed, canEdit else { dropdownShown = true; show(); return }
    runOperation(restoreSettingsFocus: false, completion: { self.dropdownShown = true; show() }) {
      try await self.applyAndConceal(restoringToMenuBar: nil)
    }
  }

  func setPlacement(_ key: String, _ placement: Placement) {
    guard canEdit, let item = liveItem(key), isManageable(item) else { return }
    var next = layout
    next.place(key, in: placement)
    guard replaceLayout(next, undoable: true) else { return }
    applySavedLayout(restoringToMenuBar: placement == .menuBar ? key : nil)
  }

  func applySavedLayout(restoringToMenuBar key: String? = nil) {
    guard canEdit else { return }
    attemptedLaunchRestore = true
    message = L("Applying placements…")
    runOperation { try await self.applyAndConceal(restoringToMenuBar: key) }
  }

  private func freshOperationInventory() async throws {
    let snapshot = await Task.detached(priority: .userInitiated) {
      AccessibilityInventoryScanner().scan()
    }.value
    try Task.checkCancellation()
    accept(snapshot)
    guard permissionGranted, scanComplete, !recoveryRequired else {
      throw AppError.message(message ?? L("A complete, fresh menu-bar inventory is unavailable. Refresh and try again."))
    }
  }

  private func applyAndConceal(restoringToMenuBar key: String?) async throws {
    try await native.prepareLayout(keepingVisible: Set(layout.items.filter { $0.placement == .menuBar }.map(\.id)))
    try await freshOperationInventory()
    if let key, let item = liveItem(key), native.isClipped(item.observation) {
      throw AppError.message("\(name(for: key)): \(L("macOS has clipped this item. Free some menu-bar space, then retry moving it to Menu Bar."))")
    }
    let placements = layout.items.filter { $0.placement != .menuBar }
      + layout.items.filter { $0.placement == .menuBar }
    for saved in placements {
      try Task.checkCancellation()
      guard let item = liveItem(saved.id), isManageable(item) else { continue }
      let hidden = saved.placement != .menuBar
      let behind = native.isBehindBoundary(item)
      modelLog.notice("apply \(saved.id, privacy: .public) toHidden=\(hidden) behind=\(String(describing: behind), privacy: .public) clipped=\(self.native.isClipped(item.observation))")
      if hidden && native.isClipped(item.observation) { continue }
      // Already-clipped, unassigned items cannot be dragged. The native guard
      // still rejects any visible protected/unassigned item in the hidden section.
      if hidden ? behind == true : behind != true { continue }
      do { try await native.move(item, toHidden: hidden) }
      catch is CancellationError { throw CancellationError() }
      catch { throw AppError.message("\(name(for: saved.id)): \(error.localizedDescription)") }
      try await freshOperationInventory()
    }
    try Task.checkCancellation()
    let hidden = Set(layout.items.filter { $0.placement != .menuBar }.map(\.id))
    if !hidden.isEmpty {
      try await native.conceal(allowedKeys: hidden)
    }
    concealed = native.isConcealed
    message = nil
  }

  func activate(_ item: ClassifiedSourceItem, secondary: Bool = false) {
    guard canEdit, isManageable(item) else { return }
    runOperation(restoreSettingsFocus: false, revealOnFailure: false) {
      self.message = nil
      if self.native.hasPendingActivation { try await self.native.restoreActivation() }
      try await self.native.waitForActivationReadiness(item, secondary: secondary)
      let prepared = try await self.native.prepareActivation(item)
      let pid = item.observation.processIdentifier
      let interaction = NativeMenuInteraction(processIdentifier: pid)
      defer { interaction?.cancel() }
      let windowsBefore = Self.panelWindows(of: pid)
      var responseTimedOut = false
      do { try await self.native.activatePrepared(prepared, secondary: secondary) }
      catch NativeMenuActionError.responseTimedOut { responseTimedOut = true }
      let dismissed = await interaction?.waitForDismissal() == true
      try Task.checkCancellation()
      if responseTimedOut && !dismissed { throw NativeMenuActionError.responseTimedOut }
      if dismissed {
        try await self.native.restoreActivation()
      } else {
        self.message = L("This app stays visible while its panel is in use. Open TrayNook again to return it to the hidden section.")
        self.watchPanel(of: pid, before: windowsBefore)
      }
    }
  }

  /// Onscreen windows of a source other than its status items: the panel or
  /// popover it opened instead of a menu.
  private static func panelWindows(of pid: Int32) -> Set<UInt32> {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(windows.compactMap { window in
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue != Int(CGWindowLevelForKey(.statusWindow)),
        let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
      return id
    })
  }

  /// Once the panel the activation opened is gone, return the item on its own
  /// so the next click on the tray icon opens the dropdown directly.
  private func watchPanel(of pid: Int32, before: Set<UInt32>) {
    let opened = Self.panelWindows(of: pid).subtracting(before)
    guard !opened.isEmpty else { return }
    panelWatch?.cancel()
    panelWatch = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard let self, !Task.isCancelled, self.native.hasPendingActivation else { return }
        guard Self.panelWindows(of: pid).isDisjoint(with: opened) else { continue }
        if self.busy || self.dropdownShown { continue }
        modelLog.notice("panel closed; returning the promoted item")
        self.runOperation(restoreSettingsFocus: false, revealOnFailure: false) {
          try await self.native.restoreActivation()
          self.message = nil
        }
        return
      }
    }
  }

  private func runOperation(restoreSettingsFocus: Bool = true, revealOnFailure: Bool = true,
    completion: (@MainActor () -> Void)? = nil,
    _ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    scanTask?.cancel(); scanning = false
    closeDropdown?()
    let wasActive = NSApp.isActive
    NSApp.deactivate()
    operationTask = Task {
      do { try await operation() }
      catch is CancellationError { if revealOnFailure { native.reveal() } }
      catch NativeMenuActionError.inputNotIdle { message = NativeMenuActionError.inputNotIdle.localizedDescription }
      catch {
        if revealOnFailure { native.reveal() }
        message = error.localizedDescription
        modelLog.error("operation failed: \(error.localizedDescription, privacy: .public)")
        if launchRestoreRunning { modelLog.notice("settings: launch restore failed"); showSettings?() } // the launch restore needs the user
      }
      launchRestoreRunning = false
      concealed = native.isConcealed
      busy = false
      operationTask = nil
      if restoreSettingsFocus && wasActive { NSApp.activate(ignoringOtherApps: true) }
      refresh()
      if !Task.isCancelled { completion?() }
      if let queued = queuedDropdown {
        queuedDropdown = nil
        if !Task.isCancelled { openDropdown(queued) }
      }
    }
  }

  func restoreAll() {
    guard !busy, !recoveryRequired else { return }
    reveal()
    var next = layout; next.restoreAll()
    if replaceLayout(next, undoable: true) {
      message = L("All items are revealed. Saved placements are now Menu Bar.")
    }
  }

  /// Live order of one lane's keys during a handle drag; the rest of the
  /// layout keeps its positions.
  func setOrder(_ keys: [String], undoable: Bool) {
    guard canEdit else { return }
    let byKey = Dictionary(layout.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let lane = Set(keys)
    var cursor = keys.makeIterator()
    var next = layout
    next.items = next.items.compactMap { lane.contains($0.id) ? cursor.next().flatMap { byKey[$0] } : $0 }
    guard next.items.count == layout.items.count else { return }
    replaceLayout(next, undoable: undoable)
  }

  /// One undo step for a whole drag, registered against the pre-drag layout.
  func commitReorder(from start: SavedLayout?) {
    guard let start, start != layout else { return }
    let now = layout
    layout = start
    replaceLayout(now, undoable: true)
  }

  func forget(_ key: String) {
    guard !busy, !recoveryRequired, liveItem(key) == nil else { return }
    var next = layout; next.items.removeAll { $0.id == key }
    replaceLayout(next, undoable: true)
  }

  func setRowCapacity(_ count: Int) {
    guard !recoveryRequired else { return }
    layout.rowCapacity = min(30, max(1, count)); persist()
  }

  func resetLayout() {
    guard !busy else { return }
    reveal()
    do {
      let reset = SavedLayout(rowCapacity: layout.rowCapacity)
      try store?.save(reset)
      layout = reset; recoveryRequired = false
      undoManager.removeAllActions(); message = nil; refresh()
    } catch { message = L("Could not save layout. Check available disk space and folder permissions.") }
  }

  @discardableResult private func replaceLayout(_ next: SavedLayout, undoable: Bool) -> Bool {
    let previous = layout
    guard previous != next else { return true }
    layout = next
    guard persist() else { return false }
    if undoable {
      undoManager.registerUndo(withTarget: self) { target in
        MainActor.assumeIsolated {
          target.reveal()
          if target.replaceLayout(previous, undoable: true) {
            target.message = L("Layout restored. Apply Saved Layout to update native positions.")
          }
        }
      }
      undoManager.setActionName(L("Change Layout"))
    }
    return true
  }

  @discardableResult private func persist() -> Bool {
    guard !recoveryRequired else { return false }
    do { try store?.save(layout); return true }
    catch {
      reveal(); recoveryRequired = true
      message = L("Could not save layout. Check available disk space and folder permissions.")
      return false
    }
  }

  func requestAccessibility() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    openAccessibilitySettings()
  }

  func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  func setLoginEnabled(_ enabled: Bool) {
    do {
      if enabled { try SMAppService.mainApp.register() }
      else { try SMAppService.mainApp.unregister() }
      loginEnabled = SMAppService.mainApp.status == .enabled
      if SMAppService.mainApp.status == .requiresApproval {
        message = L("Approve TrayNook in System Settings → General → Login Items.")
      }
    } catch { message = L("Could not change Launch at Login. Check System Settings → General → Login Items.") }
  }

  func copyDiagnostics() {
    let info = Bundle.main.infoDictionary ?? [:]
    let summary = "TrayNook \(info["CFBundleShortVersionString"] ?? "development") (\(info["CFBundleVersion"] ?? "0"))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(permissionGranted)\nInventory complete: \(scanComplete)\nLayout recovery: \(recoveryRequired)\nNative section concealed: \(concealed)\nPrivate APIs: none\nScreen Recording: \(screenRecordingGranted)\nProxy imagery: \(screenRecordingGranted ? "captured menu-bar items" : "app icons")"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(summary, forType: .string)
    message = L("Diagnostics copied. No app inventory or item labels included.")
  }

  /// Runs only in --smoke-test, before the actual UI model is created. No TCC
  /// requests or data writes: /dev/null cannot contain the test layout file.
  static func verifyRecoveryBehavior(native: NativeMenuBarController) -> Bool {
    let failing = AppModel(native: native,
      store: LayoutStore(url: URL(fileURLWithPath: "/dev/null/traynook-layout.json")))
    failing.layout.items = [SavedItem(id: "example.fixture", placement: .dropdown)]
    failing.restoreAll()
    let saveError = L("Could not save layout. Check available disk space and folder permissions.")
    guard failing.recoveryRequired, failing.message == saveError else { return false }
    let denied = InventorySnapshot(capturedAt: Date(), permission: .denied, completeness: .incomplete,
      items: [], warnings: [], metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0))
    failing.accept(denied)
    guard failing.message == saveError else { return false }
    let navigation = AppModel(native: native, store: nil)
    navigation.accept(denied)
    guard navigation.selectedTab == 1, !navigation.attemptedLaunchRestore else { return false }
    navigation.selectedTab = 2
    navigation.accept(denied)
    guard navigation.selectedTab == 2, !navigation.attemptedLaunchRestore else { return false }
    navigation.reveal()
    return navigation.attemptedLaunchRestore
  }
}

enum AppError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

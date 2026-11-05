import AppKit
import ApplicationServices
import Combine
import InventoryIdentityCore
import ServiceManagement
import os

let modelLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.mahenzon.TrayNook", category: "model")

@MainActor
final class AppModel: ObservableObject {
  @Published var layout = SavedLayout() {
    didSet { if layout != oldValue { observationRevision &+= 1 } }
  }
  @Published var items: [ClassifiedSourceItem] = [] {
    didSet {
      if items != oldValue { observationRevision &+= 1 }
      let oldOwners = Dictionary(grouping: oldValue, by: { $0.observation.bundleIdentifier ?? "" })
        .mapValues { Set($0.map(\.observation.processIdentifier)) }
      let owners = Dictionary(grouping: items, by: { $0.observation.bundleIdentifier ?? "" })
        .mapValues { Set($0.map(\.observation.processIdentifier)) }
      for bundle in Set(oldOwners.keys).union(owners.keys) where oldOwners[bundle] != owners[bundle] {
        applicationIcons.invalidate(bundle: bundle)
      }
      liveItemsByKey = Dictionary(grouping: items, by: \.identity.persistentKey)
        .reduce(into: [:]) { lookup, entry in
          if let key = entry.key, entry.value.count == 1 { lookup[key] = entry.value[0] }
        }
    }
  }
  private var liveItemsByKey: [String: ClassifiedSourceItem] = [:]
  @Published var permissionGranted = false {
    didSet { if permissionGranted != oldValue { observationRevision &+= 1 } }
  }
  @Published var scanComplete = false
  @Published var scanning = false
  @Published var busy = false {
    didSet { if busy != oldValue { observationRevision &+= 1 } }
  }
  @Published private(set) var pendingPlacementKeys: Set<String> = []
  private var placementOperationRunning = false
  private var placementStatuses: [String: String] = [:]
  private var pendingVisiblePlacements: [String: NativeMenuBarController.VisiblePlacement] = [:]
  private var automaticPlacementKeys: Set<String> = []
  @Published var concealed = false
  @Published private(set) var nativeSetupMessage: String?
  @Published private var nativeItemStates: [String: NativeMenuBarController.ItemInspection] = [:]
  @Published var message: String?
  @Published var recoveryRequired = false {
    didSet { if recoveryRequired != oldValue { observationRevision &+= 1 } }
  }
  private var incompleteScans = 0
  private var lastCompleteStatusWindows: [StatusWindowState]?
  private var unsafeScans = 0
  private(set) var lastReveal: DiagnosticsReport.Event?
  private var operationInitialReveal: DiagnosticsReport.Event?
  @Published var selectedTab = 0 {
    didSet { if selectedTab == 2 && oldValue != 2 { refreshLoginStatus() } }
  }
  @Published var loginEnabled: Bool
  @Published var screenRecordingGranted = ProxyImageCapture.isAuthorized
  /// Keyed by persistent identity. Session-only cache of each dropdown item's
  /// last onscreen capture; cleared when Screen Recording is unavailable.
  @Published var proxyImages: [String: ProxyImage] = [:]
  let native: NativeMenuBarController
  let undoManager = UndoManager()
  var closeDropdown: (() -> Void)?
  var showSettings: (() -> Void)?
  private let store: LayoutStore?
  private let loginItemStatus: LoginItemStatus
  private let applicationIcons = ApplicationIconCache()
  private var applicationObservers: [NSObjectProtocol] = []
  private let applyMenuBarOrder: (@MainActor ([ClassifiedSourceItem]) async throws -> Void)?
  private var scanTask: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private(set) var pendingMenuBarOrder: [ClassifiedSourceItem]?
  private var scanGeneration = 0
  private var observationRevision = 0
  private let currentAccessibilityPermission: @MainActor () -> Bool
  private let inventoryScanner: any InventoryScanning
  private let sourceStatusReader: WindowMetadataReader
  private var attemptedLaunchRestore = false
  private var launchRestoreRunning = false
  /// After sleep or a display change the section is revealed, then the saved
  /// layout is applied again once things have settled.
  private(set) var reapplyNotBefore: Date?
  private var recoveringLayout = false
  private var panelWatch: Task<Void, Never>?
  /// True while the dropdown is open; a promoted item waits until it closes.
  var dropdownShown = false

  func dropdownClosed() {
    dropdownShown = false
    guard native.hasPendingActivation, !busy else { return }
    modelLog.notice("dropdown closed; returning the promoted item")
    runOperation(restoreSettingsFocus: false, revealOnFailure: false) {
      try await self.returnPromotedItem()
      self.message = nil
    }
  }
  /// A tray click that arrived while an operation ran; honored when it ends.
  private var queuedDropdown: (@MainActor () -> Void)?
  private var hasAcceptedSnapshot = false
  private var previousItems: [ClassifiedSourceItem] = []
  private var hiddenSourceRepairs: [String: HiddenSourceRepair] = [:]

  init(native: NativeMenuBarController, store: LayoutStore?,
    applyMenuBarOrder: (@MainActor ([ClassifiedSourceItem]) async throws -> Void)? = nil,
    loginItemStatus: LoginItemStatus? = nil,
    currentAccessibilityPermission: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
    inventoryScanner: any InventoryScanning = AccessibilityInventoryScanner(),
    sourceStatusSnapshot: @escaping @Sendable () -> [StatusWindowState]? = AccessibilityInventoryScanner.sourceStatusSnapshot) {
    self.native = native
    self.store = store
    self.applyMenuBarOrder = applyMenuBarOrder
    self.currentAccessibilityPermission = currentAccessibilityPermission
    self.inventoryScanner = inventoryScanner
    sourceStatusReader = WindowMetadataReader(load: { _ in
      // Enumerate every source window; known IDs alone cannot detect newly hidden items.
      (sourceStatusSnapshot() ?? []).map { window in
        WindowMetadata(id: window.windowIdentifier, pid: window.processIdentifier,
          frame: CGRect(x: window.frame.x, y: window.frame.y, width: window.frame.width, height: window.frame.height),
          isVisible: window.isOnscreen)
      }
    })
    let loginItemStatus = loginItemStatus ?? LoginItemStatus()
    self.loginItemStatus = loginItemStatus
    loginEnabled = loginItemStatus.isEnabled
    do { layout = try store?.load() ?? SavedLayout() }
    catch {
      recoveryRequired = true
      recordReveal(.operationFailure, failure: "layoutLoadFailed")
      message = L("Saved layout cannot be read safely. Reset Layout to start again; the original file is preserved until then.")
    }
    native.onReveal = { [weak self] in
      guard let self else { return }
      self.observationRevision &+= 1
      self.sourceStatusReader.cancelAll()
      self.cancelPanelWatch()
      self.concealed = false
      self.hiddenSourceRepairs.removeAll()
      self.lastCompleteStatusWindows = nil
      if self.nativeSetupMessage != nil { self.nativeSetupMessage = nil }
      if !self.nativeItemStates.isEmpty { self.nativeItemStates = [:] }
    }
    native.onExternalReveal = { [weak self] in
      self?.recordReveal(.userReveal)
      self?.observationRevision &+= 1
      self?.cancelPanelWatch()
      self?.pendingMenuBarOrder = nil
      self?.attemptedLaunchRestore = true
      self?.reapplyNotBefore = nil
      self?.operationTask?.cancel()
    }
  }

  var canEdit: Bool { permissionGranted && scanComplete && !busy && !recoveryRequired }
  func canEditPlacement(_ key: String) -> Bool {
    permissionGranted && scanComplete && !recoveryRequired
      && (!busy || (placementOperationRunning && operationTask?.isCancelled == false))
      && !pendingPlacementKeys.contains(key)
  }

  func canChoosePlacement(_ key: String) -> Bool {
    let bundle = Self.bundle(ofKey: key)
    guard layout.items.contains(where: { $0.id == key }),
      bundle != ownBundle, !bundle.hasPrefix("com.apple.") else { return false }
    let matches = items.filter { $0.identity.persistentKey == key }
    if let item = matches.first { return matches.count == 1 && isManageable(item) }
    // An unresolved live identity must not be treated as a closed application.
    return !items.contains { $0.observation.bundleIdentifier == bundle && $0.identity.persistentKey == nil }
  }
  var ownBundle: String { Bundle.main.bundleIdentifier ?? "io.github.mahenzon.TrayNook.dev" }
  var dropdownItems: [ClassifiedSourceItem] {
    layout.items.filter { $0.placement == .dropdown }.compactMap { liveItem($0.id) }
  }

  /// Saved identities are `bundle` or `bundle#discriminator`; see IdentityAssessor.
  static func bundle(ofKey key: String) -> String {
    String(key.prefix { $0 != "#" })
  }

  func liveItem(_ key: String) -> ClassifiedSourceItem? {
    liveItemsByKey[key]
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
      ?? applicationIcons.applicationURL(for: bundle)?
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
    return applicationIcons.icon(bundle: bundle, systemSymbol: Self.systemSymbol(forKey: key))
  }

  func invalidateApplicationIcons() {
    applicationIcons.invalidateAll()
    objectWillChange.send()
  }

  static func systemSymbol(forKey key: String) -> String? {
    guard key.hasPrefix("com.apple.") else { return nil }
    let suffix = key.split(separator: ".").last.map(String.init) ?? ""
    switch suffix {
    case "KerberosMenuExtra": return "key"
    case "TextInputMenuAgent": return "keyboard"
    case "now-playing": return "play.circle"
    case "sound": return "speaker.wave.2"
    case "bluetooth": return "dot.radiowaves.left.and.right"
    case "battery": return "battery.75percent"
    case "wifi": return "wifi"
    case "controlcenter": return "switch.2"
    case "clock": return "clock"
    case "audiovideo": return "video"
    case "focusmodes": return "moon"
    case "screenmirroring", "display": return "display"
    default: return key.contains("#") ? "menubar.rectangle" : nil
    }
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
    if placementOperationRunning, !pendingPlacementKeys.contains(saved.id),
      let status = placementStatuses[saved.id] { return status }
    guard let item = liveItem(saved.id) else {
      let bundle = Self.bundle(ofKey: saved.id)
      if items.contains(where: { $0.observation.bundleIdentifier == bundle && $0.identity.persistentKey == nil }) {
        return L("Multiple items — kept visible")
      }
      return applicationIcons.applicationURL(for: bundle) == nil
        ? L("App not found") : L("Not running")
    }
    if !isManageable(item) { return L("Protected — kept visible") }
    if saved.placement == .menuBar && nativeItemStates[item.observation.runtimeID]?.isClipped == true {
      return L("Offscreen — menu bar is full")
    }
    if saved.placement != .menuBar && observedBoundarySide(of: item) != true {
      return L("Currently in Menu Bar — retry placement")
    }
    if saved.placement != .menuBar && concealed {
      return saved.placement == .dropdown ? L("Hidden — available in dropdown") : L("Hidden")
    }
    return L("Running")
  }

  /// Presentation reads the last inventory inspection; actions validate live geometry.
  func observedBoundarySide(of item: ClassifiedSourceItem) -> Bool? {
    if !concealed && !native.hasVisibleBoundary { return false }
    return nativeItemStates[item.observation.runtimeID]?.behindBoundary
  }

  func start() {
    observeApplicationChanges()
    refresh()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, let self else { return }
        if !self.busy { self.refresh(showProgress: false) }
      }
    }
  }

  func stop() {
    observationRevision &+= 1
    pendingMenuBarOrder = nil
    pollTask?.cancel(); cancelScan(); operationTask?.cancel(); cancelPanelWatch()
    sourceStatusReader.shutdown()
    for observer in applicationObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    applicationObservers.removeAll()
    native.remove()
  }

  func refresh(invalidateIcons: Bool = false, showProgress: Bool = true) {
    if invalidateIcons { invalidateApplicationIcons() }
    guard scanTask == nil, !scanning, !busy else { return }
    if showProgress { scanning = true }
    scanGeneration += 1
    let generation = scanGeneration
    let scanner = inventoryScanner
    scanTask = Task { [weak self] in
      defer {
        if let self, self.scanGeneration == generation {
          if self.scanning { self.scanning = false }
          self.scanTask = nil
        }
      }
      let deadline = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, let self, self.scanGeneration == generation,
          self.scanTask != nil, self.concealed, !self.busy else { return }
        await self.handleSlowInventory()
      }
      defer { deadline.cancel() }
      let snapshot = await Task.detached(priority: .utility) {
        scanner.scan(promptForPermission: false)
      }.value
      guard !Task.isCancelled, let self else { return }
      let accepted = await self.acceptLatest(snapshot)
      guard !Task.isCancelled, self.scanGeneration == generation else { return }
      if self.scanning { self.scanning = false }
      guard accepted else { return }
      if self.takeLayoutRecovery() {
        modelLog.notice("re-applying the saved layout after a temporary reveal")
        self.applySavedLayout(recovering: true)
      } else if !self.attemptedLaunchRestore && self.canEdit {
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

  private func cancelScan() {
    scanGeneration += 1
    scanTask?.cancel()
    sourceStatusReader.cancelAll()
    scanTask = nil
    if scanning { scanning = false }
  }

  func handleSlowInventory() async {
    guard scanTask != nil else { return }
    await verifyConcealmentDuringInventoryFailure(requiringScan: true)
  }

  private func verifyConcealmentDuringInventoryFailure(requiringScan: Bool = false) async {
    guard !Task.isCancelled, (!requiringScan || scanTask != nil), concealed, !busy else { return }
    let generation = scanGeneration
    let revision = observationRevision
    let baseline = lastCompleteStatusWindows
    scanComplete = false
    var current: [StatusWindowState]?
    if permissionGranted, unsafeScans == 0, let baseline, !baseline.isEmpty {
      current = await sourceStatusReader.read([])?.map { window in
        StatusWindowState(processIdentifier: window.pid, windowIdentifier: window.id,
          frame: ItemFrame(x: window.frame.minX, y: window.frame.minY,
            width: window.frame.width, height: window.frame.height), isOnscreen: window.isVisible)
      }
    }
    guard !Task.isCancelled, (!requiringScan || scanTask != nil), concealed, !busy,
      generation == scanGeneration, revision == observationRevision else { return }
    let granted = currentAccessibilityPermission()
    if permissionGranted != granted { permissionGranted = granted }
    if granted, Self.canRetainConcealment(lastVerified: baseline, current: current, unsafeScans: unsafeScans) {
      message = NativeMenuActionError.inventoryUnavailable.localizedDescription
      modelLog.notice("discovery exceeded 3 s with unchanged native sources; keeping items concealed")
      return
    }
    revealForInventoryRecovery()
    message = granted
      ? L("Discovery is taking too long. Items are revealed until a fresh scan completes.")
      : L("Grant Accessibility to discover and organize menu-bar items.")
    modelLog.error("revealed: discovery exceeded 3 s")
  }

  static func canRetainConcealment(lastVerified: [StatusWindowState]?, current: [StatusWindowState]?,
    unsafeScans: Int) -> Bool {
    guard unsafeScans == 0, let lastVerified, !lastVerified.isEmpty, let current,
      current == lastVerified, Set(current.map(\.windowIdentifier)).count == current.count else { return false }
    return current.allSatisfy { $0.processIdentifier > 0 && $0.windowIdentifier > 0 && $0.frame.isUsable }
  }

  private struct PreparedInventory {
    let observed: [ClassifiedSourceItem]
    let statusWindows: [StatusWindowState]?
    let watchingLayout: Bool
    let changes: [KeyedChange]
    let known: Set<String>
    let hidden: Set<String>
  }

  /// Explicit native operations retain their synchronous fresh inspection.
  func accept(_ snapshot: InventorySnapshot) {
    observationRevision &+= 1
    guard let prepared = prepareInventory(snapshot) else { return }
    applyInventory(prepared, inspection: native.inspect(prepared.observed))
  }

  /// Polling suspends for metadata without blocking scrolling or native actions.
  @discardableResult func acceptLatest(_ snapshot: InventorySnapshot) async -> Bool {
    observationRevision &+= 1
    guard !busy, !Task.isCancelled else { return false }
    guard Date().timeIntervalSince(snapshot.capturedAt) <= 3 else {
      scanComplete = false
      if concealed { await verifyConcealmentDuringInventoryFailure() }
      else { message = NativeMenuActionError.inventoryUnavailable.localizedDescription }
      return false
    }
    guard let prepared = prepareInventory(snapshot) else { return true }
    let revision = observationRevision
    let generation = scanGeneration
    let inspection = await native.inspectLatest(prepared.observed)
    guard !Task.isCancelled,
      !busy, revision == observationRevision, generation == scanGeneration else { return false }
    guard currentAccessibilityPermission() else {
      accept(InventorySnapshot(capturedAt: Date(), permission: .denied, completeness: .incomplete,
        items: [], warnings: [], metrics: snapshot.metrics))
      return true
    }
    let geometryUnavailable = L("Menu-bar geometry could not be verified. Items are revealed; the saved layout is applied again shortly.")
    let inventoryUnavailable = NativeMenuActionError.inventoryUnavailable.localizedDescription
    guard let inspection, Date().timeIntervalSince(snapshot.capturedAt) <= 3 else {
      scanComplete = false
      if concealed { await verifyConcealmentDuringInventoryFailure() }
      else { message = inventoryUnavailable }
      return false
    }
    if message == geometryUnavailable || message == inventoryUnavailable { message = nil }
    applyInventory(prepared, inspection: inspection)
    return true
  }

  private func prepareInventory(_ snapshot: InventorySnapshot) -> PreparedInventory? {
    native.noteInventory(snapshot)
    let firstSnapshot = !hasAcceptedSnapshot
    hasAcceptedSnapshot = true
    let recordingGranted = ProxyImageCapture.isAuthorized
    if screenRecordingGranted != recordingGranted { screenRecordingGranted = recordingGranted }
    if concealed != native.isConcealed { concealed = native.isConcealed }
    guard acceptScanStatus(snapshot, firstSnapshot: firstSnapshot) else { return nil }
    let observed = snapshot.items.filter { $0.observation.bundleIdentifier != ownBundle }
    let watchingLayout = concealed || reapplyNotBefore != nil || recoveringLayout
    let changes = watchingLayout ? Self.keyedChanges(from: previousItems, to: observed) : []
    let known = Set(layout.items.map(\.id))
    let hidden = Set(layout.items.filter { $0.placement != .menuBar }.map(\.id))
    for change in changes where Self.rebindsProcess(change, hidden: hidden) {
      if let key = change.key,
        let item = observed.first(where: { $0.observation.runtimeID == change.change.currentRuntimeID }) {
        native.adoptProcess(key: key, pid: item.observation.processIdentifier)
      }
    }
    return PreparedInventory(observed: observed, statusWindows: snapshot.statusWindows, watchingLayout: watchingLayout,
      changes: changes, known: known, hidden: hidden)
  }

  private func applyInventory(_ prepared: PreparedInventory, inspection: NativeMenuBarController.Inspection) {
    let observed = prepared.observed
    let changes = prepared.changes
    let known = prepared.known
    let hidden = prepared.hidden
    let verifiedVisible = Self.verifiedVisibleSourceKeys(observed, inspection: inspection)
    if nativeSetupMessage != inspection.setupMessage { nativeSetupMessage = inspection.setupMessage }
    if nativeItemStates != inspection.items { nativeItemStates = inspection.items }
    // Polling diff: hidden sources rebind, other additions reconcile, and
    // ambiguous identities stop for review, including during recovery.
    if prepared.watchingLayout {
      if Self.inventoryRequiresReveal(changes, known: known, hidden: hidden, verifiedVisible: verifiedVisible) {
        let needsReview = Self.inventoryRequiresReview(changes)
        let affected = changes.filter {
          Self.inventoryRequiresReveal([$0], known: known, hidden: hidden, verifiedVisible: verifiedVisible)
        }.compactMap { $0.change.identity?.bundleIdentifier ?? $0.change.runtimeGroup?.bundleIdentifier }
        if needsReview {
          reveal(reason: .identityReview, affectedBundles: affected)
          message = L("Menu-bar items changed. Review the layout before hiding again.")
        } else if !recoveringLayout {
          revealForInventoryRecovery(affectedBundles: affected)
        }
        // Log each actual trigger separately: order changes used to fill the
        // log entry and truncate the source that caused the reveal.
        for change in changes where Self.inventoryRequiresReveal([change], known: known,
          hidden: hidden, verifiedVisible: verifiedVisible) {
          modelLog.notice("inventory change: \(change.change.kind.rawValue, privacy: .public) key=\(change.key ?? "ambiguous", privacy: .public) review=\(needsReview)")
        }
      }
    }
    previousItems = observed
    if items != observed { items = observed }
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
      if !stale.isEmpty { layout.items.removeAll { saved in stale.contains { $0.id == saved.id } } }
      if !added.isEmpty || !stale.isEmpty { persist() }
    }
    lastCompleteStatusWindows = prepared.statusWindows
    validateConcealment { inspection.items[$0.observation.runtimeID]?.behindBoundary }
    repairReturnedHiddenSources(changes, inspection: inspection)
  }

  func repairReturnedHiddenSources(_ changes: [KeyedChange], inspection: NativeMenuBarController.Inspection) {
    guard concealed, !recoveryRequired else { return }
    let hidden = Set(layout.items.filter { $0.placement != .menuBar }.map(\.id))
    let verifiedVisible = Self.verifiedVisibleSourceKeys(items, inspection: inspection)
    hiddenSourceRepairs = hiddenSourceRepairs.filter { key, repair in
      guard hidden.contains(key), let item = liveItem(key), isManageable(item), repair.matches(item) else { return false }
      return inspection.items[item.observation.runtimeID]?.behindBoundary != true
    }
    for key in Self.hiddenSourceRepairKeys(changes, hidden: hidden, verifiedVisible: verifiedVisible) {
      if let item = liveItem(key), isManageable(item) { hiddenSourceRepairs[key] = HiddenSourceRepair(source: item) }
    }
    guard canEdit, !native.hasPendingActivation else { return }
    let now = Date()
    for key in hiddenSourceRepairs.keys.sorted() where verifiedVisible.contains(key) {
      guard let repair = hiddenSourceRepairs[key], repair.canAttempt(now: now) else { continue }
      enqueuePlacement(key, automatic: true)
    }
  }

  func validateConcealment(using side: (ClassifiedSourceItem) -> Bool?) {
    guard concealed else { unsafeScans = 0; return }
    // Sample each source once: re-reading changing geometry can disagree with the decision.
    var needsReview = false
    var affected: [String] = []
    let unsafe = items.compactMap { item -> String? in
      let behind = side(item)
      let assigned = isManageable(item) && layout.items.contains { $0.id == item.identity.persistentKey && $0.placement != .menuBar }
      guard behind == nil || (behind == true && !assigned) else { return nil }
      if let bundle = item.observation.bundleIdentifier { affected.append(bundle) }
      if behind == true { needsReview = true }
      let frame = item.observation.frame.map { "\($0.x),\($0.y) \($0.width)x\($0.height)" } ?? "no frame"
      return "\(item.identity.persistentKey ?? "nil")[\(frame) on=\(String(describing: item.observation.isOnscreen))] behind=\(String(describing: behind)) assigned=\(assigned)"
    }
    guard !unsafe.isEmpty else { unsafeScans = 0; return }
    // One poll can catch the bar mid-relayout; the next scan must confirm it.
    unsafeScans += 1
    guard unsafeScans >= 2 else {
      modelLog.notice("unsafe once, waiting for the next scan: \(unsafe.joined(separator: " ; "), privacy: .public)")
      return
    }
    modelLog.error("revealed: unsafe items: \(unsafe.joined(separator: " ; "), privacy: .public)")
    if needsReview {
      reveal(reason: .identityReview, affectedBundles: affected)
      message = L("An unassigned or protected item is behind the separator. Items have been revealed.")
    } else {
      revealForInventoryRecovery(reason: .geometryUnavailable, affectedBundles: affected)
      if reapplyNotBefore != nil { reapplyNotBefore = Date().addingTimeInterval(3) }
      message = L("Menu-bar geometry could not be verified. Items are revealed; the saved layout is applied again shortly.")
    }
  }

  func acceptScanStatus(_ snapshot: InventorySnapshot, firstSnapshot: Bool = false) -> Bool {
    let wasGranted = permissionGranted
    let wasComplete = scanComplete
    let granted = snapshot.permission == .granted
    let complete = snapshot.completeness == .complete
    if permissionGranted != granted { permissionGranted = granted }
    if scanComplete != complete { scanComplete = complete }
    // An AX read failure cannot undo a verified layout when WindowServer still
    // reports the same owners, windows, geometry, and visibility.
    if permissionGranted, !scanComplete, concealed, !busy,
      Date().timeIntervalSince(snapshot.capturedAt) <= 3,
      Self.canRetainConcealment(lastVerified: lastCompleteStatusWindows,
        current: snapshot.statusWindows, unsafeScans: unsafeScans) {
      incompleteScans = 0
      if wasComplete { modelLog.notice("incomplete scan with unchanged native windows; keeping items concealed") }
      return false
    }
    // One app answering Accessibility late (a launching app, a busy main
    // thread) makes a scan incomplete every few minutes on a crowded bar.
    // Nothing moved, so the section stays hidden through a few such scans;
    // the next complete scan diffs against the last complete one.
    if permissionGranted, !scanComplete, concealed, !busy, incompleteScans < 3 {
      incompleteScans += 1
      modelLog.notice("incomplete scan \(self.incompleteScans) of 3 while concealed: \(snapshot.warnings.joined(separator: " | "), privacy: .public)")
      return false
    }
    incompleteScans = 0
    guard permissionGranted, scanComplete else {
      // A preparation error must reach the operation's completion UI. Only an
      // external reveal cancels that task; failing its own scan is an error.
      if busy {
        if lastReveal == operationInitialReveal {
          recordReveal(.inventoryUnavailable, failure: granted ? nil : "accessibilityDenied")
        }
        native.reveal(); concealed = false
      }
      else { revealForInventoryRecovery() }
      modelLog.error("revealed: scan permission=\(snapshot.permission.rawValue, privacy: .public) completeness=\(snapshot.completeness.rawValue, privacy: .public) warnings=\(snapshot.warnings.joined(separator: " | "), privacy: .public)")
      guard !recoveryRequired else { return false }
      if !permissionGranted {
        if firstSnapshot || wasGranted { modelLog.notice("settings: accessibility not granted (first=\(firstSnapshot))"); showSettings?() }
        message = L("Grant Accessibility to discover and organize menu-bar items.")
      } else {
        message = reapplyNotBefore != nil
          ? L("Some apps did not respond. Items are revealed until a complete scan succeeds.")
          : L("Some apps did not respond. Items are revealed; retry when those apps respond.")
      }
      return false
    }
    if !wasGranted && !recoveryRequired { message = nil }
    return true
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

  static func hiddenSourceRepairKeys(_ changes: [KeyedChange], hidden: Set<String>,
    verifiedVisible: Set<String>) -> Set<String> {
    guard !inventoryRequiresReview(changes) else { return [] }
    return Set(changes.compactMap { change in
      guard let key = change.key, hidden.contains(key),
        rebindsProcess(change, hidden: hidden) || (change.windowReplaced && !change.isRankedSibling),
        verifiedVisible.contains(key) else { return nil }
      return key
    })
  }

  static func verifiedVisibleSourceKeys(_ items: [ClassifiedSourceItem],
    inspection: NativeMenuBarController.Inspection) -> Set<String> {
    Set(items.compactMap { item -> String? in
      guard item.observation.isOnscreen == true, item.observation.statusWindowIdentifier != nil,
        inspection.items[item.observation.runtimeID]?.isVerifiedVisible == true else { return nil }
      return item.identity.persistentKey
    })
  }

  @MainActor struct HiddenSourceRepair {
    let source: ClassifiedSourceItem
    private(set) var attempts = 0
    private(set) var notBefore = Date.distantPast

    func matches(_ current: ClassifiedSourceItem) -> Bool {
      NativeMenuBarController.preservesSourceIdentity(original: source, current: current)
        && source.observation.statusWindowIdentifier == current.observation.statusWindowIdentifier
    }

    mutating func takeAttempt(now: Date) -> Bool {
      // A refused source stays in its mismatch/Retry state instead of causing endless native input.
      guard canAttempt(now: now) else { return false }
      attempts += 1
      notBefore = now.addingTimeInterval(3)
      return true
    }

    func canAttempt(now: Date) -> Bool { attempts < 3 && now >= notBefore }

    mutating func deferTransientFailure() { attempts = max(0, attempts - 1) }
  }

  /// Reveal when something could be hidden that the user did not place there:
  /// an unknown source, a Menu Bar source that is not verified visible, an
  /// ambiguous group change, a sibling leaving, or a ranked sibling's window
  /// changing. Ranks are assumed stable across a relaunch (ADR 0009).
  static func inventoryRequiresReveal(_ changes: [KeyedChange], known: Set<String>,
    hidden: Set<String>, verifiedVisible: Set<String>) -> Bool {
    if inventoryRequiresReview(changes) { return true }
    return changes.contains { change in
      guard let key = change.key else { return false } // runtime-only window rows
      // System items are never hidden by TrayNook; one appearing (Control
      // Centre's camera indicator) changes nothing about the hidden section.
      if key.hasPrefix("com.apple.") && change.change.kind == .created { return false }
      switch change.change.kind {
      case .created:
        if change.isSibling && !known.contains(key) { return true }
        return !hidden.contains(key) && !verifiedVisible.contains(key)
      case .processReplaced: return !hidden.contains(key) && !verifiedVisible.contains(key)
      case .removed, .orderChanged, .runtimeMetadataChanged, .ambiguousInventoryChanged: return false
      }
    }
  }

  static func inventoryRequiresReview(_ changes: [KeyedChange]) -> Bool {
    changes.contains { change in
      if change.change.kind == .ambiguousInventoryChanged { return true }
      // Re-keyed siblings can inherit another source's saved placement.
      if change.isRankedSibling && (change.change.kind == .removed || change.windowReplaced) { return true }
      return change.isSibling && change.change.kind == .removed && change.survivorsRekeyed
    }
  }

  func environmentChanged(_ reason: String) {
    modelLog.notice("environment changed: \(reason, privacy: .public); revealing, re-applying in 10 s")
    reveal(reason: .environmentChange)
    message = L("Display or session changed. Items are revealed; the saved layout is applied again shortly.")
    if layout.items.contains(where: { $0.placement != .menuBar }) {
      reapplyNotBefore = Date().addingTimeInterval(10)
    }
  }

  private func takeLayoutRecovery(now: Date = Date()) -> Bool {
    guard let notBefore = reapplyNotBefore, now >= notBefore, canEdit, !concealed else { return false }
    reapplyNotBefore = nil
    return true
  }

  private func revealForInventoryRecovery(reason: DiagnosticsReport.Reason = .inventoryUnavailable,
    affectedBundles: [String] = []) {
    let shouldRecover = concealed && layout.items.contains { $0.placement != .menuBar }
    // Repeated incomplete polls must not replace the event that started recovery.
    if concealed || lastReveal == nil {
      reveal(cancelLaunchRestore: false, reason: reason, affectedBundles: affectedBundles)
    } else {
      preservingRevealReason { reveal(cancelLaunchRestore: false) }
    }
    // A transient scan failure must not permanently turn off the saved layout.
    if shouldRecover { reapplyNotBefore = Date() }
  }

  func reveal(cancelLaunchRestore: Bool = true, reason: DiagnosticsReport.Reason = .userReveal,
    affectedBundles: [String] = []) {
    recordReveal(reason, affectedBundles: affectedBundles)
    pendingMenuBarOrder = nil
    cancelPanelWatch()
    if cancelLaunchRestore {
      attemptedLaunchRestore = true
      reapplyNotBefore = nil
    }
    operationTask?.cancel(); native.reveal(); concealed = false
  }

  private func recordReveal(_ reason: DiagnosticsReport.Reason, failure: String? = nil,
    affectedBundles: [String] = [], at timestamp: Date = Date()) {
    lastReveal = DiagnosticsReport.Event(reason: reason, timestamp: timestamp,
      failure: failure, affectedBundles: affectedBundles)
  }

  private func preservingRevealReason(_ cleanup: () -> Void) {
    let original = lastReveal
    defer { lastReveal = original }
    cleanup()
  }

  private func recordOperationFailure(_ error: Error, context: String, affectedBundles: [String] = []) {
    let code: String
    switch error {
    case NativeMenuActionError.responseTimedOut: code = "responseTimedOut"
    case NativeMenuActionError.inputNotIdle: code = "inputNotIdle"
    case NativeMenuActionError.inputInterrupted: code = "inputInterrupted"
    case NativeMenuActionError.placementInterrupted: code = "placementInterrupted"
    case NativeMenuActionError.inventoryUnavailable: code = "inventoryUnavailable"
    default: code = "failed"
    }
    // Localized errors may contain item labels; copy only fixed categories.
    recordReveal(code == "inventoryUnavailable" ? .inventoryUnavailable : .operationFailure,
      failure: "\(context).\(code)", affectedBundles: affectedBundles)
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
      try await self.applyAndConceal(restoringToMenuBar: [])
    }
  }

  func setPlacement(_ key: String, _ placement: Placement) {
    guard canEditPlacement(key), canChoosePlacement(key),
      let previous = layout.items.first(where: { $0.id == key })?.placement,
      previous != placement else { return }
    let item = liveItem(key)
    var next = layout
    next.place(key, in: placement)
    guard replaceLayout(next, undoable: true) else { return }
    if let item { applyPlacementChange(key, from: previous, item: item) }
  }

  func retryPlacement(_ key: String) {
    guard canEditPlacement(key), let item = liveItem(key), isManageable(item) else { return }
    let menuBar = layout.items.filter { $0.placement == .menuBar }
    var visiblePlacement: NativeMenuBarController.VisiblePlacement = .leftmost
    if let index = menuBar.firstIndex(where: { $0.id == key }), index > 0 {
      let next = menuBar.dropFirst(index + 1).compactMap { liveItem($0.id) }
        .first { native.isBehindBoundary($0) == false }
      visiblePlacement = next.map { .before($0) } ?? .beforeLauncher
    }
    enqueuePlacement(key, visiblePlacement: visiblePlacement)
  }

  private func applyPlacementChange(_ key: String, from previous: Placement, item: ClassifiedSourceItem,
    visiblePlacement: NativeMenuBarController.VisiblePlacement = .leftmost) {
    // Both hidden lanes share one native section; only the proxy list changes.
    if previous != .menuBar, layout.items.first(where: { $0.id == key })?.placement != .menuBar,
      concealed, !native.hasPendingActivation, native.isBehindBoundary(item) == true {
      if layout.items.first(where: { $0.id == key })?.placement == .alwaysHidden {
        proxyImages.removeValue(forKey: key)
      }
      return
    }
    enqueuePlacement(key, visiblePlacement: visiblePlacement)
  }

  private func enqueuePlacement(_ key: String,
    visiblePlacement: NativeMenuBarController.VisiblePlacement = .leftmost, automatic: Bool = false) {
    if !placementOperationRunning {
      placementStatuses = Dictionary(uniqueKeysWithValues: layout.items.map { ($0.id, status(for: $0)) })
    }
    pendingPlacementKeys.insert(key)
    pendingVisiblePlacements[key] = visiblePlacement
    if automatic { automaticPlacementKeys.insert(key) }
    else { automaticPlacementKeys.remove(key) }
    guard !placementOperationRunning else { return }
    placementOperationRunning = true
    attemptedLaunchRestore = true
    message = nil
    runOperation(revealOnFailure: false, deactivateApp: false, diagnosticContext: "placement") {
      defer {
        self.placementOperationRunning = false
        self.pendingPlacementKeys.removeAll()
        self.placementStatuses.removeAll()
        self.pendingVisiblePlacements.removeAll()
        self.automaticPlacementKeys.removeAll()
      }
      var warnings: [String] = []
      while !self.pendingPlacementKeys.isEmpty {
        try Task.checkCancellation()
        let keys = self.pendingPlacementKeys
        let requested = self.layout
        let visiblePlacements = self.pendingVisiblePlacements
        do {
          if Self.canApplyPlacementsIndividually(keys: keys, layout: requested,
            concealed: self.native.isConcealed, hasPendingActivation: self.native.hasPendingActivation) {
            var failedSource: ClassifiedSourceItem?
            var deferredWarnings: [String] = []
            let batchWarnings = try await Self.applyIndividualPlacementsWithFallback(
              requested.items.filter { keys.contains($0.id) }, move: { saved in
              failedSource = nil
              try Task.checkCancellation()
              guard let item = self.liveItem(saved.id), self.isManageable(item) else { return false }
              let toHidden = saved.placement != .menuBar
              if toHidden && self.native.isBehindBoundary(item) == true { return false }
              guard Self.takePlacementAttempt(automatic: self.automaticPlacementKeys.contains(saved.id),
                repair: &self.hiddenSourceRepairs[saved.id], source: item, now: Date()) else { return false }
              failedSource = item
              let moved: ClassifiedSourceItem
              do {
                moved = try await (toHidden
                  ? self.native.hideWhileConcealed(item)
                  : self.native.showWhileConcealed(item, placement: visiblePlacements[saved.id] ?? .leftmost))
              } catch is CancellationError { throw CancellationError() }
              catch let error as NativeMenuActionError {
                self.recordOperationFailure(error, context: "placement",
                  affectedBundles: item.observation.bundleIdentifier.map { [$0] } ?? [])
                if self.automaticPlacementKeys.contains(saved.id),
                  Self.deferAutomaticPlacementFailure(error, repair: &self.hiddenSourceRepairs[saved.id]) {
                  deferredWarnings.append(error.localizedDescription)
                  failedSource = nil
                  return false
                }
                throw error
              }
              catch {
                self.recordOperationFailure(error, context: "placement",
                  affectedBundles: item.observation.bundleIdentifier.map { [$0] } ?? [])
                throw AppError.message("\(self.name(for: saved.id)): \(error.localizedDescription)")
              }
              if let index = self.items.firstIndex(where: { $0.identity.persistentKey == saved.id }) {
                self.items[index] = moved
              }
              failedSource = nil
              return true
            }, refresh: {
              try await self.freshOperationInventory(preservingConcealment: true)
              if let original = failedSource {
                guard let key = original.identity.persistentKey, let current = self.liveItem(key),
                  NativeMenuBarController.preservesSourceIdentity(original: original, current: current),
                  original.observation.statusWindowIdentifier == current.observation.statusWindowIdentifier else {
                  self.recordReveal(.identityReview,
                    affectedBundles: original.observation.bundleIdentifier.map { [$0] } ?? [])
                  throw AppError.message(L("Menu-bar items changed. Review the layout before hiding again."))
                }
              }
            }, verifyConcealed: {
              guard self.native.isConcealed, !self.native.hasPendingActivation else {
                throw NativeMenuActionError.inventoryUnavailable
              }
            }, reorder: {
              if requested.items.contains(where: { keys.contains($0.id) && $0.placement == .menuBar }) {
                try await self.synchronizeMenuBarOrder(self.menuBarItems(in: requested))
              }
            })
            warnings += batchWarnings + deferredWarnings
            self.concealed = self.native.isConcealed
            self.message = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
          } else {
            let restoring = Set(requested.items.filter { keys.contains($0.id) && $0.placement == .menuBar }.map(\.id))
            try await self.applyAndConceal(restoringToMenuBar: restoring, layout: requested)
          }
        } catch where Self.shouldRetryPlacement(after: error) {
          // Editing another picker can interrupt the drag; keep every request.
          try await Task.sleep(for: .milliseconds(300))
          continue
        }
        self.pendingPlacementKeys.subtract(keys)
        self.automaticPlacementKeys.subtract(keys)
        for key in keys { self.pendingVisiblePlacements.removeValue(forKey: key) }
      }
    }
  }

  static func canApplyPlacementsIndividually(keys: Set<String>, layout: SavedLayout,
    concealed: Bool, hasPendingActivation: Bool) -> Bool {
    guard concealed, !hasPendingActivation, !keys.isEmpty else { return false }
    return keys.allSatisfy { key in
      layout.items.contains { $0.id == key }
    }
  }

  static func shouldRetryPlacement(after error: Error) -> Bool {
    guard let error = error as? NativeMenuActionError else { return false }
    return [.inputNotIdle, .inputInterrupted, .placementInterrupted].contains(error)
  }

  static func takePlacementAttempt(automatic: Bool, repair: inout HiddenSourceRepair?,
    source: ClassifiedSourceItem, now: Date) -> Bool {
    guard automatic else { return true }
    guard var pending = repair, pending.matches(source), pending.takeAttempt(now: now) else { return false }
    repair = pending
    return true
  }

  static func applyIndividualPlacementsWithFallback(_ placements: [SavedItem],
    move: (SavedItem) async throws -> Bool, refresh: () async throws -> Void,
    verifyConcealed: () throws -> Void, reorder: () async throws -> Void) async throws -> [String] {
    try verifyConcealed()
    return try await applyPlacementsWithFallback(placements, move: move, refresh: refresh,
      repairBoundary: { try verifyConcealed() }, conceal: { try verifyConcealed() }, reorder: reorder)
  }

  static func deferAutomaticPlacementFailure(_ error: Error, repair: inout HiddenSourceRepair?) -> Bool {
    guard let error = error as? NativeMenuActionError,
      [.inputNotIdle, .inputInterrupted, .placementInterrupted, .inventoryUnavailable].contains(error),
      var pending = repair else { return false }
    pending.deferTransientFailure()
    repair = pending
    return true
  }

  func applySavedLayout(restoringToMenuBar key: String? = nil, recovering: Bool = false) {
    runLayoutOperation(recovering: recovering) {
      try await self.applyAndConceal(restoringToMenuBar: Set(key.map { [$0] } ?? []))
    }
  }

  private func runLayoutOperation(recovering: Bool,
    operation: @escaping @MainActor () async throws -> Void) {
    guard canEdit else { return }
    let shouldRecover = recovering || launchRestoreRunning
    attemptedLaunchRestore = true
    message = L("Applying placements…")
    runOperation(revealOnFailure: false, diagnosticContext: "layout") {
      self.recoveringLayout = shouldRecover
      defer { self.recoveringLayout = false }
      do { try await operation() }
      catch {
        self.retryLayoutRecovery(after: error, recovering: shouldRecover)
        throw error
      }
    }
  }

  private func retryLayoutRecovery(after error: Error, recovering: Bool) {
    guard recovering, !Task.isCancelled, permissionGranted, !recoveryRequired,
      let error = error as? NativeMenuActionError,
      [.inputNotIdle, .inputInterrupted, .placementInterrupted, .inventoryUnavailable].contains(error) else { return }
    reapplyNotBefore = Date().addingTimeInterval(3)
    modelLog.notice("temporary layout failure; retrying after input and inventory settle: \(error.localizedDescription, privacy: .public)")
  }

  private func freshOperationInventory(preservingConcealment: Bool = false) async throws {
    let snapshot = await Task.detached(priority: .userInitiated) {
      AccessibilityInventoryScanner().scan()
    }.value
    try Task.checkCancellation()
    if preservingConcealment {
      let granted = currentAccessibilityPermission() && snapshot.permission == .granted
      if permissionGranted != granted { permissionGranted = granted }
      guard granted, snapshot.completeness == .complete,
        Date().timeIntervalSince(snapshot.capturedAt) <= 3 else {
        scanComplete = false
        throw NativeMenuActionError.inventoryUnavailable
      }
    }
    accept(snapshot)
    try Task.checkCancellation() // identity review or a failed save cancels recovery
    guard permissionGranted, !recoveryRequired else {
      throw AppError.message(message ?? L("A complete, fresh menu-bar inventory is unavailable. Refresh and try again."))
    }
    guard scanComplete, Date().timeIntervalSince(snapshot.capturedAt) <= 3 else {
      throw NativeMenuActionError.inventoryUnavailable
    }
  }

  private func applyAndConceal(restoringToMenuBar keys: Set<String>, layout requested: SavedLayout? = nil) async throws {
    let layout = requested ?? self.layout
    reapplyNotBefore = nil
    try await native.prepareLayout(keepingVisible: Set(layout.items.filter { $0.placement == .menuBar }.map(\.id)))
    try await freshOperationInventory()
    for key in keys {
      if let item = liveItem(key), native.isClipped(item.observation) {
        throw AppError.message("\(name(for: key)): \(L("macOS has clipped this item. Free some menu-bar space, then retry moving it to Menu Bar."))")
      }
    }
    let placements = layout.items.filter { $0.placement != .menuBar }
      + layout.items.filter { $0.placement == .menuBar }
    var failedSource: ClassifiedSourceItem?
    let warnings = try await Self.applyPlacementsWithFallback(placements,
      move: { saved in
        failedSource = nil
        guard let item = self.liveItem(saved.id), self.isManageable(item) else { return false }
        let hidden = saved.placement != .menuBar
        let behind = self.native.isBehindBoundary(item)
        modelLog.notice("apply \(saved.id, privacy: .public) toHidden=\(hidden) behind=\(String(describing: behind), privacy: .public) clipped=\(self.native.isClipped(item.observation))")
        if hidden && self.native.isClipped(item.observation) { return false }
        // Already-clipped, unassigned items cannot be dragged. The native guard
        // still rejects any visible protected/unassigned item in the hidden section.
        if hidden ? behind == true : behind != true { return false }
        do { try await self.native.move(item, toHidden: hidden) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NativeMenuActionError {
          self.recordOperationFailure(error, context: "placement",
            affectedBundles: item.observation.bundleIdentifier.map { [$0] } ?? [])
          throw error
        }
        catch {
          self.recordOperationFailure(error, context: "placement",
            affectedBundles: item.observation.bundleIdentifier.map { [$0] } ?? [])
          failedSource = item
          throw AppError.message("\(self.name(for: saved.id)): \(error.localizedDescription)")
        }
        return true
    }, refresh: {
      try await self.freshOperationInventory()
      if let original = failedSource, let key = original.identity.persistentKey {
        let identityChanged: Bool
        if let current = self.liveItem(key) {
          identityChanged = !NativeMenuBarController.preservesSourceIdentity(original: original, current: current)
        } else {
          guard let window = original.observation.statusWindowIdentifier,
            let windows = self.lastCompleteStatusWindows else { throw NativeMenuActionError.inventoryUnavailable }
          identityChanged = windows.contains {
            $0.windowIdentifier == window && $0.processIdentifier == original.observation.processIdentifier
          }
        }
        if identityChanged {
          self.recordReveal(.identityReview,
            affectedBundles: original.observation.bundleIdentifier.map { [$0] } ?? [])
          throw AppError.message(L("Menu-bar items changed. Review the layout before hiding again."))
        }
      }
    }, repairBoundary: {
      try await self.native.prepareLayout(keepingVisible: Set(layout.items.filter { $0.placement == .menuBar }.map(\.id)))
    }, conceal: {
      let hidden = Set(layout.items.filter { $0.placement != .menuBar }.map(\.id))
      if !hidden.isEmpty { try await self.native.conceal(allowedKeys: hidden) }
      else { self.native.reveal() }
      self.concealed = self.native.isConcealed
    }, reorder: { try await self.synchronizeMenuBarOrder(self.menuBarItems(in: layout)) })
    concealed = native.isConcealed
    message = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
  }

  static func applyPlacementsWithFallback(_ placements: [SavedItem],
    move: (SavedItem) async throws -> Bool,
    refresh: () async throws -> Void,
    repairBoundary: () async throws -> Void,
    conceal: () async throws -> Void,
    reorder: () async throws -> Void) async throws -> [String] {
    var warnings: [String] = []
    var failedKeys = Set<String>()
    var next = 0
    while next < placements.count {
      try Task.checkCancellation()
      let saved = placements[next]
      next += 1
      guard !failedKeys.contains(saved.id) else { continue }
      let moved: Bool
      do { moved = try await move(saved) }
      catch is CancellationError { throw CancellationError() }
      catch let error as NativeMenuActionError { throw error }
      catch {
        // A refused source must not undo other placements, but its failed move may remove our boundary.
        try Task.checkCancellation()
        try await refresh()
        try await repairBoundary()
        try await refresh()
        warnings.append(error.localizedDescription)
        failedKeys.insert(saved.id)
        // A repaired divider can expose earlier placements; each refused source causes at most one restart.
        next = 0
        continue
      }
      if moved { try await refresh() }
    }
    try Task.checkCancellation()
    try await conceal()
    try Task.checkCancellation()
    do { try await reorder() }
    catch is CancellationError { throw CancellationError() }
    catch { warnings.append(error.localizedDescription) }
    return warnings
  }

  static func deliverActivationOnce(activate: () async throws -> Void,
    cleanupUndelivered: () -> Void) async throws {
    try Task.checkCancellation()
    do { try await activate() }
    catch {
      // These errors are emitted only by checks before the first AX/pointer delivery.
      if !Task.isCancelled, let failure = error as? NativeMenuActionError,
        [.inputNotIdle, .inventoryUnavailable].contains(failure) {
        cleanupUndelivered()
      }
      throw error
    }
  }

  func activate(_ item: ClassifiedSourceItem, secondary: Bool = false) {
    guard canEdit, isManageable(item) else { return }
    let owner = NSRunningApplication(processIdentifier: item.observation.processIdentifier)
    // A previous panel's lifetime must never restore this new interaction.
    cancelPanelWatch()
    runOperation(restoreSettingsFocus: false, revealOnFailure: false, showSettingsOnFailure: true,
      diagnosticContext: "activation", affectedBundles: item.observation.bundleIdentifier.map { [$0] } ?? []) {
      self.message = nil
      if self.native.hasPendingActivation { try await self.returnPromotedItem() }
      try await self.native.waitForActivationReadiness(item, secondary: secondary)
      let prepared: ClassifiedSourceItem
      do { prepared = try await self.native.prepareActivation(item) }
      catch {
        // No activation was delivered, so a partially promoted source can return safely.
        self.watchPanel(of: 0, opened: [], dismissed: true)
        throw error
      }
      let pid = item.observation.processIdentifier
      let interaction = NativeMenuInteraction(processIdentifier: pid)
      var backgroundObservation = false
      defer { if !backgroundObservation { interaction?.cancel() } }
      var responseTimedOut = false
      var cleanupScheduled = false
      do {
        try await Self.deliverActivationOnce(activate: {
          try await self.native.activatePrepared(prepared, secondary: secondary)
        }, cleanupUndelivered: {
          cleanupScheduled = self.watchPanel(of: 0, opened: [], dismissed: true)
        })
      }
      catch NativeMenuActionError.responseTimedOut { responseTimedOut = true }
      catch {
        if !cleanupScheduled {
          backgroundObservation = self.watchPanel(of: pid, opened: interaction?.observedWindowIDs ?? [],
            interaction: interaction, owner: owner)
        }
        throw error
      }
      let dismissed = await interaction?.waitForDismissal(retainingObservationOnTimeout: true) == true
      try Task.checkCancellation()
      if responseTimedOut && !dismissed && interaction?.observedInterface != true {
        backgroundObservation = self.watchPanel(of: pid, opened: interaction?.observedWindowIDs ?? [],
          interaction: interaction, owner: owner)
        throw NativeMenuActionError.responseTimedOut
      }
      if dismissed {
        try await self.returnPromotedItem()
      } else {
        self.message = L("This app stays visible while its panel is in use. Open TrayNook again to return it to the hidden section.")
        backgroundObservation = self.watchPanel(of: pid,
          opened: interaction?.observedWindowIDs ?? [], interaction: interaction, owner: owner)
      }
    }
  }

  /// Once the panel the activation opened is gone, return the item on its own
  /// so the next click on the tray icon opens the dropdown directly.
  private func returnPromotedItem() async throws {
    do { try await native.restoreActivation() }
    catch {
      if NativeMenuBarController.shouldRetrySelectedReturn(after: error) {
        watchPanel(of: 0, opened: [], dismissed: true)
      }
      throw error
    }
  }

  @discardableResult private func watchPanel(of pid: Int32, opened: Set<UInt32>,
    interaction: NativeMenuInteraction? = nil, owner: NSRunningApplication? = nil,
    dismissed: Bool = false) -> Bool {
    guard !Task.isCancelled else { return false }
    cancelPanelWatch()
    guard native.hasPendingActivation,
      dismissed || interaction?.observedInterface == true || !opened.isEmpty || owner != nil else { return false }
    panelWatch = Task { [weak self] in
      defer { interaction?.cancel() }
      var dismissed = dismissed
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) }
        catch { return }
        guard let self, !Task.isCancelled, self.native.hasPendingActivation else { return }
        if !dismissed {
          if owner?.isTerminated == true { dismissed = true }
          else if let interaction { dismissed = interaction.dismissalObserved() }
          else if !opened.isEmpty, let current = NativeMenuInteraction.visibleWindowIDs(of: pid) {
            dismissed = current.isDisjoint(with: opened)
          }
        }
        guard dismissed else { continue }
        do {
          try await NativeMenuBarController.retrySelectedReturn(isPending: { [weak self] in
            self?.native.hasPendingActivation == true
          }, restore: { [weak self] in
            guard let self, !Task.isCancelled else { throw CancellationError() }
            guard !self.busy, !self.dropdownShown else { throw NativeMenuActionError.inputNotIdle }
            modelLog.notice("interface closed; returning the promoted item")
            var outcome: Result<Void, Error>?
            self.runOperation(restoreSettingsFocus: false, revealOnFailure: false) {
              do {
                try await self.native.restoreActivation()
                self.message = nil
                outcome = .success(())
              } catch {
                outcome = .failure(error)
                throw error
              }
            }
            guard let task = self.operationTask else { throw NativeMenuActionError.inputNotIdle }
            await task.value
            try Task.checkCancellation()
            guard let outcome else { throw CancellationError() }
            try outcome.get()
          })
        } catch {
          // The operation already reports permanent errors; another explicit action can retry.
        }
        return
      }
    }
    return true
  }

  private func cancelPanelWatch() {
    panelWatch?.cancel()
    panelWatch = nil
  }

  private func runOperation(restoreSettingsFocus: Bool = true, revealOnFailure: Bool = true, deactivateApp: Bool = true,
    showSettingsOnFailure: Bool = false,
    diagnosticContext: String = "operation", affectedBundles: [String] = [],
    completion: (@MainActor () -> Void)? = nil,
    _ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    let previousReveal = lastReveal
    operationInitialReveal = previousReveal
    let affected = affectedBundles + (native.pendingActivationBundleIdentifier.map { [$0] } ?? [])
    busy = true
    cancelScan()
    closeDropdown?()
    let wasActive = NSApp.isActive
    if deactivateApp { NSApp.deactivate() }
    operationTask = Task {
      var failed = false
      do { try await operation() }
      catch is CancellationError { if revealOnFailure { native.reveal() } }
      catch NativeMenuActionError.inputNotIdle {
        failed = true
        if lastReveal == previousReveal {
          recordOperationFailure(NativeMenuActionError.inputNotIdle, context: diagnosticContext, affectedBundles: affected)
        }
        message = NativeMenuActionError.inputNotIdle.localizedDescription
      }
      catch {
        failed = true
        if lastReveal == previousReveal {
          recordOperationFailure(error, context: diagnosticContext, affectedBundles: affected)
        }
        preservingRevealReason {
          if revealOnFailure { native.reveal() }
          message = error.localizedDescription
          modelLog.error("operation failed: \(error.localizedDescription, privacy: .public)")
          if launchRestoreRunning && reapplyNotBefore == nil { modelLog.notice("settings: launch restore failed"); showSettings?() }
        }
      }
      launchRestoreRunning = false
      concealed = native.isConcealed
      busy = false
      operationInitialReveal = nil
      operationTask = nil
      if !Task.isCancelled { applyPendingMenuBarOrder() }
      if deactivateApp && restoreSettingsFocus && wasActive { NSApp.activate(ignoringOtherApps: true) }
      refresh()
      if failed && showSettingsOnFailure && !Task.isCancelled {
        queuedDropdown = nil
        preservingRevealReason { showSettings?() }
      }
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

  /// Reorder one lane's keys, keeping the rest of the layout in place.
  func setOrder(_ keys: [String], undoable: Bool) {
    guard canEdit else { return }
    let byKey = Dictionary(layout.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let lane = Set(keys)
    var cursor = keys.makeIterator()
    var next = layout
    next.items = next.items.compactMap { lane.contains($0.id) ? cursor.next().flatMap { byKey[$0] } : $0 }
    guard next.items.count == layout.items.count else { return }
    replaceLayout(next, undoable: undoable, applyingMenuBarOrder: true)
  }

  private func menuBarItems(in layout: SavedLayout) -> [ClassifiedSourceItem] {
    layout.items.filter { $0.placement == .menuBar }
      .compactMap { liveItem($0.id) }.filter { isManageable($0) }
  }

  private func applyPendingMenuBarOrder() {
    guard !busy, let ordered = pendingMenuBarOrder else { return }
    pendingMenuBarOrder = nil
    attemptedLaunchRestore = true
    message = nil
    runOperation(revealOnFailure: false, deactivateApp: false) {
      if self.native.hasPendingActivation { try await self.native.restoreActivation() }
      try await self.synchronizeMenuBarOrder(ordered)
    }
  }

  private func synchronizeMenuBarOrder(_ ordered: [ClassifiedSourceItem]) async throws {
    guard ordered.count > 1 else { return }
    do {
      if let applyMenuBarOrder { try await applyMenuBarOrder(ordered) }
      else { try await native.reorderMenuBarItems(ordered) }
    } catch is CancellationError { throw CancellationError() }
    catch {
      recordOperationFailure(error, context: "menuBarOrder",
        affectedBundles: ordered.compactMap { $0.observation.bundleIdentifier })
      throw error
    }
  }

  /// Mouse movement edits a local preview; persist one final drop and one Undo.
  @discardableResult func commitPreviewMove(_ key: String, to placement: Placement, before anchor: String? = nil) -> Bool {
    guard canEdit, let source = liveItem(key), isManageable(source),
      let previousPlacement = layout.items.first(where: { $0.id == key })?.placement else { return false }
    if let anchor {
      guard let destination = liveItem(anchor),
        layout.items.contains(where: { $0.id == anchor && $0.placement == placement }),
        placement == .menuBar || isManageable(destination) else { return false }
    }
    guard let next = layout.moving(key, to: placement, before: anchor) else { return false }
    guard next != layout else { return true }
    guard replaceLayout(next, undoable: true,
      applyingMenuBarOrder: previousPlacement == placement && placement == .menuBar) else { return false }
    if previousPlacement != placement {
      let visiblePlacement: NativeMenuBarController.VisiblePlacement = anchor.flatMap { liveItem($0) }
        .map { .before($0) } ?? .beforeLauncher
      applyPlacementChange(key, from: previousPlacement, item: source, visiblePlacement: visiblePlacement)
    }
    return true
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

  @discardableResult private func replaceLayout(_ next: SavedLayout, undoable: Bool,
    applyingMenuBarOrder: Bool = false) -> Bool {
    let previous = layout
    guard previous != next else { return true }
    layout = next
    guard persist() else { return false }
    if undoable {
      undoManager.registerUndo(withTarget: self) { target in
        MainActor.assumeIsolated {
          if !applyingMenuBarOrder { target.reveal() }
          if target.replaceLayout(previous, undoable: true, applyingMenuBarOrder: applyingMenuBarOrder),
            !applyingMenuBarOrder {
            target.message = L("Layout restored. Apply Saved Layout to update native positions.")
          }
        }
      }
      undoManager.setActionName(L("Change Layout"))
    }
    if applyingMenuBarOrder {
      let ordered = menuBarItems(in: next)
      if ordered.count > 1,
        ordered.compactMap(\.identity.persistentKey) != menuBarItems(in: previous).compactMap(\.identity.persistentKey) {
        pendingMenuBarOrder = ordered
        applyPendingMenuBarOrder()
      }
    }
    return true
  }

  @discardableResult private func persist() -> Bool {
    guard !recoveryRequired else { return false }
    do { try store?.save(layout); return true }
    catch {
      reveal(reason: .operationFailure)
      recordReveal(.operationFailure, failure: "layoutSaveFailed")
      recoveryRequired = true
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
      let status = try loginItemStatus.setEnabled(enabled)
      loginEnabled = loginItemStatus.isEnabled
      if status == .requiresApproval {
        message = L("Approve TrayNook in System Settings → General → Login Items.")
      }
    } catch {
      loginEnabled = loginItemStatus.isEnabled
      message = L("Could not change Launch at Login. Check System Settings → General → Login Items.")
    }
  }

  func refreshLoginStatus() {
    _ = loginItemStatus.refresh()
    if loginEnabled != loginItemStatus.isEnabled { loginEnabled = loginItemStatus.isEnabled }
  }

  private func observeApplicationChanges() {
    guard applicationObservers.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      applicationObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        MainActor.assumeIsolated {
          guard let self else { return }
          self.observationRevision &+= 1
          if let bundle { self.applicationIcons.invalidate(bundle: bundle) }
          else { self.applicationIcons.invalidateAll() }
          self.objectWillChange.send()
        }
      })
    }
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
      NSWorkspace.didRenameVolumeNotification] {
      applicationObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.invalidateApplicationIcons() }
      })
    }
  }

  func diagnosticsReport() -> DiagnosticsReport {
    let info = Bundle.main.infoDictionary ?? [:]
    return DiagnosticsReport(version: info["CFBundleShortVersionString"] as? String ?? "development",
      build: info["CFBundleVersion"] as? String ?? "0",
      macOS: ProcessInfo.processInfo.operatingSystemVersionString,
      permissionGranted: permissionGranted, scanComplete: scanComplete, recoveryRequired: recoveryRequired,
      concealed: concealed, screenRecordingGranted: screenRecordingGranted, lastReveal: lastReveal,
      reapplyNotBefore: reapplyNotBefore, recoveringLayout: recoveringLayout, busy: busy, scanning: scanning,
      nativeBusy: native.isBusy, incompleteScans: incompleteScans, unsafeScans: unsafeScans,
      hasPendingActivation: native.hasPendingActivation,
      pendingActivationBundle: native.pendingActivationBundleIdentifier,
      panelWatch: panelWatch != nil, dropdownShown: dropdownShown,
      pendingPlacementCount: pendingPlacementKeys.count, automaticPlacementCount: automaticPlacementKeys.count,
      pendingPlacementBundles: pendingPlacementKeys.map(Self.bundle(ofKey:)),
      automaticPlacementBundles: automaticPlacementKeys.map(Self.bundle(ofKey:)),
      hiddenSourceRepairs: hiddenSourceRepairs.values.map {
        DiagnosticsReport.Repair(bundleIdentifier: $0.source.observation.bundleIdentifier,
          attempts: $0.attempts, notBefore: $0.notBefore)
      })
  }

  func copyDiagnostics() {
    let summary = diagnosticsReport().text
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(summary, forType: .string)
    message = L("Diagnostics copied. Includes affected-app bundle identifiers; no full app inventory, item labels, window titles, or images.")
  }

  /// Exercises launch failure handling without native moves or saved-state writes.
  static func verifyLaunchRecoveryBehavior(native: NativeMenuBarController) async -> Bool {
    let onReveal = native.onReveal
    let onExternalReveal = native.onExternalReveal
    defer {
      native.onReveal = onReveal
      native.onExternalReveal = onExternalReveal
    }

    func launchModel() -> AppModel {
      let model = AppModel(native: native, store: nil)
      model.permissionGranted = true
      model.scanComplete = true
      model.layout.items = [SavedItem(id: "example.fixture", placement: .dropdown)]
      model.launchRestoreRunning = true
      return model
    }

    func finish(_ model: AppModel) async -> Bool {
      guard let task = model.operationTask else { return false }
      await task.value
      model.cancelScan()
      return !model.busy
    }

    for error in [NativeMenuActionError.inventoryUnavailable, .inputNotIdle,
      .inputInterrupted, .placementInterrupted] {
      let model = launchModel()
      var settingsOpened = false
      model.showSettings = { [weak model] in
        settingsOpened = true
        if model?.busy == true { model?.reveal() }
      }
      model.runLayoutOperation(recovering: false) {
        if error == .inventoryUnavailable {
          try Task.checkCancellation()
          model.accept(InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .incomplete,
            items: [], warnings: [],
            metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0)))
          try Task.checkCancellation()
        }
        throw error
      }
      guard await finish(model), !settingsOpened, let retry = model.reapplyNotBefore else {
        fputs("TRAYNOOK_LAUNCH_RECOVERY_NOT_RETRIED\n", stderr)
        return false
      }
      if error == .inventoryUnavailable {
        guard !model.scanComplete, !model.takeLayoutRecovery(now: .distantFuture) else {
          fputs("TRAYNOOK_LAUNCH_RECOVERY_USED_INCOMPLETE_SCAN\n", stderr)
          return false
        }
        model.accept(InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
          items: [], warnings: [],
          metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0)))
      }
      guard !model.takeLayoutRecovery(now: retry.addingTimeInterval(-1)),
        model.takeLayoutRecovery(now: retry),
        !model.takeLayoutRecovery(now: .distantFuture) else {
        fputs("TRAYNOOK_LAUNCH_RECOVERY_NOT_RETRIED\n", stderr)
        return false
      }
      var retried = false
      model.runLayoutOperation(recovering: true) { retried = true }
      guard await finish(model), retried, model.reapplyNotBefore == nil, !settingsOpened else {
        fputs("TRAYNOOK_LAUNCH_RECOVERY_DID_NOT_COMPLETE\n", stderr)
        return false
      }
    }

    let overlapping = launchModel()
    overlapping.runLayoutOperation(recovering: true) {
      _ = try NativeMenuBarController.checkedHiddenSide(
        ItemFrame(x: 1108, y: 6.5, width: 24, height: 24),
        boundary: ItemFrame(x: 1129, y: 7.5, width: 2, height: 22))
    }
    guard await finish(overlapping), let retry = overlapping.reapplyNotBefore,
      !overlapping.takeLayoutRecovery(now: retry.addingTimeInterval(-1)),
      overlapping.takeLayoutRecovery(now: retry) else {
      fputs("TRAYNOOK_BOUNDARY_OVERLAP_DROPPED_RECOVERY\n", stderr)
      return false
    }

    let cancelled = launchModel()
    cancelled.runLayoutOperation(recovering: false) {
      cancelled.reveal()
      throw NativeMenuActionError.inventoryUnavailable
    }
    guard await finish(cancelled), cancelled.reapplyNotBefore == nil,
      cancelled.lastReveal?.reason == .userReveal else {
      fputs("TRAYNOOK_CANCELLED_LAUNCH_RECOVERY_RETRIED\n", stderr)
      return false
    }

    let failed = launchModel()
    var settingsOpened = false
    var originalFailure: DiagnosticsReport.Event?
    failed.showSettings = { [weak failed] in
      settingsOpened = true
      originalFailure = failed?.lastReveal
      if failed?.busy == true { failed?.reveal() }
    }
    failed.runLayoutOperation(recovering: false) { throw NativeMenuActionError.responseTimedOut }
    guard await finish(failed), failed.reapplyNotBefore == nil, settingsOpened,
      failed.lastReveal == originalFailure, originalFailure?.reason == .operationFailure,
      originalFailure?.failure == "layout.responseTimedOut" else {
      fputs("TRAYNOOK_PERMANENT_LAUNCH_FAILURE_RETRIED\n", stderr)
      return false
    }
    let revalidation = launchModel()
    let original = DiagnosticsReport.Event(reason: .operationFailure,
      timestamp: Date(timeIntervalSince1970: 1_794_000_000), failure: "placement.failed",
      affectedBundles: ["example.refusing"])
    revalidation.runOperation(deactivateApp: false) {
      revalidation.lastReveal = original
      _ = revalidation.acceptScanStatus(InventorySnapshot(capturedAt: Date(), permission: .granted,
        completeness: .incomplete, items: [], warnings: [],
        metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0)))
      throw AppError.message("Private item label must not enter diagnostics")
    }
    guard await finish(revalidation), revalidation.lastReveal == original,
      !revalidation.diagnosticsReport().text.contains("Private item label") else {
      fputs("TRAYNOOK_DIAGNOSTICS_LOST_ORIGINAL_FAILURE\n", stderr)
      return false
    }
    let feedbackCases: [(Error?, Bool, Bool)] = [
      (NativeMenuActionError.inputNotIdle, true, true),
      (AppError.message("Activation feedback fixture"), true, true),
      (CancellationError(), true, false),
      (nil, true, false),
      (AppError.message("Background feedback fixture"), false, false),
    ]
    for (error, presentsFailure, shouldPresent) in feedbackCases {
      let model = AppModel(native: native, store: nil)
      var presentations = 0
      var presentedAfterCleanup = true
      var presentedMessage: String?
      var queuedDropdownOpened = false
      model.showSettings = { [weak model] in
        presentations += 1
        presentedAfterCleanup = model?.busy == false && model?.operationTask == nil
        presentedMessage = model?.message
      }
      model.runOperation(revealOnFailure: false, deactivateApp: false,
        showSettingsOnFailure: presentsFailure) {
        if shouldPresent { model.openDropdown { queuedDropdownOpened = true } }
        if let error { throw error }
      }
      guard await finish(model), presentations == (shouldPresent ? 1 : 0),
        presentedAfterCleanup, !queuedDropdownOpened,
        !shouldPresent || presentedMessage == error?.localizedDescription else {
        fputs("TRAYNOOK_ACTIVATION_FAILURE_FEEDBACK_FAILED\n", stderr)
        return false
      }
    }
    return true
  }

  /// Runs only in --smoke-test, before the actual UI model is created. No TCC
  /// requests or data writes: /dev/null cannot contain the test layout file.
  static func verifyRecoveryBehavior(native: NativeMenuBarController) -> Bool {
    let failing = AppModel(native: native,
      store: LayoutStore(url: URL(fileURLWithPath: "/dev/null/traynook-layout.json")))
    // Loading an invalid parent is already a recovery error. Clear it here
    // so this check exercises a failed write rather than the load guard.
    failing.recoveryRequired = false
    failing.message = nil
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
    guard navigation.selectedTab == 0, !navigation.attemptedLaunchRestore else {
      fputs("TRAYNOOK_PERMISSION_CHANGED_SETTINGS_TAB\n", stderr)
      return false
    }
    navigation.selectedTab = 2
    navigation.accept(denied)
    guard navigation.selectedTab == 2, !navigation.attemptedLaunchRestore else { return false }
    var dropdownOpened = false
    navigation.openDropdown { dropdownOpened = true }
    guard dropdownOpened, navigation.dropdownShown, !navigation.busy,
      !navigation.canEdit else { return false }
    navigation.dropdownClosed()
    let granted = InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
      items: [], warnings: [], metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0))
    guard navigation.acceptScanStatus(granted), navigation.selectedTab == 2 else { return false }
    let stable = AppModel(native: native, store: nil)
    let windows = [StatusWindowState(processIdentifier: 10, windowIdentifier: 1,
      frame: ItemFrame(x: -100, y: 0, width: 24, height: 24), isOnscreen: false)]
    stable.accept(InventorySnapshot(capturedAt: Date(), permission: .granted, items: [],
      statusWindows: windows, warnings: [], metrics: granted.metrics))
    stable.layout.items = [SavedItem(id: "example.fixture", placement: .dropdown)]
    stable.concealed = true
    let stableIncomplete = InventorySnapshot(capturedAt: Date(), permission: .granted,
      completeness: .incomplete, items: [], statusWindows: windows, warnings: [], metrics: granted.metrics)
    for _ in 0..<8 {
      guard !stable.acceptScanStatus(stableIncomplete), stable.concealed,
        !stable.canEdit, stable.reapplyNotBefore == nil else {
        fputs("TRAYNOOK_UNCHANGED_WINDOWS_REVEALED\n", stderr)
        return false
      }
    }
    navigation.reveal()
    guard navigation.attemptedLaunchRestore else { return false }
    let recovering = AppModel(native: native, store: nil)
    recovering.layout.items = [SavedItem(id: "example.fixture", placement: .dropdown)]
    recovering.concealed = true
    let incomplete = InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .incomplete,
      items: [], warnings: [], metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0))
    for _ in 0..<3 {
      guard !recovering.acceptScanStatus(incomplete), recovering.concealed,
        recovering.reapplyNotBefore == nil else { return false }
    }
    guard !recovering.acceptScanStatus(incomplete), !recovering.concealed,
      let retry = recovering.reapplyNotBefore,
      !recovering.takeLayoutRecovery(now: .distantFuture) else {
      fputs("TRAYNOOK_INVENTORY_RECOVERY_NOT_SCHEDULED\n", stderr)
      return false
    }
    guard !recovering.acceptScanStatus(incomplete), recovering.reapplyNotBefore == retry else { return false }
    let complete = InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
      items: [], warnings: [], metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0))
    guard recovering.acceptScanStatus(complete),
      !recovering.takeLayoutRecovery(now: retry.addingTimeInterval(-1)),
      recovering.takeLayoutRecovery(now: retry),
      !recovering.takeLayoutRecovery(now: .distantFuture) else { return false }
    recovering.environmentChanged("smoke check")
    recovering.reveal()
    guard recovering.reapplyNotBefore == nil else { return false }
    recovering.environmentChanged("smoke check")
    native.onExternalReveal?()
    guard recovering.reapplyNotBefore == nil else { return false }

    // A sibling recreated during the outage must still require identity review.
    func siblings(firstWindow: UInt32) -> [ClassifiedSourceItem] {
      IdentityAssessor().classify([firstWindow, 2].enumerated().map { index, window in
        RawSourceItemObservation(runtimeID: "10:\(index)", processIdentifier: 10,
          bundleIdentifier: "example.pair", applicationName: "Fixture", role: "AXMenuBarItem",
          frame: ItemFrame(x: 1100 + Double(index) * 24, y: 0, width: 24, height: 24), actions: ["AXPress"],
          metadata: LiveAccessibilityMetadata(), observedOrder: index, statusWindowIdentifier: window)
      })
    }
    recovering.layout.items = [SavedItem(id: "example.pair#w0", placement: .dropdown),
      SavedItem(id: "example.pair#w1", placement: .alwaysHidden)]
    recovering.previousItems = siblings(firstWindow: 1)
    recovering.reapplyNotBefore = .distantPast
    recovering.accept(InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
      items: siblings(firstWindow: 3), warnings: [],
      metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 2)))
    guard recovering.reapplyNotBefore == nil else { return false }

    let hiddenSource = RawSourceItemObservation(runtimeID: "10:0", processIdentifier: 10,
      bundleIdentifier: "example.hidden", applicationName: "Hidden fixture", role: "AXMenuBarItem",
      frame: ItemFrame(x: -100, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 0, isOnscreen: false, statusWindowIdentifier: 10)
    let returnedSource = RawSourceItemObservation(runtimeID: "20:0", processIdentifier: 20,
      bundleIdentifier: "example.bar", applicationName: "Menu Bar fixture", role: "AXMenuBarItem",
      frame: ItemFrame(x: 900, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 1, isOnscreen: false, statusWindowIdentifier: 20)
    for alreadyKnown in [true, false] {
      recovering.layout.items = [SavedItem(id: "example.hidden", placement: .dropdown)]
      if alreadyKnown { recovering.layout.items.append(SavedItem(id: "example.bar")) }
      recovering.previousItems = IdentityAssessor().classify([hiddenSource])
      recovering.reapplyNotBefore = .distantPast
      recovering.accept(InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
        items: IdentityAssessor().classify([hiddenSource, returnedSource]), warnings: [],
        metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 2)))
      guard recovering.layout.items.first(where: { $0.id == "example.bar" })?.placement == .menuBar,
        recovering.takeLayoutRecovery(now: .distantFuture) else {
        fputs("TRAYNOOK_NEW_ITEM_DROPPED_RECOVERY\n", stderr)
        return false
      }
    }

    // Recovery is consumed before attempting native work. A transient failure
    // at any stage must re-arm it, while user actions and permanent errors stop.
    for error in [NativeMenuActionError.inputNotIdle, .inputInterrupted, .inventoryUnavailable] {
      recovering.retryLayoutRecovery(after: error, recovering: true)
      guard let retry = recovering.reapplyNotBefore,
        !recovering.takeLayoutRecovery(now: retry.addingTimeInterval(-1)),
        recovering.takeLayoutRecovery(now: retry) else { return false }
      recovering.retryLayoutRecovery(after: error, recovering: false)
      guard recovering.reapplyNotBefore == nil else { return false }
    }
    recovering.retryLayoutRecovery(after: NativeMenuActionError.responseTimedOut, recovering: true)
    recovering.retryLayoutRecovery(after: CancellationError(), recovering: true)
    recovering.retryLayoutRecovery(after: AppError.message("placement mismatch"), recovering: true)
    guard recovering.reapplyNotBefore == nil else { return false }
    recovering.permissionGranted = false
    recovering.retryLayoutRecovery(after: NativeMenuActionError.inventoryUnavailable, recovering: true)
    guard recovering.reapplyNotBefore == nil else { return false }
    recovering.permissionGranted = true
    recovering.recoveryRequired = true
    recovering.retryLayoutRecovery(after: NativeMenuActionError.inventoryUnavailable, recovering: true)
    guard recovering.reapplyNotBefore == nil else { return false }
    recovering.recoveryRequired = false
    recovering.retryLayoutRecovery(after: NativeMenuActionError.inventoryUnavailable, recovering: true)
    recovering.reveal()
    guard recovering.reapplyNotBefore == nil else { return false }

    // Replacing an activation with no observed windows must retire the prior
    // watcher, just like either model-initiated or native-initiated reveals.
    // These no-op tasks never query windows or initiate a native interaction.
    func watcherCancelled(by action: () -> Void) -> Bool {
      let previous = Task { @MainActor in }
      recovering.panelWatch = previous
      action()
      let cancelled = previous.isCancelled && recovering.panelWatch == nil
      previous.cancel()
      recovering.panelWatch = nil
      return cancelled
    }
    guard watcherCancelled(by: { recovering.watchPanel(of: 0, opened: []) }),
      watcherCancelled(by: { recovering.reveal() }),
      watcherCancelled(by: { native.reveal() }),
      watcherCancelled(by: { native.onExternalReveal?() }) else {
      fputs("TRAYNOOK_STALE_PANEL_WATCHER\n", stderr)
      return false
    }
    guard verifyPreviewEditingBehavior(native: native) else {
      fputs("TRAYNOOK_PREVIEW_EDIT_FAILED\n", stderr)
      return false
    }
    return true
  }

  private static func verifyPreviewEditingBehavior(native: NativeMenuBarController) -> Bool {
    let editing = AppModel(native: native, store: nil)
    editing.permissionGranted = true
    editing.scanComplete = true
    let keys = ["example.first", "example.second", "example.third", "com.apple.fixture"]
    editing.items = IdentityAssessor().classify(keys.enumerated().map { index, key in
      RawSourceItemObservation(runtimeID: "\(index):0", processIdentifier: Int32(index + 10),
        bundleIdentifier: key, applicationName: key, role: "AXMenuBarItem",
        frame: ItemFrame(x: 1100 + Double(index) * 24, y: 0, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: index)
    })
    let original = SavedLayout(items: [
      SavedItem(id: keys[0], placement: .dropdown), SavedItem(id: "example.missing", placement: .dropdown),
      SavedItem(id: keys[1], placement: .dropdown), SavedItem(id: keys[2], placement: .dropdown),
      SavedItem(id: keys[3]),
    ])
    editing.layout = original
    var dropdownClosed = false
    editing.closeDropdown = { dropdownClosed = true }
    editing.setPlacement(keys[0], .dropdown)
    guard editing.layout == original, !editing.busy, !editing.undoManager.canUndo,
      !dropdownClosed else {
      editing.operationTask?.cancel()
      fputs("TRAYNOOK_PLACEMENT_NOOP_REFRESHED\n", stderr)
      return false
    }
    guard !editing.commitPreviewMove(keys[3], to: .dropdown),
      !editing.commitPreviewMove("example.unknown", to: .dropdown),
      !editing.commitPreviewMove(keys[0], to: .dropdown, before: "example.missing"),
      editing.layout == original, !editing.undoManager.canUndo,
      editing.commitPreviewMove(keys[2], to: .dropdown),
      !editing.undoManager.canUndo, !editing.busy else { return false }

    editing.undoManager.groupsByEvent = false
    editing.undoManager.beginUndoGrouping()
    let moved = editing.commitPreviewMove(keys[2], to: .dropdown, before: keys[0])
    editing.undoManager.endUndoGrouping()
    guard moved, editing.layout == original.moving(keys[2], to: .dropdown, before: keys[0]),
      editing.undoManager.canUndo, !editing.busy else { return false }
    editing.undoManager.undo()
    guard editing.layout == original, !editing.undoManager.canUndo, editing.undoManager.canRedo else { return false }
    editing.undoManager.redo()
    guard editing.layout == original.moving(keys[2], to: .dropdown, before: keys[0]),
      editing.undoManager.canUndo, !editing.undoManager.canRedo else { return false }
    editing.busy = true
    let before = editing.layout
    guard !editing.commitPreviewMove(keys[0], to: .dropdown, before: keys[2]),
      editing.layout == before else { return false }
    editing.busy = false
    editing.undoManager.beginUndoGrouping()
    defer { editing.undoManager.endUndoGrouping() }
    dropdownClosed = false
    editing.setPlacement(keys[0], .menuBar)
    defer { editing.operationTask?.cancel() }
    guard editing.busy, dropdownClosed, editing.message == nil,
      !editing.canEdit, !editing.canEditPlacement(keys[0]), editing.canEditPlacement(keys[1]),
      editing.pendingPlacementKeys == [keys[0]] else { return false }
    // Another row remains usable, and joins the same serialized operation.
    dropdownClosed = false
    editing.setPlacement(keys[1], .alwaysHidden)
    guard editing.pendingPlacementKeys == [keys[0], keys[1]], !dropdownClosed,
      !editing.canEditPlacement(keys[1]), editing.canEditPlacement(keys[2]),
      editing.layout.items.first(where: { $0.id == keys[0] })?.placement == .menuBar,
      editing.layout.items.first(where: { $0.id == keys[1] })?.placement == .alwaysHidden else { return false }
    let queued = editing.layout
    editing.setPlacement(keys[0], .dropdown)
    guard editing.layout == queued, editing.pendingPlacementKeys == [keys[0], keys[1]] else { return false }
    editing.reveal()
    editing.setPlacement(keys[2], .menuBar)
    return !editing.canEditPlacement(keys[2]) && editing.layout == queued
  }
}

enum AppError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

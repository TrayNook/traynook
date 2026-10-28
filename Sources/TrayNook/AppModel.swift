import AppKit
import ApplicationServices
import Combine
import InventoryIdentityCore
import ServiceManagement

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
  @Published var selectedTab = 0
  @Published var loginEnabled = SMAppService.mainApp.status == .enabled
  @Published var screenRecordingGranted = ProxyImageCapture.isAuthorized
  /// Keyed by runtime ID. Filled only while the dropdown is open; purged after.
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

  func liveItem(_ bundle: String) -> ClassifiedSourceItem? {
    let matches = items.filter { $0.observation.bundleIdentifier == bundle }
    return matches.count == 1 ? matches.first : nil
  }

  func isManageable(_ item: ClassifiedSourceItem) -> Bool {
    guard let bundle = item.observation.bundleIdentifier,
      bundle != ownBundle, !bundle.hasPrefix("com.apple."),
      liveItem(bundle) != nil else { return false }
    return item.identity.status != .ambiguous && item.manageability.status != .protected
  }

  func name(for bundle: String) -> String {
    if let name = liveItem(bundle)?.observation.applicationName { return name }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
      return url.deletingPathExtension().lastPathComponent
    }
    return bundle
  }

  func icon(for bundle: String) -> NSImage {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
  }

  /// Capture the real menu-bar pixels of every dropdown item. Without Screen
  /// Recording this clears the cache and the views fall back to app icons.
  func refreshProxyImages() {
    screenRecordingGranted = ProxyImageCapture.isAuthorized
    guard screenRecordingGranted else { proxyImages = [:]; return }
    var next: [String: ProxyImage] = [:]
    for item in dropdownItems {
      guard let window = native.statusWindowGeometry(for: item.observation) else { continue }
      if let captured = ProxyImageCapture.capture(windowID: window.id, frame: window.frame) {
        next[item.observation.runtimeID] = captured
      } else if let previous = proxyImages[item.observation.runtimeID] {
        next[item.observation.runtimeID] = previous // transient capture failure
      }
    }
    proxyImages = next
  }

  func purgeProxyImages() { proxyImages = [:] }

  func requestScreenRecording() {
    ProxyImageCapture.request()
    message = L("After granting Screen Recording, quit and reopen TrayNook so macOS applies it.")
  }

  func openScreenRecordingSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }

  func status(for saved: SavedItem) -> String {
    let matches = items.filter { $0.observation.bundleIdentifier == saved.id }
    if matches.count > 1 { return L("Multiple items — kept visible") }
    guard let item = matches.first else {
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved.id) == nil
        ? L("App not found") : L("Not running")
    }
    if !isManageable(item) { return L("Protected — kept visible") }
    if saved.placement == .menuBar && native.isClipped(item.observation) {
      return L("Offscreen — menu bar is full")
    }
    if saved.placement != .menuBar && native.isBehindBoundary(item.observation) != true {
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
    pollTask?.cancel(); scanTask?.cancel(); operationTask?.cancel()
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
          self.applySavedLayout()
        }
      }
    }
  }

  func accept(_ snapshot: InventorySnapshot) {
    let wasGranted = permissionGranted
    let firstSnapshot = !hasAcceptedSnapshot
    hasAcceptedSnapshot = true
    loginEnabled = SMAppService.mainApp.status == .enabled
    screenRecordingGranted = ProxyImageCapture.isAuthorized
    concealed = native.isConcealed
    permissionGranted = snapshot.permission == .granted
    scanComplete = snapshot.completeness == .complete
    guard permissionGranted, scanComplete else {
      // A preparation error must reach the operation's completion UI. Only an
      // external reveal cancels that task; failing its own scan is an error.
      if busy { native.reveal(); concealed = false }
      else { reveal(cancelLaunchRestore: false) }
      guard !recoveryRequired else { return }
      if !permissionGranted {
        if firstSnapshot || wasGranted { selectedTab = 1 }
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
      let changes = SnapshotDiffer().changes(from: previousItems, to: observed)
      let known = Set(layout.items.map(\.id))
      let hidden = Set(layout.items.filter { $0.placement != .menuBar }.map(\.id))
      for change in changes where Self.rebindsProcess(change, known: hidden) {
        if let bundle = change.identity?.bundleIdentifier,
          let item = observed.first(where: { $0.observation.runtimeID == change.currentRuntimeID }) {
          native.adoptProcess(bundle: bundle, pid: item.observation.processIdentifier)
        }
      }
      if Self.inventoryRequiresReveal(changes, known: known) {
        reveal()
        message = L("Menu-bar items changed. Review the layout before hiding again.")
      }
    }
    previousItems = observed
    items = observed
    if !recoveryRequired {
      let known = Set(layout.items.map(\.id))
      let additions = observed.compactMap { $0.observation.bundleIdentifier }
        .filter { !known.contains($0) }
      var added = Set<String>()
      for bundle in additions where added.insert(bundle).inserted {
        layout.items.append(SavedItem(id: bundle))
      }
      if !added.isEmpty { persist() }
    }
    if concealed && !canSafelyConceal() {
      reveal()
      message = L("An unassigned or protected item is behind the separator. Items have been revealed.")
    }
  }

  /// A source the user already placed may restart or relaunch without
  /// reopening the hidden section; the controller just adopts its new process.
  static func rebindsProcess(_ change: SnapshotChange, known: Set<String>) -> Bool {
    guard let bundle = change.identity?.bundleIdentifier else { return false }
    switch change.kind {
    case .processReplaced: return true
    case .created: return known.contains(bundle)
    default: return false
    }
  }

  static func inventoryRequiresReveal(_ changes: [SnapshotChange], known: Set<String>) -> Bool {
    changes.contains { change in
      switch change.kind {
      case .ambiguousInventoryChanged: true
      case .created: !known.contains(change.identity?.bundleIdentifier ?? "")
      case .removed, .processReplaced, .orderChanged, .runtimeMetadataChanged: false
      }
    }
  }

  static func inventoryRequiresReveal(previous: [ClassifiedSourceItem], current: [ClassifiedSourceItem],
    known: Set<String>) -> Bool {
    inventoryRequiresReveal(SnapshotDiffer().changes(from: previous, to: current), known: known)
  }

  func reveal(cancelLaunchRestore: Bool = true) {
    if cancelLaunchRestore { attemptedLaunchRestore = true }
    operationTask?.cancel(); native.reveal(); concealed = false
  }

  private func canSafelyConceal() -> Bool {
    items.allSatisfy { item in
      guard let behind = native.isBehindBoundary(item.observation) else { return false }
      guard behind else { return true }
      return isManageable(item) && layout.items.contains {
        $0.id == item.observation.bundleIdentifier && $0.placement != .menuBar
      }
    }
  }

  func toggleConcealment() {
    if concealed { reveal(); return }
    applySavedLayout()
  }

  func openDropdown(_ show: @escaping @MainActor () -> Void) {
    guard !busy else { return }
    if native.hasPendingActivation {
      runOperation(restoreSettingsFocus: false, revealOnFailure: false, completion: show) {
        try await self.native.restoreActivation()
        self.message = nil
      }
      return
    }
    guard !concealed, canEdit else { show(); return }
    runOperation(restoreSettingsFocus: false, completion: show) {
      try await self.applyAndConceal(restoringToMenuBar: nil)
    }
  }

  func setPlacement(_ bundle: String, _ placement: Placement) {
    guard canEdit, let item = liveItem(bundle), isManageable(item) else { return }
    var next = layout
    next.place(bundle, in: placement)
    guard replaceLayout(next, undoable: true) else { return }
    applySavedLayout(restoringToMenuBar: placement == .menuBar ? bundle : nil)
  }

  func applySavedLayout(restoringToMenuBar bundle: String? = nil) {
    guard canEdit else { return }
    attemptedLaunchRestore = true
    message = L("Applying placements…")
    runOperation { try await self.applyAndConceal(restoringToMenuBar: bundle) }
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

  private func applyAndConceal(restoringToMenuBar bundle: String?) async throws {
    try await native.prepareLayout(keepingVisible: Set(layout.items.filter { $0.placement == .menuBar }.map(\.id)))
    try await freshOperationInventory()
    if let bundle, let item = liveItem(bundle), native.isClipped(item.observation) {
      throw AppError.message("\(name(for: bundle)): \(L("macOS has clipped this item. Free some menu-bar space, then retry moving it to Menu Bar."))")
    }
    let placements = layout.items.filter { $0.placement != .menuBar }
      + layout.items.filter { $0.placement == .menuBar }
    for saved in placements {
      try Task.checkCancellation()
      guard let item = liveItem(saved.id), isManageable(item) else { continue }
      let hidden = saved.placement != .menuBar
      let behind = native.isBehindBoundary(item.observation)
      if hidden && native.isClipped(item.observation) { continue }
      // Already-clipped, unassigned items cannot be dragged. The native guard
      // still rejects any visible protected/unassigned item in the hidden section.
      if hidden ? behind == true : behind != true { continue }
      do { try await native.move(item.observation, toHidden: hidden) }
      catch is CancellationError { throw CancellationError() }
      catch { throw AppError.message("\(name(for: saved.id)): \(error.localizedDescription)") }
      try await freshOperationInventory()
    }
    try Task.checkCancellation()
    let hidden = Set(layout.items.filter { $0.placement != .menuBar }.map(\.id))
    if !hidden.isEmpty {
      try await native.conceal(allowedBundleIdentifiers: hidden)
    }
    concealed = native.isConcealed
    message = nil
  }

  func activate(_ item: ClassifiedSourceItem, secondary: Bool = false) {
    guard canEdit, isManageable(item), !native.hasPendingActivation else { return }
    runOperation(restoreSettingsFocus: false, revealOnFailure: false) {
      self.message = nil
      try await self.native.waitForActivationReadiness(item.observation, secondary: secondary)
      let prepared = try await self.native.prepareActivation(item.observation)
      let interaction = NativeMenuInteraction(processIdentifier: item.observation.processIdentifier)
      defer { interaction?.cancel() }
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
      }
      concealed = native.isConcealed
      busy = false
      operationTask = nil
      if restoreSettingsFocus && wasActive { NSApp.activate(ignoringOtherApps: true) }
      refresh()
      if !Task.isCancelled { completion?() }
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

  func reorder(_ bundle: String, delta: Int) {
    guard canEdit, let index = layout.items.firstIndex(where: { $0.id == bundle }) else { return }
    let lane = layout.items.indices.filter { layout.items[$0].placement == layout.items[index].placement }
    guard let position = lane.firstIndex(of: index), lane.indices.contains(position + delta) else { return }
    var next = layout; next.items.swapAt(index, lane[position + delta])
    replaceLayout(next, undoable: true)
  }

  func forget(_ bundle: String) {
    guard !busy, !recoveryRequired,
      !items.contains(where: { $0.observation.bundleIdentifier == bundle }) else { return }
    var next = layout; next.items.removeAll { $0.id == bundle }
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

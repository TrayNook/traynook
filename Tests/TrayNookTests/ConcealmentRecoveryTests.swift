import AppKit
@testable import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Concealment recovery", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct ConcealmentRecoveryTests {
  @Test("Slow AX discovery keeps a verified unchanged native section hidden and pauses editing")
  func slowDiscoveryRetainsVerifiedConcealment() async throws {
    let scanner = HeldConcealmentScanner()
    let metadata = HeldSourceMetadata()
    defer { scanner.release(); metadata.release() }
    let fixture = Fixture(scanner: scanner, sourceStatusSnapshot: metadata.read)
    defer { fixture.close() }
    try await beginSlowScan(fixture, scanner: scanner, metadata: metadata)
    await fixture.model.handleSlowInventory()
    #expect(fixture.model.concealed)
    #expect(!fixture.model.scanComplete)
    #expect(!fixture.model.canEdit)
    #expect(fixture.model.message == NativeMenuActionError.inventoryUnavailable.localizedDescription)
    #expect(fixture.model.reapplyNotBefore == nil)
    #expect(metadata.calls == 1)
    scanner.release()
    try await waitUntil { fixture.model.scanComplete }
    #expect(fixture.model.canEdit)
    #expect(fixture.model.message == nil)
  }

  @Test("An expired AX result is discarded before adoption and uses fresh full-window proof",
    arguments: [false, true])
  func expiredInventoryRequiresFreshNativeProof(changed: Bool) async throws {
    let metadata = HeldSourceMetadata()
    let fixture = Fixture(sourceStatusSnapshot: metadata.read)
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot())
    model.concealed = true
    let original = model.items
    let saved = model.layout
    let observation = try #require(original.first).observation
    let replacement = IdentityAssessor().classify([RawSourceItemObservation(runtimeID: "999:0",
      processIdentifier: 999, bundleIdentifier: observation.bundleIdentifier,
      applicationName: observation.applicationName, role: observation.role,
      frame: ItemFrame(x: 1300, y: 6, width: 24, height: 24), actions: ["AXPress"],
      metadata: observation.metadata, observedOrder: 0, isOnscreen: true, statusWindowIdentifier: 999)])
    metadata.set(fixture.windows + (changed ? [StatusWindowState(processIdentifier: 999,
      windowIdentifier: 999, frame: ItemFrame(x: 1400, y: 6, width: 24, height: 24), isOnscreen: true)] : []))
    let stale = InventorySnapshot(capturedAt: .distantPast, permission: .granted,
      completeness: .complete, items: replacement, statusWindows: fixture.windows, warnings: [],
      metrics: ScanMetrics(durationMilliseconds: 4000, inspectedApplicationCount: 2, sourceItemCount: replacement.count))
    let accepted = await model.acceptLatest(stale)
    #expect(!accepted)
    #expect(model.concealed == !changed)
    #expect(!model.scanComplete)
    #expect(!model.canEdit)
    #expect(model.items == original)
    #expect(model.layout == saved)
    #expect(metadata.calls == 1)
    #expect((model.reapplyNotBefore != nil) == changed)
  }

  @Test("Slow discovery still reveals for changed, missing, late, or permission-denied evidence",
    arguments: ["changed", "missing", "late", "permission"])
  func slowDiscoveryRejectsUnverifiedSources(_ condition: String) async throws {
    let scanner = HeldConcealmentScanner()
    let metadata = HeldSourceMetadata(blocked: condition == "late")
    defer { scanner.release(); metadata.release() }
    var granted = true
    let fixture = Fixture(scanner: scanner, sourceStatusSnapshot: metadata.read,
      currentPermission: { granted })
    defer { fixture.close() }
    try await beginSlowScan(fixture, scanner: scanner, metadata: metadata)
    if condition == "changed" {
      metadata.set(fixture.windows + [StatusWindowState(processIdentifier: 999, windowIdentifier: 999,
        frame: ItemFrame(x: 1400, y: 6, width: 24, height: 24), isOnscreen: true)])
    } else if condition == "missing" { metadata.set(nil) }
    else if condition == "permission" { granted = false }
    await fixture.model.handleSlowInventory()
    #expect(!fixture.model.concealed)
    #expect(!fixture.model.canEdit)
    #expect(fixture.model.reapplyNotBefore != nil)
    if condition == "permission" { #expect(!fixture.model.permissionGranted) }
  }

  @Test("Late watchdog evidence cannot change Reveal, shutdown, or a newer accepted inventory",
    arguments: ["reveal", "stop", "newer"])
  func slowDiscoveryDiscardsInvalidatedEvidence(_ change: String) async throws {
    let scanner = HeldConcealmentScanner()
    let metadata = HeldSourceMetadata(blocked: true)
    defer { scanner.release(); metadata.release() }
    let fixture = Fixture(scanner: scanner, sourceStatusSnapshot: metadata.read)
    defer { fixture.close() }
    try await beginSlowScan(fixture, scanner: scanner, metadata: metadata)
    let pending = Task { await fixture.model.handleSlowInventory() }
    try await waitUntil { metadata.calls == 1 }
    if change == "stop" { fixture.model.stop() }
    else if change == "reveal" { fixture.model.reveal() }
    else { fixture.model.accept(fixture.snapshot()) }
    fixture.model.message = "authoritative newer state"
    metadata.release()
    await pending.value
    #expect(fixture.model.message == "authoritative newer state")
    #expect(fixture.model.reapplyNotBefore == nil)
    #expect(!fixture.model.concealed)
  }

  private func beginSlowScan(_ fixture: Fixture, scanner: HeldConcealmentScanner,
    metadata: HeldSourceMetadata) async throws {
    fixture.model.reveal()
    let baseline = fixture.snapshot()
    fixture.model.accept(baseline)
    fixture.model.concealed = true
    scanner.set(baseline)
    metadata.set(fixture.windows)
    fixture.model.refresh(showProgress: false)
    try await waitUntil { scanner.calls == 1 }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition(), "The controlled discovery operation did not reach its expected state.")
  }

  @Test("Changing unrelated panels cannot exhaust verified concealment during AX failures")
  func unrelatedPanelsKeepConcealment() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let own = ProcessInfo.processInfo.processIdentifier
    func states(panel: CGRect? = nil) throws -> [StatusWindowState] {
      var metadata: [[String: Any]] = fixture.windows.map { window in
        [kCGWindowLayer as String: Int(CGWindowLevelForKey(.statusWindow)),
         kCGWindowOwnerPID as String: Int(window.processIdentifier),
         kCGWindowNumber as String: Int(window.windowIdentifier),
         kCGWindowIsOnscreen as String: window.isOnscreen,
         kCGWindowBounds as String: CGRect(x: window.frame.x, y: window.frame.y,
           width: window.frame.width, height: window.frame.height).dictionaryRepresentation]
      }
      metadata.append([kCGWindowLayer as String: Int(CGWindowLevelForKey(.statusWindow)),
        kCGWindowOwnerPID as String: Int(own), kCGWindowNumber as String: 9000,
        kCGWindowIsOnscreen as String: true,
        kCGWindowBounds as String: CGRect(x: 1500, y: 0, width: 24, height: 37).dictionaryRepresentation])
      if let panel {
        metadata.append([kCGWindowLayer as String: Int(CGWindowLevelForKey(.statusWindow)),
          kCGWindowOwnerPID as String: 100, kCGWindowNumber as String: 9001,
          kCGWindowIsOnscreen as String: true, kCGWindowBounds as String: panel.dictionaryRepresentation])
      }
      let windows = try #require(statusWindowObservations(in: metadata))
      return StatusWindowInventory(windows: windows, metadata: metadata,
        displays: [CGRect(x: 0, y: 0, width: 1728, height: 1117)]).concealmentStates
    }
    model.accept(fixture.snapshot(complete: true, windows: try states()))
    model.concealed = true
    let saved = model.layout
    for panel: CGRect? in [CGRect(x: 24, y: 19, width: 1680, height: 1079),
      CGRect(x: 400, y: 400, width: 400, height: 200), nil] {
      for _ in 0..<4 {
        #expect(!model.acceptScanStatus(fixture.snapshot(complete: false, windows: try states(panel: panel))))
        #expect(model.concealed)
        #expect(model.reapplyNotBefore == nil)
        #expect(model.layout == saved)
      }
    }
  }

  @Test("A visible hidden-app restart queues only that source without revealing other icons")
  func returnedHiddenSourceQueuesIndividualRepair() async throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let original = model.items
    let source = try #require(original.first)
    let old = source.observation
    let returned = try #require(IdentityAssessor().classify([RawSourceItemObservation(
      runtimeID: "200:0", processIdentifier: 200, bundleIdentifier: old.bundleIdentifier,
      applicationName: old.applicationName, role: old.role,
      frame: ItemFrame(x: 1300, y: 6, width: 24, height: 24), actions: ["AXPress"],
      metadata: old.metadata, observedOrder: old.observedOrder, isOnscreen: true,
      statusWindowIdentifier: 200)]).first)
    let changes = AppModel.keyedChanges(from: original, to: [returned] + original.dropFirst())
    model.items = [returned] + original.dropFirst()
    let saved = model.layout
    let inspection = NativeMenuBarController.Inspection(setupMessage: nil,
      items: [returned.observation.runtimeID: .init(behindBoundary: false,
        isClipped: false, isVerifiedVisible: true)])
    model.repairReturnedHiddenSources(changes, inspection: inspection)
    #expect(model.pendingPlacementKeys == [Fixture.hidden])
    #expect(model.concealed)
    #expect(model.layout == saved)
    // Cancel before the queued task can perform native work; this is a scheduling check.
    model.reveal()
    await Task.yield()
  }

  @Test("Repeated incomplete reads keep an unchanged native section concealed")
  func unchangedWindowsStayConcealed() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let initial = fixture.snapshot()
    model.accept(initial)
    model.concealed = true
    let saved = model.layout
    let observed = model.items

    for _ in 0..<8 {
      #expect(!model.acceptScanStatus(fixture.snapshot(complete: false)))
      #expect(model.concealed)
      #expect(!model.scanComplete)
      #expect(!model.canEdit)
      #expect(model.reapplyNotBefore == nil)
      #expect(model.layout == saved)
      #expect(model.items == observed)
    }

    #expect(model.acceptScanStatus(initial))
    #expect(model.canEdit)
    #expect(model.concealed)
  }

  @Test("Changed or unavailable native windows still require scan recovery",
    arguments: ["added", "moved", "owner", "visibility", "missing", "permission", "stale"])
  func changedWindowsRecover(_ change: String) {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot())
    model.concealed = true
    let saved = model.layout
    let observed = model.items
    var windows = fixture.windows
    let first = windows[0]
    switch change {
    case "added": windows.append(StatusWindowState(processIdentifier: 102, windowIdentifier: 102,
      frame: ItemFrame(x: 1250, y: 6, width: 24, height: 24), isOnscreen: true))
    case "moved": windows[0] = StatusWindowState(processIdentifier: first.processIdentifier,
      windowIdentifier: first.windowIdentifier,
      frame: ItemFrame(x: -200, y: 6, width: 24, height: 24), isOnscreen: first.isOnscreen)
    case "owner": windows[0] = StatusWindowState(processIdentifier: 999,
      windowIdentifier: first.windowIdentifier, frame: first.frame, isOnscreen: first.isOnscreen)
    case "visibility": windows[0] = StatusWindowState(processIdentifier: first.processIdentifier,
      windowIdentifier: first.windowIdentifier, frame: first.frame, isOnscreen: !first.isOnscreen)
    default: break
    }
    let snapshot = fixture.snapshot(complete: false, windows: change == "missing" ? nil : windows,
      permission: change == "permission" ? .denied : .granted,
      capturedAt: change == "stale" ? .distantPast : Date())
    for _ in 0..<4 { #expect(!model.acceptScanStatus(snapshot)) }
    #expect(!model.concealed)
    #expect(!model.canEdit)
    #expect(model.layout == saved)
    #expect(model.items == observed)
    #expect(model.reapplyNotBefore != nil)
  }

  @Test("Reveal invalidates the previously verified native windows")
  func revealInvalidatesWindowBaseline() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot())
    model.reveal()
    model.concealed = true
    for _ in 0..<4 { #expect(!model.acceptScanStatus(fixture.snapshot(complete: false))) }
    #expect(!model.concealed)
  }

  @Test("An unverified concealment scan cannot become a stable-window baseline")
  func unsafeGeometryStillRecovers() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot())
    model.concealed = true
    model.validateConcealment { _ in nil }
    for _ in 0..<4 { #expect(!model.acceptScanStatus(fixture.snapshot(complete: false))) }
    #expect(!model.concealed)
    #expect(model.reapplyNotBefore != nil)
  }

  @Test("Malformed Accessibility geometry reaches safety recovery without crashing diagnostics")
  func malformedGeometryRecovers() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let saved = model.layout
    let original = try #require(model.items.first).observation
    for component in 0..<4 {
      for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int.max)] {
        model.reveal()
        model.concealed = true
        var geometry: [Double] = [-100, 6, 24, 24]
        geometry[component] = value
        model.items[0] = try #require(IdentityAssessor().classify([
          RawSourceItemObservation(runtimeID: original.runtimeID, processIdentifier: original.processIdentifier,
            bundleIdentifier: original.bundleIdentifier, applicationName: original.applicationName,
            role: original.role,
            frame: ItemFrame(x: geometry[0], y: geometry[1], width: geometry[2], height: geometry[3]),
            actions: original.actions, metadata: original.metadata, observedOrder: original.observedOrder)
        ]).first)

        model.validateConcealment { $0.identity.persistentKey == Fixture.hidden ? nil : false }
        model.validateConcealment { $0.identity.persistentKey == Fixture.hidden ? nil : false }
        #expect(!model.concealed)
        #expect(model.reapplyNotBefore != nil)
        #expect(model.layout == saved)
      }
    }
  }

  @Test("Two scans with unknown geometry reveal temporarily and retain saved-layout recovery")
  func unknownGeometryRecovers() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let saved = model.layout

    var reads = 0
    model.validateConcealment { _ in reads += 1; return nil }
    #expect(model.concealed)
    #expect(model.reapplyNotBefore == nil)
    #expect(reads == model.items.count)

    let beforeReveal = Date()
    model.validateConcealment { _ in nil }
    #expect(!model.concealed)
    let retry = try #require(model.reapplyNotBefore)
    #expect(retry >= beforeReveal.addingTimeInterval(3))
    #expect(model.layout == saved)

    model.reveal()
    #expect(model.reapplyNotBefore == nil)
  }

  @Test("A safe scan clears a single unknown-geometry observation")
  func safeScanResetsDebounce() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model

    model.validateConcealment { _ in nil }
    model.validateConcealment { $0.identity.persistentKey == Fixture.hidden }
    model.validateConcealment { _ in nil }
    #expect(model.concealed)
    #expect(model.reapplyNotBefore == nil)
  }

  @Test("A confirmed unassigned or protected source behind the boundary stays revealed for review")
  func confirmedUnsafeSourceDoesNotRecover() {
    for protected in [false, true] {
      let fixture = Fixture()
      defer { fixture.close() }
      let model = fixture.model
      if protected {
        let original = model.items[1]
        model.items[1] = ClassifiedSourceItem(observation: original.observation,
          identity: original.identity,
          manageability: ManageabilityAssessment(status: .protected, reason: "fixture"))
        model.layout.items[1].placement = .dropdown
      }

      for _ in 0..<2 { model.validateConcealment { _ in true } }
      #expect(!model.concealed)
      #expect(model.reapplyNotBefore == nil)
    }
  }

  @Test("Confirmed unsafe placement wins over unknown geometry in the same scan")
  func confirmedUnsafePlacementWins() {
    let fixture = Fixture()
    defer { fixture.close() }
    let model = fixture.model

    for _ in 0..<2 {
      model.validateConcealment { $0.identity.persistentKey == Fixture.hidden ? nil : true }
    }
    #expect(!model.concealed)
    #expect(model.reapplyNotBefore == nil)
    #expect(model.message == "An unassigned or protected item is behind the separator. Items have been revealed.")
  }
}

@MainActor
private final class Fixture {
  static let hidden = "example.hidden"
  let model: AppModel
  private let launcher: NSStatusItem
  private let preferenceKeys: [String]
  private let previousPreferences: [String: Any]

  var windows: [StatusWindowState] {
    model.items.map { item in
      StatusWindowState(processIdentifier: item.observation.processIdentifier,
        windowIdentifier: UInt32(item.observation.processIdentifier), frame: item.observation.frame!,
        isOnscreen: item.observation.isOnscreen == true)
    }
  }

  func snapshot(complete: Bool = true) -> InventorySnapshot {
    snapshot(complete: complete, windows: windows)
  }

  func snapshot(complete: Bool, windows: [StatusWindowState]?,
    permission: AccessibilityPermissionStatus = .granted, capturedAt: Date = Date()) -> InventorySnapshot {
    InventorySnapshot(capturedAt: capturedAt, permission: permission,
      completeness: complete ? .complete : .incomplete, items: complete ? model.items : [],
      statusWindowRuntimeIDs: Set((windows ?? []).map(\.windowIdentifier)), statusWindows: windows,
      warnings: complete ? [] : ["Fixture app did not respond"],
      metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 2,
        sourceItemCount: complete ? model.items.count : 0))
  }

  init(scanner: any InventoryScanning = AccessibilityInventoryScanner(),
    sourceStatusSnapshot: @escaping @Sendable () -> [StatusWindowState]? = AccessibilityInventoryScanner.sourceStatusSnapshot,
    currentPermission: @escaping @MainActor () -> Bool = { true }) {
    NSApplication.shared.setActivationPolicy(.accessory)
    preferenceKeys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let defaults = UserDefaults.standard
    previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    model = AppModel(native: NativeMenuBarController(launcher: launcher), store: nil,
      currentAccessibilityPermission: currentPermission, inventoryScanner: scanner,
      sourceStatusSnapshot: sourceStatusSnapshot)
    launcher.isVisible = false
    model.permissionGranted = true
    model.scanComplete = true
    model.layout.items = [SavedItem(id: Self.hidden, placement: .dropdown), SavedItem(id: "example.bar")]
    model.items = IdentityAssessor().classify(model.layout.items.enumerated().map { index, saved in
      RawSourceItemObservation(runtimeID: "fixture:\(index)", processIdentifier: Int32(100 + index),
        bundleIdentifier: saved.id, applicationName: saved.id, role: "AXMenuBarItem",
        frame: ItemFrame(x: index == 0 ? -100 : 1200, y: 6, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: index,
        isOnscreen: index != 0)
    })
    model.concealed = true
  }

  func close() {
    model.stop()
    NativeMenuBarController.removePreservingPosition(launcher)
    let defaults = UserDefaults.standard
    for key in preferenceKeys {
      if let value = previousPreferences[key] { defaults.set(value, forKey: key) }
      else { defaults.removeObject(forKey: key) }
    }
    defaults.synchronize()
  }
}

private final class HeldConcealmentScanner: InventoryScanning, @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var count = 0
  private var result: InventorySnapshot?
  var calls: Int { lock.withLock { count } }
  func set(_ snapshot: InventorySnapshot) { lock.withLock { result = snapshot } }
  func release() { gate.signal() }
  func scan(promptForPermission: Bool) -> InventorySnapshot {
    lock.withLock { count += 1 }
    gate.wait()
    return lock.withLock { result! }
  }
}

private final class HeldSourceMetadata: @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private let blocked: Bool
  private var count = 0
  private var result: [StatusWindowState]?
  init(blocked: Bool = false) { self.blocked = blocked }
  var calls: Int { lock.withLock { count } }
  func set(_ windows: [StatusWindowState]?) { lock.withLock { result = windows } }
  func release() { gate.signal() }
  func read() -> [StatusWindowState]? {
    let snapshot = lock.withLock { count += 1; return result }
    if blocked { gate.wait() }
    return snapshot
  }
}

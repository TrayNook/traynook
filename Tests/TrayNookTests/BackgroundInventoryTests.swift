import AppKit
import InventoryIdentityCore
import ServiceManagement
import Testing

@testable import TrayNook

@Suite("Background inventory acceptance", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct BackgroundInventoryTests {
  @Test("A delayed read publishes neither new items nor layout until its result is accepted")
  func publishesOnlyAfterCompletion() async throws {
    let fixture = try await InventoryFixture()
    defer { fixture.close() }
    let originalLayout = fixture.model.layout
    let originalItems = fixture.model.items
    let pending = fixture.begin(extra: "example.arrived")
    try await waitUntil { fixture.load.calls == 1 }
    #expect(fixture.model.layout == originalLayout)
    #expect(fixture.model.items == originalItems)
    fixture.load.release()
    #expect(try await finish(pending))
    #expect(fixture.model.items.contains { $0.identity.persistentKey == "example.arrived" })
    #expect(fixture.model.layout.items.contains { $0.id == "example.arrived" && $0.placement == .menuBar })
  }

  enum Invalidation: CaseIterable, Sendable { case layoutEdit, reveal, permission, stop }

  @Test("User and lifecycle changes discard an in-flight inventory", arguments: Invalidation.allCases)
  func discardsInvalidatedResults(_ reason: Invalidation) async throws {
    let fixture = try await InventoryFixture()
    defer { fixture.close() }
    let originalItems = fixture.model.items
    let pending = fixture.begin(extra: "example.obsolete")
    try await waitUntil { fixture.load.calls == 1 }
    switch reason {
    case .layoutEdit: fixture.model.setRowCapacity(7)
    case .reveal: fixture.model.reveal()
    case .permission: fixture.model.permissionGranted = false
    case .stop: fixture.model.stop()
    }
    let authoritativeLayout = fixture.model.layout
    if reason == .reveal || reason == .stop {
      #expect(try await finish(pending) == false,
        "Reveal and shutdown must finish without waiting for the blocking C call.")
      #expect(fixture.load.completed == 0)
    }
    fixture.load.release()
    #expect(try await finish(pending) == false)
    #expect(fixture.model.items == originalItems)
    #expect(fixture.model.layout == authoritativeLayout)
    #expect(fixture.model.reapplyNotBefore == nil)
    if reason == .permission { #expect(!fixture.model.permissionGranted) }
  }

  @Test("Permission lost during the query is rechecked before publishing")
  func rechecksCurrentPermission() async throws {
    let fixture = try await InventoryFixture()
    defer { fixture.close() }
    let originalLayout = fixture.model.layout
    let originalItems = fixture.model.items
    let pending = fixture.begin(extra: "example.obsolete")
    try await waitUntil { fixture.load.calls == 1 }
    fixture.permission.granted = false
    fixture.load.release()
    #expect(try await finish(pending), "The permission-denied state itself must be accepted.")
    #expect(!fixture.model.permissionGranted)
    #expect(!fixture.model.scanComplete)
    #expect(!fixture.model.concealed)
    #expect(!fixture.model.native.hasVisibleBoundary)
    #expect(fixture.model.items == originalItems)
    #expect(fixture.model.layout == originalLayout)
    #expect(fixture.model.reapplyNotBefore == nil)
  }

  @Test("A newer synchronous inventory supersedes an older background result")
  func synchronousAcceptanceWins() async throws {
    let fixture = try await InventoryFixture()
    defer { fixture.close() }
    let old = fixture.begin(extra: "example.old")
    try await waitUntil { fixture.load.calls == 1 }
    fixture.model.accept(InventoryFixture.snapshot(extra: "example.current"))
    let currentLayout = fixture.model.layout
    let currentItems = fixture.model.items
    fixture.load.release()
    #expect(try await finish(old) == false)
    #expect(fixture.model.items == currentItems)
    #expect(fixture.model.layout == currentLayout)
    #expect(fixture.model.items.contains { $0.identity.persistentKey == "example.current" })
  }

  @Test("Only the newer asynchronous inventory can publish after a blocked query")
  func newerBackgroundAcceptanceWins() async throws {
    let fixture = try await InventoryFixture()
    defer { fixture.close() }
    let old = fixture.begin(extra: "example.old")
    try await waitUntil { fixture.load.calls == 1 }
    let current = fixture.begin(extra: "example.current")
    try await waitUntil { current.outcome.started }
    fixture.load.release()
    #expect(try await finish(old) == false)
    try await waitUntil { fixture.load.calls == 2 }
    fixture.load.release()
    #expect(try await finish(current))
    #expect(fixture.model.items.contains { $0.identity.persistentKey == "example.current" })
    #expect(!fixture.model.items.contains { $0.identity.persistentKey == "example.old" })
    #expect(!fixture.model.layout.items.contains { $0.id == "example.old" })
  }

  private func finish(_ pending: PendingAcceptance) async throws -> Bool {
    try await waitUntil { pending.outcome.result != nil }
    return try #require(pending.outcome.result as Bool?)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition(), "The inventory acceptance did not reach the expected state within two seconds.")
  }
}

@MainActor
private final class InventoryFixture {
  final class Permission { var granted = true }
  let permission: Permission
  let load = DelayedInventoryMetadata()
  let model: AppModel
  private let launcher: NSStatusItem
  private let preferenceKeys: [String]
  private let previousPreferences: [String: Any]

  init() async throws {
    for id in ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"] {
      try #require(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
        "Quit TrayNook before creating the isolated inventory test controls.")
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    preferenceKeys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let defaults = UserDefaults.standard
    previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    launcher = NSStatusBar.system.statusItem(withLength: 24)
    let native = NativeMenuBarController(launcher: launcher,
      metadataReader: WindowMetadataReader(load: load.read))
    native.reveal(keepBoundaryVisible: true)
    let permission = Permission()
    self.permission = permission
    model = AppModel(native: native, store: nil,
      loginItemStatus: LoginItemStatus(read: { .notRegistered }, register: {}, unregister: {}),
      currentAccessibilityPermission: { permission.granted })
    model.layout = SavedLayout(items: [SavedItem(id: "example.baseline", placement: .dropdown)])
    model.accept(Self.snapshot())
    try await Task.sleep(for: .milliseconds(250))
  }

  func begin(extra: String) -> PendingAcceptance {
    let outcome = AcceptanceOutcome()
    let snapshot = Self.snapshot(extra: extra)
    let task = Task { @MainActor [model] in
      outcome.started = true
      outcome.result = await model.acceptLatest(snapshot)
    }
    return PendingAcceptance(outcome: outcome, task: task)
  }

  static func snapshot(extra: String? = nil) -> InventorySnapshot {
    let bundles = ["example.baseline"] + (extra.map { [$0] } ?? [])
    let items = IdentityAssessor().classify(bundles.enumerated().map { index, bundle in
      RawSourceItemObservation(runtimeID: "fixture:\(bundle)", processIdentifier: Int32(100 + index),
        bundleIdentifier: bundle, applicationName: bundle, role: "AXMenuBarItem",
        frame: ItemFrame(x: 1200 + Double(index) * 28, y: 6, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: index)
    })
    return InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
      items: items, warnings: [],
      metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: items.count, sourceItemCount: items.count))
  }

  func close() {
    model.stop()
    NativeMenuBarController.removePreservingPosition(launcher)
    load.release(4)
    let defaults = UserDefaults.standard
    for key in preferenceKeys {
      if let value = previousPreferences[key] { defaults.set(value, forKey: key) }
      else { defaults.removeObject(forKey: key) }
    }
    defaults.synchronize()
  }
}

@MainActor
private final class AcceptanceOutcome {
  var started = false
  var result: Bool?
}

@MainActor
private struct PendingAcceptance {
  let outcome: AcceptanceOutcome
  let task: Task<Void, Never>
}

private final class DelayedInventoryMetadata: @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var callCount = 0
  private var completionCount = 0
  var calls: Int { lock.withLock { callCount } }
  var completed: Int { lock.withLock { completionCount } }

  func read(_ ids: [UInt32]) -> [WindowMetadata] {
    lock.withLock { callCount += 1 }
    guard gate.wait(timeout: .now() + 5) == .success else { return [] }
    let result = WindowMetadata.read(ids: ids)
    lock.withLock { completionCount += 1 }
    return result
  }

  func release(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }
}

import AppKit
import Combine
import InventoryIdentityCore
import ServiceManagement
import Testing

@testable import TrayNook

@Suite("Idle inventory publications", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct IdleInventoryTests {
  @Test("Identical accepted inventories do not rebuild presentation", arguments: [false, true])
  func unchangedInventoryDoesNotPublish(includeBaseline: Bool) throws {
    let fixture = try IdleInventoryFixture()
    defer { fixture.close() }
    let model = fixture.model
    let baseline = includeBaseline ? ["example.baseline"] : []
    let snapshot = fixture.snapshot(bundles: baseline)
    model.accept(snapshot)
    #expect(model.scanComplete)
    #expect(model.items == snapshot.items)

    var publications = 0
    let subscription = model.objectWillChange.sink { publications += 1 }
    defer { subscription.cancel() }
    for _ in 0..<4 { model.accept(snapshot) }
    #expect(publications == 0,
      "An unchanged inventory must not invalidate Settings or Dropdown views while idle.")

    let changed = fixture.snapshot(bundles: baseline + ["example.arrived"])
    model.accept(changed)
    #expect(publications > 0, "A real inventory change must still update presentation.")
    #expect(model.items == changed.items)
    #expect(model.layout.items.contains { $0.id == "example.arrived" && $0.placement == .menuBar })

    publications = 0
    model.accept(changed)
    #expect(publications == 0)
  }

  @Test("Quiet polls coalesce without progress publications, while manual refresh still shows progress")
  func quietPollScheduling() async throws {
    let scanner = HeldInventoryScanner()
    defer { scanner.release(4) }
    let fixture = try IdleInventoryFixture(scanner: scanner)
    defer { fixture.close() }
    let model = fixture.model
    model.accept(fixture.snapshot(bundles: []))

    var publications = 0
    let subscription = model.objectWillChange.sink { publications += 1 }
    defer { subscription.cancel() }
    model.refresh(showProgress: false)
    try await waitUntil { scanner.calls == 1 }
    model.refresh(showProgress: false)
    model.refresh()
    #expect(!model.scanning)
    #expect(scanner.calls == 1)
    #expect(publications == 0)

    scanner.release()
    try await waitUntil { fixture.permission.reads == 1 }
    #expect(!model.scanning)
    #expect(publications == 0)

    model.refresh()
    #expect(model.scanning)
    #expect(publications == 1)
    try await waitUntil { scanner.calls == 2 }
    model.refresh()
    scanner.release()
    try await waitUntil { fixture.permission.reads == 2 }
    #expect(!model.scanning)
    #expect(scanner.calls == 2)
    #expect(publications == 2)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition(), "The inventory task did not reach the expected state within two seconds.")
  }
}

@MainActor
private final class IdleInventoryFixture {
  final class Permission { var reads = 0 }
  let permission = Permission()
  let model: AppModel
  private let launcher: NSStatusItem
  private let preferenceKeys: [String]
  private let previousPreferences: [String: Any]

  init(scanner: any InventoryScanning = AccessibilityInventoryScanner()) throws {
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
    launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let permission = permission
    model = AppModel(native: NativeMenuBarController(launcher: launcher), store: nil,
      loginItemStatus: LoginItemStatus(read: { .notRegistered }, register: {}, unregister: {}),
      currentAccessibilityPermission: { permission.reads += 1; return true },
      inventoryScanner: scanner)
    launcher.isVisible = false
  }

  func snapshot(bundles: [String]) -> InventorySnapshot {
    let items = IdentityAssessor().classify(bundles.enumerated().map { index, bundle in
      RawSourceItemObservation(runtimeID: "fixture:\(bundle)", processIdentifier: Int32(100 + index),
        bundleIdentifier: bundle, applicationName: bundle, role: "AXMenuBarItem",
        frame: ItemFrame(x: 1200 + Double(index) * 28, y: 6, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: index,
        isOnscreen: false)
    })
    return InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
      items: items, warnings: [],
      metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: items.count,
        sourceItemCount: items.count))
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

private final class HeldInventoryScanner: InventoryScanning, @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var callCount = 0

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  func scan(promptForPermission: Bool) -> InventorySnapshot {
    lock.lock()
    callCount += 1
    lock.unlock()
    gate.wait()
    return InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
      items: [], warnings: [],
      metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0))
  }

  func release(_ count: Int = 1) {
    for _ in 0..<count { gate.signal() }
  }
}

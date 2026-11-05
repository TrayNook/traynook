import Foundation
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Diagnostics report formatting")
struct DiagnosticsReportTests {
  private let occurredAt = Date(timeIntervalSince1970: 1_794_000_000)

  @Test("Normal state has explicit absent values and preserves the snapshot")
  func normalState() {
    let report = DiagnosticsReport(version: "1.2.3", build: "42", macOS: "test macOS",
      permissionGranted: true, scanComplete: true, concealed: true)
    let before = report
    #expect(report.text == """
      TrayNook 1.2.3 (42)
      macOS test macOS
      Accessibility: true
      Inventory complete: true
      Layout recovery: false
      Native section concealed: true
      Private APIs: none
      Screen Recording: false
      Proxy imagery: app icons
      Last reveal/recovery reason: none
      Last reveal/recovery at: none
      Last failure: none
      Affected sources: none
      reapplyNotBefore: none
      recoveringLayout: false
      busy: false
      scanning: false
      nativeBusy: false
      incompleteScans: 0
      unsafeScans: 0
      hasPendingActivation: false
      Pending return source: none
      panelWatch: false
      dropdownShown: false
      pendingPlacementKeys: 0
      automaticPlacementKeys: 0
      Pending placement sources: none
      Automatic placement sources: none
      Hidden source repairs: none
      Affected-app bundle identifiers only; no full app inventory, item labels, window titles, or images.
      """)
    #expect(report == before)
    #expect(report.text == before.text)
  }

  @Test("Scheduled recovery exposes its original cause, UTC deadline, and scan blockers")
  func scheduledRecovery() {
    let report = DiagnosticsReport(lastReveal: .init(reason: .inventoryUnavailable, timestamp: occurredAt),
      reapplyNotBefore: occurredAt.addingTimeInterval(3), recoveringLayout: true,
      busy: true, scanning: true, nativeBusy: true, incompleteScans: 3, unsafeScans: 2)
    let text = report.text
    #expect(text.contains("Last reveal/recovery reason: inventoryUnavailable"))
    #expect(text.contains("Last reveal/recovery at: 2026-11-06T21:20:00.000Z"))
    #expect(text.contains("reapplyNotBefore: 2026-11-06T21:20:03.000Z"))
    for field in ["recoveringLayout", "busy", "scanning", "nativeBusy"] {
      #expect(text.contains("\(field): true"))
    }
    #expect(text.contains("incompleteScans: 3"))
    #expect(text.contains("unsafeScans: 2"))
  }

  @Test("Pending selected return reports only its source and return blockers")
  func pendingReturn() {
    let report = DiagnosticsReport(concealed: true, hasPendingActivation: true,
      pendingActivationBundle: "example.selected", panelWatch: true, dropdownShown: true)
    #expect(report.text.contains("Native section concealed: true"))
    #expect(report.text.contains("hasPendingActivation: true\nPending return source: example.selected\npanelWatch: true\ndropdownShown: true"))
    #expect(DiagnosticsReport(hasPendingActivation: true).text.contains("Pending return source: unknown"))
    #expect(DiagnosticsReport(pendingActivationBundle: "example.stale").text.contains("Pending return source: none"))
  }

  @Test("Repair attempts distinguish exhaustion from refunded transient failures without consuming them")
  @MainActor func repairAttempts() throws {
    let source = try #require(IdentityAssessor().classify([
      RawSourceItemObservation(runtimeID: "10:0", processIdentifier: 10,
        bundleIdentifier: "example.repair", applicationName: "Private fixture name", role: "AXMenuBarItem",
        frame: ItemFrame(x: 1100, y: 0, width: 24, height: 24), actions: ["AXPress"],
        metadata: LiveAccessibilityMetadata(title: "Private item title"), observedOrder: 0,
        statusWindowIdentifier: 10),
    ]).first)
    var repair = AppModel.HiddenSourceRepair(source: source)
    var report = DiagnosticsReport(pendingPlacementCount: 1, automaticPlacementCount: 1,
      pendingPlacementBundles: ["example.repair"], automaticPlacementBundles: ["example.repair"],
      hiddenSourceRepairs: [.init(bundleIdentifier: source.observation.bundleIdentifier,
        attempts: repair.attempts, notBefore: repair.notBefore)])
    #expect(report.text.contains("attempts=0/3, exhausted=false, notBefore=none"))
    for interval in [0.0, 3.0, 6.0] {
      let dispatched = repair.takeAttempt(now: occurredAt.addingTimeInterval(interval))
      #expect(dispatched)
    }
    report.hiddenSourceRepairs = [.init(bundleIdentifier: source.observation.bundleIdentifier,
      attempts: repair.attempts, notBefore: repair.notBefore)]
    let before = repair
    let text = report.text
    #expect(text.contains("example.repair: attempts=3/3, exhausted=true, notBefore=2026-11-06T21:20:09.000Z"))
    #expect(text.contains("Pending placement sources: example.repair"))
    #expect(text.contains("pendingPlacementKeys: 1\nautomaticPlacementKeys: 1"))
    #expect(!text.contains("Private fixture name"))
    #expect(!text.contains("Private item title"))
    #expect(repair.attempts == before.attempts)
    #expect(repair.notBefore == before.notBefore)
    #expect(!repair.canAttempt(now: .distantFuture))
    #expect(report.text == text)

    var refunded: AppModel.HiddenSourceRepair? = repair
    let deferred = AppModel.deferAutomaticPlacementFailure(NativeMenuActionError.inventoryUnavailable,
      repair: &refunded)
    #expect(deferred)
    let retry = try #require(refunded)
    report.hiddenSourceRepairs = [.init(bundleIdentifier: retry.source.observation.bundleIdentifier,
      attempts: retry.attempts, notBefore: retry.notBefore)]
    #expect(report.text.contains("example.repair: attempts=2/3, exhausted=false, notBefore=2026-11-06T21:20:09.000Z"))
    #expect(refunded?.attempts == 2)
    #expect(refunded?.notBefore == before.notBefore)
    #expect(refunded?.canAttempt(now: before.notBefore) == true)
  }

  @Test("Affected bundle identifiers are sorted and deduplicated independently of retry state")
  func stableAffectedSources() {
    let event = DiagnosticsReport.Event(reason: .operationFailure, timestamp: occurredAt,
      failure: "responseTimedOut", affectedBundles: ["example.z", "example.a", "example.z", ""])
    let report = DiagnosticsReport(screenRecordingGranted: true, lastReveal: event,
      pendingPlacementBundles: ["example.z", "example.a", "example.z"],
      automaticPlacementBundles: ["example.z", "example.z"])
    #expect(report.text.contains("Affected sources: example.a, example.z"))
    #expect(report.text.contains("Pending placement sources: example.a, example.z"))
    #expect(report.text.contains("Automatic placement sources: example.z"))
    #expect(report.text.contains("Last failure: responseTimedOut"))
    #expect(report.text.contains("Proxy imagery: captured menu-bar items"))
    #expect(report.lastReveal == event)
  }
}

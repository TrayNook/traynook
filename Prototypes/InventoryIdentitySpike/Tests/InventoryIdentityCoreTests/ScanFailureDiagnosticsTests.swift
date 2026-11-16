import ApplicationServices
import Foundation
import Testing

@testable import InventoryIdentityCore

@Suite("Bounded scan failure diagnostics")
struct ScanFailureDiagnosticsTests {
  @Test("Only the first failure per affected process retains its category and timing")
  func firstFailurePerProcess() {
    var now: UInt64 = 1_000_000_000
    let tracker = AccessibilityScanIssueTracker(deadline: 2_000_000_000, uptimeNanoseconds: { now })
    tracker.beginApplication(100, bundleIdentifier: "example.source")
    now += 200_000_000
    tracker.record(.cannotComplete, operation: .timeoutConfiguration)
    tracker.record(.invalidUIElement, operation: .message)
    tracker.finishApplication(durationMilliseconds: 200)
    tracker.beginApplication(200)
    now = 2_000_000_000
    #expect(!tracker.currentApplicationIsComplete)
    #expect(tracker.firstFailures.count == 2)
    #expect(tracker.firstFailures[0].processIdentifier == 100)
    #expect(tracker.firstFailures[0].bundleIdentifier == "example.source")
    #expect(tracker.firstFailures[0].operation == .timeoutConfiguration)
    #expect(tracker.firstFailures[0].errorCode == AXError.cannotComplete.rawValue)
    #expect(tracker.firstFailures[0].elapsedMilliseconds == 200)
    #expect(!tracker.firstFailures[0].budgetExceeded)
    #expect(tracker.firstFailures[1].operation == .budget)
    #expect(tracker.firstFailures[1].budgetExceeded)
  }

  @Test("Diagnostic failure arrays have a fixed cap while all failure counts remain accurate")
  func boundedFailures() {
    let tracker = AccessibilityScanIssueTracker()
    for process in Int32(1)...100 {
      tracker.beginApplication(process)
      tracker.record(.cannotComplete)
      tracker.finishApplication(durationMilliseconds: 1)
    }
    #expect(tracker.incompleteApplicationCount == 100)
    #expect(tracker.firstFailures.count == AccessibilityInventoryTuning.maximumDiagnosticFailures)
  }

  @Test("Legacy metrics decode with empty added diagnostics")
  func legacyMetrics() throws {
    let data = Data("""
      {"durationMilliseconds":10,"inspectedApplicationCount":2,"sourceItemCount":1,
       "incompleteApplicationCount":0,"cannotCompleteApplicationCount":0,
       "maximumApplicationScanMilliseconds":5,"messagingTimeoutMilliseconds":200}
      """.utf8)
    let metrics = try JSONDecoder().decode(ScanMetrics.self, from: data)
    #expect(metrics.firstFailures.isEmpty)
    #expect(!metrics.budgetExceeded)
  }
}

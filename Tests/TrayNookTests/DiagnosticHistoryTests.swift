import Foundation
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Bounded local diagnostic history")
struct DiagnosticHistoryTests {
  private let now = Date(timeIntervalSince1970: 1_794_000_000)

  @Test("Extended limits require the local preference and development identity")
  func localLimitsAreScoped() {
    for bundle in ["io.github.mahenzon.TrayNook", "example.fixture", "io.github.mahenzon.TrayNook.dev"] {
      for enabled in [false, true] {
        let limits = DiagnosticHistory.limits(for: bundle, extendedLocally: enabled)
        let extended = bundle == "io.github.mahenzon.TrayNook.dev" && enabled
        #expect(limits.maximumBytes == (extended ? 32 * 1_048_576 : 1_048_576))
        #expect(limits.retention == TimeInterval(extended ? 30 : 7) * 86400)
      }
    }
  }

  @Test("Local retention keeps older evidence across restart and expires records after thirty days")
  func extendedRetention() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.jsonl")
    let limits = DiagnosticHistory.limits(for: "io.github.mahenzon.TrayNook.dev", extendedLocally: true)
    let old = DiagnosticHistory(url: url, now: { now.addingTimeInterval(-10 * 86400) })
    old.record(.layout, outcome: .completed)
    _ = try await old.read()
    let before = try Data(contentsOf: url)
    let history = DiagnosticHistory(url: url, maximumBytes: limits.maximumBytes,
      retention: limits.retention, now: { now })
    #expect(try await history.read().count == 1)
    #expect(try Data(contentsOf: url) == before)
    let expired = DiagnosticHistory(url: url, maximumBytes: limits.maximumBytes,
      retention: limits.retention, now: { now.addingTimeInterval(21 * 86400) })
    #expect(try await expired.read().isEmpty)
    #expect(try await DiagnosticHistory(url: url, now: { now }).read().isEmpty)
  }

  @Test("History preserves event order and fixed result codes across a restart")
  func preservesOrder() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.jsonl")
    let history = DiagnosticHistory(url: url, now: { now })
    let interaction = UUID()
    history.record(.selectedReturn, outcome: .started, bundleIdentifier: "example.source", operationID: interaction)
    history.record(.selectedReturn, outcome: .deferred, reason: .inventoryUnavailable, operationID: interaction)
    history.record(.selectedReturn, outcome: .completed, operationID: interaction)
    let events = try await history.read()
    #expect(events.map(\.outcome) == [.started, .deferred, .completed])
    #expect(events.allSatisfy { $0.operationID == interaction })
    #expect(try await DiagnosticHistory(url: url, now: { now }).read() == events)
  }

  @Test("Control and source refusals retain a fixed reason without recording item text",
    arguments: [DiagnosticHistory.Reason.controlPlacementRefused, .unsafeConcealment,
      .unsafeControlGeometry, .sourceWindowUnavailable])
  func preservesFixedRefusalReason(_ reason: DiagnosticHistory.Reason) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.jsonl")
    let history = DiagnosticHistory(url: url, now: { now })
    history.record(.layout, outcome: .failed, reason: reason, operation: .savedLayout,
      bundleIdentifier: "Private item title\nBearer private-token")
    let events = try await history.read()
    let event = try #require(events.first)
    #expect(event.operation == .savedLayout)
    #expect(event.reason == reason)
    #expect(event.bundleIdentifier == nil)
    let stored = try String(contentsOf: url, encoding: .utf8)
    #expect(!stored.contains("Private"))
    #expect(!stored.contains("Bearer"))
    #expect(!stored.contains("private-token"))
    #expect(try await DiagnosticHistory(url: url, now: { now }).read() == events)
  }

  @Test("Only bundle identifiers and structured finite metrics cross the persistent boundary")
  func fixedSchema() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.jsonl")
    let history = DiagnosticHistory(url: url, now: { now })
    history.record(.inventory, outcome: .deferred, reason: .scanIncomplete,
      bundleIdentifier: "Private item title\nBearer private-token",
      metrics: ScanMetrics(durationMilliseconds: .infinity, inspectedApplicationCount: 2,
        sourceItemCount: 1, firstFailures: [AccessibilityScanFailure(processIdentifier: 10,
          bundleIdentifier: "Private label", operation: .message, errorCode: -25204,
          elapsedMilliseconds: .nan, budgetExceeded: false)]), scanAgeMilliseconds: .nan)
    let events = try await history.read()
    let event = try #require(events.first)
    #expect(event.bundleIdentifier == nil)
    #expect(event.scanAgeMilliseconds == nil)
    #expect(event.metrics?.durationMilliseconds == 0)
    #expect(event.metrics?.firstFailures.first?.bundleIdentifier == nil)
    let stored = try String(contentsOf: url, encoding: .utf8)
    #expect(!stored.contains("Private"))
    #expect(!stored.contains("Bearer"))
    #expect(!stored.contains("private-token"))
  }

  @Test("Version-one history keeps legacy records and distinguishes layout operation contexts")
  func preservesOperationContexts() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.jsonl")
    let timestamp = now.timeIntervalSinceReferenceDate
    let records = ["{\"schemaVersion\":1}",
      "{\"timestamp\":\(timestamp),\"category\":\"layout\",\"outcome\":\"completed\"}"]
      + ["savedLayout", "placement", "menuBarOrder"].map {
        "{\"timestamp\":\(timestamp),\"category\":\"layout\",\"outcome\":\"failed\",\"reason\":\"unknown\",\"operation\":\"\($0)\"}"
      }
    let original = Data((records.joined(separator: "\n") + "\n").utf8)
    try original.write(to: url)
    let history = DiagnosticHistory(url: url, now: { now })
    let events = try await history.read()
    #expect(events.count == 4)
    let encoded = try events.map {
      try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as? [String: Any])
    }
    #expect(encoded.first?["operation"] == nil)
    #expect(encoded.dropFirst().compactMap { $0["operation"] as? String }
      == ["savedLayout", "placement", "menuBarOrder"])
    #expect(try Data(contentsOf: url) == original)
    #expect(try await DiagnosticHistory(url: url, now: { now }).read() == events)
  }

  @Test("Rotation expires seven-day-old records and enforces a byte cap")
  func boundsRetention() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.jsonl")
    let old = DiagnosticHistory(url: url, now: { now.addingTimeInterval(-8 * 86400) })
    old.record(.lifecycle, outcome: .suspended)
    _ = try await old.read()
    let history = DiagnosticHistory(url: url, maximumBytes: 2048, now: { now })
    for _ in 0..<100 { history.record(.inventory, outcome: .deferred, reason: .scanIncomplete) }
    let events = try await history.read()
    #expect(!events.isEmpty && events.count < 100)
    #expect(events.allSatisfy { $0.timestamp == now })
    #expect(try Data(contentsOf: url).count <= 2048)
  }

  @Test("Malformed or newer history remains byte-for-byte intact")
  func preservesUnreadableHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.jsonl")
    for data in [Data("broken history".utf8), Data("{\"schemaVersion\":999}\n".utf8),
      Data("{\"schemaVersion\":1}\n{\"timestamp\":0,\"category\":\"inventory\",\"outcome\":\"deferred\",\"bundleIdentifier\":\"Private user title\"}\n".utf8)] {
      try data.write(to: url)
      let history = DiagnosticHistory(url: url, now: { now })
      history.record(.layout, outcome: .completed)
      await #expect(throws: (any Error).self) { try await history.read() }
      #expect(try Data(contentsOf: url) == data)
    }
    let directoryHistory = DiagnosticHistory(url: directory, now: { now })
    directoryHistory.record(.layout, outcome: .completed)
    await #expect(throws: (any Error).self) { try await directoryHistory.read() }
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("Oversized existing history is preserved instead of being loaded or truncated")
  func preservesOversizedHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.jsonl")
    let data = Data(repeating: 65, count: 3000)
    try data.write(to: url)
    let history = DiagnosticHistory(url: url, maximumBytes: 2048, now: { now })
    history.record(.layout, outcome: .completed)
    await #expect(throws: (any Error).self) { try await history.read() }
    #expect(try Data(contentsOf: url) == data)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("traynook-history-\(UUID())")
  }
}

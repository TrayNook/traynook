import Foundation
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Bounded local diagnostic history")
struct DiagnosticHistoryTests {
  private let now = Date(timeIntervalSince1970: 1_794_000_000)

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

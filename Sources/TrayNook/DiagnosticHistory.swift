import Foundation
import InventoryIdentityCore
import os

/// Only fixed diagnostic categories and affected bundle identifiers cross this boundary.
final class DiagnosticHistory: @unchecked Sendable {
  enum Category: String, Codable, Sendable {
    case inventory, layout, activation, selectedReturn, lifecycle, display
  }
  enum Outcome: String, Codable, Sendable {
    case started, completed, deferred, failed, cancelled, suspended, resumed, changed
  }
  enum Reason: String, Codable, Sendable {
    case inputNotIdle, inputInterrupted, placementInterrupted, inventoryUnavailable, responseTimedOut
    case permissionDenied, identityChanged, scanIncomplete, budgetExceeded, displayUnavailable, unknown
  }
  enum StorageError: Error { case unavailable, malformed, newerSchema, oversized }

  struct Event: Codable, Equatable, Sendable {
    let timestamp: Date
    let category: Category
    let outcome: Outcome
    let reason: Reason?
    let bundleIdentifier: String?
    let operationID: UUID?
    let metrics: ScanMetrics?
    let scanAgeMilliseconds: Double?
  }

  static let shared: DiagnosticHistory = {
    // Unit tests and unbundled tools must not write the user's application history.
    guard !CommandLine.arguments.contains("--smoke-test"), !CommandLine.arguments.contains("--diagnose"),
      Bundle.main.bundleURL.pathExtension == "app", let bundle = Bundle.main.bundleIdentifier,
      ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"].contains(bundle) else {
      return DiagnosticHistory(url: nil)
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return DiagnosticHistory(url: support.appendingPathComponent(bundle)
      .appendingPathComponent("diagnostic-history.jsonl"))
  }()

  let url: URL?
  private let maximumBytes: Int
  private let now: @Sendable () -> Date
  private let queue = DispatchQueue(label: "io.github.mahenzon.TrayNook.diagnostic-history", qos: .utility)
  private var loaded = false
  private var failure: StorageError?
  private var events: [Event] = []
  private var lines: [Data] = []
  private var byteCount = 0
  private static let header = Data("{\"schemaVersion\":1}\n".utf8)
  private static let retention: TimeInterval = 7 * 24 * 60 * 60
  private static let log = Logger(subsystem: "io.github.mahenzon.TrayNook", category: "diagnostic-history")

  init(url: URL?, maximumBytes: Int = 1_048_576, now: @escaping @Sendable () -> Date = { Date() }) {
    precondition(maximumBytes >= 1024 && maximumBytes <= 1_048_576)
    self.url = url
    self.maximumBytes = maximumBytes
    self.now = now
  }

  func record(_ category: Category, outcome: Outcome, reason: Reason? = nil,
    bundleIdentifier: String? = nil, operationID: UUID? = nil, metrics: ScanMetrics? = nil,
    scanAgeMilliseconds: Double? = nil) {
    guard url != nil else { return }
    let event = Event(timestamp: now(), category: category, outcome: outcome, reason: reason,
      bundleIdentifier: Self.bundleIdentifier(bundleIdentifier), operationID: operationID,
      metrics: metrics.map(Self.sanitized), scanAgeMilliseconds: scanAgeMilliseconds.flatMap {
        $0.isFinite && $0 >= 0 ? $0 : nil
      })
    queue.async { self.append(event) }
  }

  /// Reading waits for preceding writes and never changes the stored file.
  func read() async throws -> [Event] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.load()
        if let failure = self.failure { continuation.resume(throwing: failure) }
        else {
          let cutoff = self.now().addingTimeInterval(-Self.retention)
          continuation.resume(returning: self.events.filter { $0.timestamp >= cutoff })
        }
      }
    }
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    guard let url else { return }
    do {
      let attributes: [FileAttributeKey: Any]
      do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
      catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return }
      guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StorageError.unavailable }
      guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
        throw StorageError.oversized
      }
      let data = try Data(contentsOf: url)
      guard data.count <= maximumBytes else { throw StorageError.oversized }
      let records = data.split(separator: 10, omittingEmptySubsequences: false)
      guard records.last?.isEmpty == true, let first = records.first else { throw StorageError.malformed }
      struct Header: Decodable { let schemaVersion: Int }
      let header = try JSONDecoder().decode(Header.self, from: Data(first))
      guard header.schemaVersion == 1 else { throw StorageError.newerSchema }
      for record in records.dropFirst().dropLast() {
        let event = try JSONDecoder().decode(Event.self, from: Data(record))
        guard event.timestamp.timeIntervalSince1970.isFinite,
          event.bundleIdentifier == Self.bundleIdentifier(event.bundleIdentifier),
          event.metrics == event.metrics.map(Self.sanitized),
          event.scanAgeMilliseconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw StorageError.malformed }
        events.append(event)
        var line = Data(record); line.append(10); lines.append(line)
      }
      byteCount = data.count
    } catch { setFailure(error) }
  }

  private func append(_ event: Event) {
    load()
    guard failure == nil, let url else { return }
    do {
      var line = try JSONEncoder().encode(event); line.append(10)
      guard line.count + Self.header.count <= maximumBytes else { return }
      let cutoff = now().addingTimeInterval(-Self.retention)
      let oldCount = events.count
      var keptEvents: [Event] = [], keptLines: [Data] = []
      for (existing, data) in zip(events, lines) where existing.timestamp >= cutoff {
        keptEvents.append(existing); keptLines.append(data)
      }
      events = keptEvents; lines = keptLines
      byteCount = Self.header.count + lines.reduce(0) { $0 + $1.count }
      if byteCount + line.count > maximumBytes {
        // Keep headroom so a full history does not rewrite one megabyte on every event.
        let target = max(maximumBytes / 2, Self.header.count + line.count)
        while byteCount + line.count > target, !lines.isEmpty {
          byteCount -= lines.removeFirst().count
          events.removeFirst()
        }
      }
      let compact = events.count != oldCount || !FileManager.default.fileExists(atPath: url.path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if compact {
        var data = Self.header
        for existing in lines { data.append(existing) }
        data.append(line)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      } else {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      }
      events.append(event); lines.append(line); byteCount += line.count
    } catch { setFailure(error) }
  }

  private func setFailure(_ error: Error) {
    failure = error as? StorageError ?? .unavailable
    // Never print filesystem errors: a path or localized description may contain user text.
    Self.log.error("Local diagnostic history recording stopped; readback reports the storage failure.")
  }

  private static func bundleIdentifier(_ value: String?) -> String? {
    guard let value, value.count <= 255, value.contains("."),
      value.unicodeScalars.allSatisfy({
        (65...90).contains($0.value) || (97...122).contains($0.value)
          || (48...57).contains($0.value) || $0 == "." || $0 == "-"
      }) else { return nil }
    return value
  }

  private static func sanitized(_ metrics: ScanMetrics) -> ScanMetrics {
    func duration(_ value: Double) -> Double { value.isFinite && value >= 0 ? value : 0 }
    return ScanMetrics(durationMilliseconds: duration(metrics.durationMilliseconds),
      inspectedApplicationCount: max(0, metrics.inspectedApplicationCount), sourceItemCount: max(0, metrics.sourceItemCount),
      incompleteApplicationCount: max(0, metrics.incompleteApplicationCount),
      cannotCompleteApplicationCount: max(0, metrics.cannotCompleteApplicationCount),
      maximumApplicationScanMilliseconds: duration(metrics.maximumApplicationScanMilliseconds),
      messagingTimeoutMilliseconds: duration(metrics.messagingTimeoutMilliseconds),
      firstFailures: metrics.firstFailures.prefix(AccessibilityInventoryTuning.maximumDiagnosticFailures).map {
        AccessibilityScanFailure(processIdentifier: max(0, $0.processIdentifier),
          bundleIdentifier: bundleIdentifier($0.bundleIdentifier), operation: $0.operation, errorCode: $0.errorCode,
          elapsedMilliseconds: duration($0.elapsedMilliseconds), budgetExceeded: $0.budgetExceeded)
      }, budgetExceeded: metrics.budgetExceeded)
  }
}

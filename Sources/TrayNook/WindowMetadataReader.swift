import CoreGraphics
import Foundation

struct WindowMetadata: Equatable, Sendable {
  let id: UInt32
  let pid: Int32
  let frame: CGRect
  let isVisible: Bool

  /// Window IDs are raw values in a CFArray with no object callbacks, not NSNumbers.
  static func read(ids: [UInt32]) -> [WindowMetadata] {
    guard !ids.isEmpty else { return [] }
    var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = values.withUnsafeMutableBufferPointer({ values in
      CFArrayCreate(kCFAllocatorDefault, values.baseAddress, values.count, nil)
    }) else { return [] }
    let dictionaries = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
    return decode(dictionaries, requestedIDs: Set(ids))
  }

  static func decode(_ dictionaries: [[String: Any]], requestedIDs: Set<UInt32>) -> [WindowMetadata] {
    dictionaries.compactMap { item in
      guard let id = item[kCGWindowNumber as String] as? UInt32, requestedIDs.contains(id),
        let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        let bounds = item[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
        frame.width > 0, frame.height > 0 else { return nil }
      return WindowMetadata(id: id, pid: pid, frame: frame,
        isVisible: item[kCGWindowIsOnscreen as String] as? Bool == true)
    }
  }
}

/// One blocking query runs on a serial queue; only the newest pending request survives.
@MainActor
final class WindowMetadataReader {
  typealias Load = @Sendable ([UInt32]) -> [WindowMetadata]
  static let defaultReadTimeout: Duration = .seconds(1)
  private struct Request {
    let id: UUID
    let windowIDs: [UInt32]
    let deadline: ContinuousClock.Instant
    let deadlineTask: Task<Void, Never>
    var continuation: CheckedContinuation<[WindowMetadata]?, Never>?
  }
  private let queue = DispatchQueue(label: "TrayNook.WindowMetadata", qos: .utility)
  private let load: Load
  private let timeout: Duration
  private var active: Request?
  private var pending: Request?
  private var stopped = false
  private var latestRequestID: UUID?

  init(timeout: Duration = defaultReadTimeout, load: @escaping Load = WindowMetadata.read) {
    self.timeout = timeout
    self.load = load
  }

  func read(_ windowIDs: [UInt32]) async -> [WindowMetadata]? {
    let id = UUID()
    let result: [WindowMetadata]? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !stopped, !Task.isCancelled else { continuation.resume(returning: nil); return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let deadlineTask = Task { [weak self] in
          do { try await ContinuousClock().sleep(until: deadline) }
          catch { return }
          self?.cancel(id)
        }
        let request = Request(id: id, windowIDs: windowIDs, deadline: deadline,
          deadlineTask: deadlineTask, continuation: continuation)
        latestRequestID = id
        if active == nil { start(request) }
        else {
          pending?.deadlineTask.cancel()
          pending?.continuation?.resume(returning: nil)
          pending = request
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(id) }
    }
    return Task.isCancelled ? nil : result
  }

  func cancelAll() {
    latestRequestID = nil
    active?.deadlineTask.cancel()
    active?.continuation?.resume(returning: nil)
    active?.continuation = nil
    pending?.deadlineTask.cancel()
    pending?.continuation?.resume(returning: nil)
    pending = nil
  }

  func shutdown() {
    stopped = true
    cancelAll()
  }

  private func cancel(_ id: UUID) {
    if active?.id == id {
      active?.deadlineTask.cancel()
      active?.continuation?.resume(returning: nil)
      active?.continuation = nil
    }
    if pending?.id == id {
      pending?.deadlineTask.cancel()
      pending?.continuation?.resume(returning: nil)
      pending = nil
    }
  }

  private func start(_ request: Request) {
    guard ContinuousClock.now < request.deadline else {
      request.deadlineTask.cancel()
      request.continuation?.resume(returning: nil)
      return
    }
    active = request
    let id = request.id
    let windowIDs = request.windowIDs
    let load = load
    queue.async { [weak self] in
      let result = autoreleasepool { load(windowIDs) }
      Task { @MainActor [weak self] in self?.finish(id, result: result) }
    }
  }

  private func finish(_ id: UUID, result: [WindowMetadata]) {
    guard active?.id == id else { return }
    active?.deadlineTask.cancel()
    let fresh = active.map { ContinuousClock.now < $0.deadline } == true
    active?.continuation?.resume(returning: !stopped && latestRequestID == id && fresh ? result : nil)
    active = nil
    guard !stopped, let next = pending else { return }
    pending = nil
    start(next)
  }
}

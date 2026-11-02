import AppKit
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Targeted window metadata")
struct WindowMetadataTests {
  @Test("Targeted dictionaries retain offscreen controls and omit missing or invalid IDs")
  func decodeTargetedWindows() {
    let offscreen = CGRect(x: -2000, y: 0, width: 2578, height: 37)
    let dictionaries: [[String: Any]] = [
      dictionary(id: 20, frame: CGRect(x: 1500, y: 0, width: 38, height: 37), visible: true),
      dictionary(id: 10, frame: offscreen, visible: false),
      dictionary(id: 30, frame: CGRect(x: 0, y: 0, width: 0, height: 37), visible: true),
      dictionary(id: 99, frame: offscreen, visible: false),
    ]
    let result = WindowMetadata.decode(dictionaries, requestedIDs: [10, 20, 30, 40])
    #expect(result.map(\.id) == [20, 10])
    #expect(result.first { $0.id == 10 }?.frame == offscreen)
    #expect(result.first { $0.id == 10 }?.isVisible == false)
    #expect(result.first { $0.id == 20 }?.pid == 100)
    #expect(WindowMetadata.read(ids: []).isEmpty)
  }

  @Test("A vanished or reassigned source window invalidates a snapshot; uncaptured sources remain valid")
  @MainActor
  func sourceWindowBindings() {
    func source(window: UInt32?) -> ClassifiedSourceItem {
      IdentityAssessor().classify([RawSourceItemObservation(runtimeID: "100:fixture", processIdentifier: 100,
        bundleIdentifier: "example.fixture", applicationName: "Fixture", role: "AXMenuBarItem",
        frame: ItemFrame(x: -100, y: 0, width: 24, height: 24), actions: ["AXPress"],
        metadata: LiveAccessibilityMetadata(), observedOrder: 0, statusWindowIdentifier: window)])[0]
    }
    let frame = CGRect(x: -100, y: 0, width: 24, height: 24)
    let original = WindowMetadata(id: 10, pid: 100, frame: frame, isVisible: false)
    #expect(NativeMenuBarController.preservesWindowBindings(of: [source(window: nil)], in: []))
    #expect(NativeMenuBarController.preservesWindowBindings(of: [source(window: 10)], in: [original]))
    #expect(!NativeMenuBarController.preservesWindowBindings(of: [source(window: 10)], in: []))
    #expect(!NativeMenuBarController.preservesWindowBindings(of: [source(window: 10)],
      in: [WindowMetadata(id: 10, pid: 200, frame: frame, isVisible: false)]))
    #expect(!NativeMenuBarController.preservesWindowBindings(of: [source(window: 10)], in: [original, original]))
  }

  private func dictionary(id: UInt32, frame: CGRect, visible: Bool) -> [String: Any] {
    [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: NSNumber(value: Int32(100)),
     kCGWindowBounds as String: frame.dictionaryRepresentation, kCGWindowIsOnscreen as String: visible]
  }
}

@Suite("Bounded background window reader", .serialized)
@MainActor
struct WindowMetadataReaderTests {
  @Test("Only the newest pending query runs and old results never publish")
  func coalescesPendingReads() async throws {
    let probe = BlockingWindowLoad()
    let reader = WindowMetadataReader(load: probe.load)
    defer { reader.shutdown(); probe.release(3) }
    let first = Task { await reader.read([1]) }
    try await waitUntil { probe.calls == [[1]] }
    var middleFinished = false
    let middle = Task {
      let result = await reader.read([2])
      middleFinished = true
      return result
    }
    await Task.yield()
    let last = Task { await reader.read([3]) }
    try await waitUntil { middleFinished }
    #expect(await middle.value == nil)
    #expect(probe.calls == [[1]])
    probe.release()
    #expect(await first.value == nil)
    try await waitUntil { probe.calls.count == 2 }
    #expect(probe.calls == [[1], [3]])
    probe.release()
    #expect(await last.value?.map(\.id) == [3])
    #expect(probe.maximumConcurrent == 1)
    #expect(!probe.ranOnMain)
  }

  @Test("Cancellation completes promptly while the blocking call retains its serial slot")
  func cancellationDoesNotOverlapQueries() async throws {
    let probe = BlockingWindowLoad()
    let reader = WindowMetadataReader(load: probe.load)
    defer { reader.shutdown(); probe.release(3) }
    let first = Task { await reader.read([1]) }
    try await waitUntil { probe.calls.count == 1 }
    first.cancel()
    #expect(await first.value == nil)
    var pendingFinished = false
    let pending = Task {
      let value = await reader.read([2])
      pendingFinished = true
      return value
    }
    await Task.yield()
    pending.cancel()
    #expect(await pending.value == nil)
    #expect(pendingFinished)
    let final = Task { await reader.read([3]) }
    await Task.yield()
    #expect(probe.calls == [[1]])
    probe.release()
    try await waitUntil { probe.calls.count == 2 }
    #expect(probe.calls == [[1], [3]])
    probe.release()
    #expect(await final.value?.map(\.id) == [3])
    #expect(probe.maximumConcurrent == 1)
  }

  @Test("Shutdown releases active and pending waiters and refuses later reads")
  func shutdownCompletesEveryWaiter() async throws {
    let probe = BlockingWindowLoad()
    let reader = WindowMetadataReader(load: probe.load)
    defer { reader.shutdown(); probe.release(3) }
    let active = Task { await reader.read([1]) }
    try await waitUntil { probe.calls.count == 1 }
    let pending = Task { await reader.read([2]) }
    await Task.yield()
    reader.shutdown()
    #expect(await active.value == nil)
    #expect(await pending.value == nil)
    #expect(await reader.read([3]) == nil)
    probe.release()
    try await Task.sleep(for: .milliseconds(10))
    #expect(probe.calls == [[1]])
  }

  @Test("Invalidating reads allows a new request without reviving the old result")
  func invalidationRemainsReusable() async throws {
    let probe = BlockingWindowLoad()
    let reader = WindowMetadataReader(load: probe.load)
    defer { reader.shutdown(); probe.release(3) }
    let old = Task { await reader.read([1]) }
    try await waitUntil { probe.calls.count == 1 }
    reader.cancelAll()
    #expect(await old.value == nil)
    let current = Task { await reader.read([2]) }
    probe.release()
    try await waitUntil { probe.calls.count == 2 }
    probe.release()
    #expect(await current.value?.map(\.id) == [2])
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition(), "The serial reader did not reach the expected state.")
  }
}

private final class BlockingWindowLoad: @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var recordedCalls: [[UInt32]] = []
  private var concurrent = 0
  private var maximum = 0
  private var onMain = false

  var calls: [[UInt32]] { lock.withLock { recordedCalls } }
  var maximumConcurrent: Int { lock.withLock { maximum } }
  var ranOnMain: Bool { lock.withLock { onMain } }

  func load(_ ids: [UInt32]) -> [WindowMetadata] {
    lock.withLock {
      recordedCalls.append(ids)
      concurrent += 1
      maximum = max(maximum, concurrent)
      onMain = onMain || Thread.isMainThread
    }
    gate.wait()
    lock.withLock { concurrent -= 1 }
    return ids.map { WindowMetadata(id: $0, pid: 100, frame: CGRect(x: 0, y: 0, width: 24, height: 24), isVisible: true) }
  }

  func release(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }
}

@Suite("Latest native inspection", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct LatestNativeInspectionTests {
  @Test("A control resize or Reveal while a query runs discards its result")
  func staleControlsNeverProduceInspection() async throws {
    for id in ["io.github.mahenzon.TrayNook", "io.github.mahenzon.TrayNook.dev"] {
      try #require(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
        "Quit TrayNook before creating the isolated visible controls.")
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let defaults = UserDefaults.standard
    let keys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let previous = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    let probe = BlockingWindowLoad()
    let reader = WindowMetadataReader(load: probe.load)
    let launcher = NSStatusBar.system.statusItem(withLength: 24)
    let native = NativeMenuBarController(launcher: launcher, metadataReader: reader)
    native.reveal(keepBoundaryVisible: true)
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      probe.release(4)
      for key in keys {
        if let value = previous[key] { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
      defaults.synchronize()
    }
    try await Task.sleep(for: .milliseconds(250))
    let unchanged = Task { await native.inspectLatest([]) }
    try await waitUntil { probe.calls.count == 1 }
    probe.release()
    #expect(await unchanged.value != nil)

    let resized = Task { await native.inspectLatest([]) }
    try await waitUntil { probe.calls.count == 2 }
    let width = try #require(launcher.button?.bounds.width)
    launcher.length = 64
    try await waitUntil { launcher.button?.bounds.width != width }
    probe.release()
    #expect(await resized.value == nil)

    let revealed = Task { await native.inspectLatest([]) }
    try await waitUntil { probe.calls.count == 3 }
    native.reveal()
    #expect(await revealed.value == nil)
    probe.release()
    #expect(probe.maximumConcurrent == 1)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition(), "The isolated native inspection did not reach the expected state.")
  }
}

import AppKit
import InventoryIdentityCore
import Testing

@testable import TrayNook

@MainActor
@Test("Reorder binds an entire row from one read and rejects a replacement in the next phase")
func reorderReadbackUsesOneSnapshot() throws {
  let row = ItemFrame(x: 0, y: 0, width: 1200, height: 24)
  let observations = (1...12).map { index in
    RawSourceItemObservation(runtimeID: "100:\(index)", processIdentifier: 100,
      bundleIdentifier: "example.siblings", applicationName: "Siblings", role: "AXMenuBarItem",
      frame: ItemFrame(x: Double(index * 30), y: 0, width: 24, height: 24),
      actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: index,
      isOnscreen: true, statusWindowIdentifier: UInt32(index))
  }
  let items = IdentityAssessor().classify(observations)
  let visibleKeys = Set(items.compactMap(\.identity.persistentKey))
  #expect(visibleKeys.count == observations.count)
  let windows: [NativeMenuBarController.StatusWindow] = try observations.map { observation in
    (.init(id: try #require(observation.statusWindowIdentifier), pid: observation.processIdentifier,
      bundle: observation.bundleIdentifier), try #require(observation.frame), true)
  }
  var reads = 0
  let before = NativeMenuBarController.ReorderWindowSnapshot(row: row) {
    reads += 1
    return windows
  }
  #expect(before.bindings(for: items, visibleKeys: visibleKeys)?.count == windows.count)
  #expect(reads == 1)
  let after = NativeMenuBarController.ReorderWindowSnapshot(row: row) {
    reads += 1
    var current = windows
    current[0].binding = .init(id: 1000, pid: 100, bundle: "example.siblings")
    return current
  }
  #expect(after.rowBindings != before.rowBindings)
  #expect(after.bindings(for: items, visibleKeys: visibleKeys) == nil)
  #expect(reads == 2)
}

@Suite("Menu Bar reorder application", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
@MainActor
struct MenuBarReorderTests {
  @Test("Closing Settings immediately after a preview drop preserves the saved order")
  func dropSurvivesSettingsClose() async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.release(); fixture.close() }
    let model = fixture.model
    let drag = PreviewDragSession()
    fixture.recorder.holdNextRequest = true
    try #require(drag.begin(Fixture.tunnelblick, layout: model.layout) { key, placement, anchor in
      model.commitPreviewMove(key, to: placement, before: anchor)
    })
    drag.move(to: .menuBar, before: Fixture.broglow)
    model.undoManager.beginUndoGrouping()
    let dropped = drag.drop()
    drag.cancel() // LayoutPreviewView.onDisappear when Settings closes.
    model.undoManager.endUndoGrouping()
    try #require(dropped)

    let expected = [Fixture.tunnelblick, Fixture.broglow]
    #expect(try fixture.store.load().items.prefix(2).map(\.id) == expected)
    await fixture.waitForRequestCount(1)
    #expect(model.busy)
    fixture.recorder.release()
    await fixture.settle()
    #expect(fixture.recorder.requests == [expected])
    #expect(try fixture.store.load() == model.layout)
  }

  @Test("A preview reorder applies native order, including Undo and Redo")
  func previewAppliesOrder() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let original = model.layout
    model.undoManager.beginUndoGrouping()
    #expect(model.commitPreviewMove(Fixture.tunnelblick, to: .menuBar, before: Fixture.broglow))
    model.undoManager.endUndoGrouping()
    await fixture.settle()
    #expect(fixture.recorder.requests == [[Fixture.tunnelblick, Fixture.broglow]])
    #expect(try fixture.store.load() == model.layout)
    #expect(model.undoManager.canUndo)

    model.undoManager.undo()
    await fixture.settle()
    #expect(model.layout == original)
    #expect(fixture.recorder.requests == [
      [Fixture.tunnelblick, Fixture.broglow], [Fixture.broglow, Fixture.tunnelblick],
    ])
    #expect(model.undoManager.canRedo)
    model.undoManager.redo()
    await fixture.settle()
    #expect(fixture.recorder.requests == [
      [Fixture.tunnelblick, Fixture.broglow], [Fixture.broglow, Fixture.tunnelblick],
      [Fixture.tunnelblick, Fixture.broglow],
    ])
    #expect(try fixture.store.load() == model.layout)
    #expect(fixture.recorder.reveals == 0)
  }

  @Test("Detail dragging applies native order only after the completed drop")
  func detailDropAppliesOrder() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let original = model.layout
    let session = DetailReorderSession()
    let lane = original.items.filter { [Fixture.broglow, Fixture.tunnelblick].contains($0.id) }
    #expect(session.begin(Fixture.broglow, layout: original, lane: lane,
      rowHeights: [:], rowSpacing: 8) { model.setOrder($0, undoable: true) })
    session.update(translation: 31)
    #expect(model.layout == original)
    #expect(fixture.recorder.requests.isEmpty)
    model.undoManager.beginUndoGrouping()
    session.finish(currentLayout: model.layout)
    model.undoManager.endUndoGrouping()
    await fixture.settle()
    #expect(fixture.recorder.requests == [[Fixture.tunnelblick, Fixture.broglow]])
    #expect(try fixture.store.load() == model.layout)
    #expect(model.undoManager.canUndo)
    model.undoManager.undo()
    await fixture.settle()
    #expect(model.layout == original)
    #expect(fixture.recorder.requests.last == [Fixture.broglow, Fixture.tunnelblick])
    #expect(fixture.recorder.reveals == 0)
  }

  @Test("No-op, Dropdown-only, missing, and protected edits do not request native order")
  func irrelevantEditsDoNotMoveSources() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let model = fixture.model
    let original = model.layout
    model.undoManager.beginUndoGrouping()
    #expect(model.commitPreviewMove(Fixture.broglow, to: .menuBar, before: Fixture.tunnelblick))
    model.setOrder([Fixture.broglow, Fixture.tunnelblick], undoable: true)
    model.undoManager.endUndoGrouping()
    #expect(model.layout == original)
    model.undoManager.beginUndoGrouping()
    defer { model.undoManager.endUndoGrouping() }
    #expect(!model.commitPreviewMove(Fixture.missing, to: .menuBar, before: Fixture.broglow))
    #expect(!model.commitPreviewMove(Fixture.protected, to: .menuBar, before: Fixture.broglow))
    #expect(model.commitPreviewMove(Fixture.dropdownFirst, to: .dropdown))
    model.setOrder([Fixture.dropdownFirst, Fixture.dropdownSecond], undoable: true)
    model.setOrder([Fixture.protected, Fixture.missing], undoable: true)
    await fixture.settle()
    #expect(fixture.recorder.requests.isEmpty)
    #expect(!model.busy)
  }

  @Test("Native failure retains the requested saved order and keeps other items concealed")
  func failedNativeOrderRetainsDesiredLayout() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    fixture.recorder.failure = AppError.message("fixture native order failure")
    let model = fixture.model
    model.undoManager.beginUndoGrouping()
    model.setOrder([Fixture.tunnelblick, Fixture.broglow], undoable: true)
    model.undoManager.endUndoGrouping()
    await fixture.settle()
    #expect(fixture.recorder.requests == [[Fixture.tunnelblick, Fixture.broglow]])
    #expect(model.layout.items.filter { [Fixture.broglow, Fixture.tunnelblick].contains($0.id) }.map(\.id)
      == [Fixture.tunnelblick, Fixture.broglow])
    #expect(try fixture.store.load() == model.layout)
    #expect(model.message == "fixture native order failure")
    #expect(fixture.recorder.reveals == 0)
    #expect(!model.busy)
  }

  @Test("Restore All orders the merged lanes, and only a current Redo replays that order",
    arguments: [false, true])
  func restoreAllAndRedoOrder(externalReveal: Bool) async throws {
    let fixture = try Fixture(restoreLayout: true)
    defer { fixture.recorder.release(); fixture.close() }
    let model = fixture.model
    let original = model.layout
    let merged = [Fixture.broglow, Fixture.tunnelblick, Fixture.dropdownFirst, Fixture.dropdownSecond]
    fixture.recorder.holdNextRequest = true
    model.undoManager.beginUndoGrouping()
    model.restoreAll()
    model.undoManager.endUndoGrouping()
    await fixture.waitForRequestCount(1)
    #expect(fixture.recorder.requests == [merged])
    #expect(model.layout.items.map(\.id) == [
      Fixture.broglow, Fixture.tunnelblick, Fixture.missing, Fixture.protected,
      Fixture.dropdownFirst, Fixture.dropdownSecond,
    ])
    #expect(model.layout.items.allSatisfy { $0.placement == .menuBar })
    #expect(try fixture.store.load() == model.layout)

    model.undoManager.undo()
    #expect(model.layout == original)
    #expect(try fixture.store.load() == original)
    model.undoManager.redo()
    #expect(model.pendingMenuBarOrder?.compactMap(\.identity.persistentKey) == merged)
    if externalReveal { fixture.notifyExternalReveal() }
    fixture.recorder.release()
    await fixture.settle()
    #expect(fixture.recorder.requests == (externalReveal ? [merged] : [merged, merged]))
    #expect(model.pendingMenuBarOrder == nil)
    #expect(model.layout.items.allSatisfy { $0.placement == .menuBar })
    #expect(try fixture.store.load() == model.layout)
    #expect(!model.concealed)
  }

  @Test("Restore All stays revealed and keeps saved placements when ordering is deferred")
  func restoreAllRetainsPlacementOnNativeFailure() async throws {
    let fixture = try Fixture(restoreLayout: true)
    defer { fixture.close() }
    let model = fixture.model
    fixture.recorder.failure = NativeMenuActionError.inputNotIdle
    model.undoManager.beginUndoGrouping()
    model.restoreAll()
    model.undoManager.endUndoGrouping()
    await fixture.settle()
    #expect(fixture.recorder.requests == [[
      Fixture.broglow, Fixture.tunnelblick, Fixture.dropdownFirst, Fixture.dropdownSecond,
    ]])
    #expect(model.layout.items.allSatisfy { $0.placement == .menuBar })
    #expect(try fixture.store.load() == model.layout)
    #expect(model.message == NativeMenuActionError.inputNotIdle.localizedDescription)
    #expect(!model.concealed)
  }

  @Test("Undo during a native move applies the restored order after the in-flight request")
  func undoQueuesLatestOrder() async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.release(); fixture.close() }
    let model = fixture.model
    let original = model.layout
    fixture.recorder.holdNextRequest = true
    model.undoManager.beginUndoGrouping()
    model.setOrder([Fixture.tunnelblick, Fixture.broglow], undoable: true)
    model.undoManager.endUndoGrouping()
    await fixture.waitForRequestCount(1)
    #expect(model.busy)
    model.undoManager.undo()
    #expect(model.layout == original)
    #expect(fixture.recorder.requests == [[Fixture.tunnelblick, Fixture.broglow]])
    fixture.recorder.release()
    await fixture.settle()
    #expect(fixture.recorder.requests == [
      [Fixture.tunnelblick, Fixture.broglow], [Fixture.broglow, Fixture.tunnelblick],
    ])
    #expect(try fixture.store.load() == original)
    #expect(fixture.recorder.reveals == 0)
  }

  @Test("An external reveal discards queued order work before cancelling the in-flight move")
  func externalRevealDiscardsQueuedOrder() async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.release(); fixture.close() }
    let model = fixture.model
    let original = model.layout
    fixture.recorder.holdNextRequest = true
    model.undoManager.beginUndoGrouping()
    model.setOrder([Fixture.tunnelblick, Fixture.broglow], undoable: true)
    model.undoManager.endUndoGrouping()
    await fixture.waitForRequestCount(1)
    model.undoManager.undo()
    #expect(model.layout == original)
    #expect(model.pendingMenuBarOrder?.compactMap(\.identity.persistentKey)
      == [Fixture.broglow, Fixture.tunnelblick])
    fixture.notifyExternalReveal()
    #expect(model.pendingMenuBarOrder == nil)
    fixture.recorder.release()
    await fixture.settle()
    #expect(fixture.recorder.requests == [[Fixture.tunnelblick, Fixture.broglow]])
    #expect(model.pendingMenuBarOrder == nil)
    #expect(try fixture.store.load() == original)
    #expect(!model.busy)
  }
}

@MainActor
private final class OrderRecorder {
  weak var model: AppModel?
  var requests: [[String]] = []
  var reveals = 0
  var failure: Error?
  var holdNextRequest = false
  private var continuation: CheckedContinuation<Void, Never>?

  func apply(_ items: [ClassifiedSourceItem]) async throws {
    requests.append(items.compactMap(\.identity.persistentKey))
    // Stand in for an active inventory scan so operation completion never scans the real desktop.
    model?.scanning = true
    if holdNextRequest {
      holdNextRequest = false
      await withCheckedContinuation { continuation = $0 }
    }
    if let failure { throw failure }
  }

  func release() {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume()
  }
}

@MainActor
private final class Fixture {
  static let broglow = "example.broglow"
  static let tunnelblick = "example.tunnelblick"
  static let missing = "example.missing"
  static let protected = "com.apple.controlcenter"
  static let dropdownFirst = "example.dropdown.first"
  static let dropdownSecond = "example.dropdown.second"

  let model: AppModel
  let recorder = OrderRecorder()
  let store: LayoutStore
  private let launcher: NSStatusItem
  private let native: NativeMenuBarController
  private let directory: URL
  private let preferenceKeys: [String]
  private let previousPreferences: [String: Any]

  init(restoreLayout: Bool = false) throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    preferenceKeys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let defaults = UserDefaults.standard
    previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = LayoutStore(url: directory.appendingPathComponent("layout.json"))
    var layout = SavedLayout(items: [
      SavedItem(id: Self.broglow), SavedItem(id: Self.tunnelblick), SavedItem(id: Self.missing),
      SavedItem(id: Self.protected), SavedItem(id: Self.dropdownFirst, placement: .dropdown),
      SavedItem(id: Self.dropdownSecond, placement: .dropdown),
    ])
    if restoreLayout {
      layout.items.removeLast()
      layout.items.insert(SavedItem(id: Self.dropdownSecond, placement: .alwaysHidden), at: 0)
    }
    try store.save(layout)
    launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    native = NativeMenuBarController(launcher: launcher)
    let recorder = recorder
    model = AppModel(native: native, store: store, applyMenuBarOrder: { try await recorder.apply($0) })
    recorder.model = model
    let onReveal = native.onReveal
    native.onReveal = { recorder.reveals += 1; onReveal?() }
    model.permissionGranted = true
    model.scanComplete = true
    model.undoManager.groupsByEvent = false
    model.items = IdentityAssessor().classify(layout.items.enumerated().compactMap { index, saved in
      guard saved.id != Self.missing else { return nil }
      return RawSourceItemObservation(runtimeID: "fixture:\(index)", processIdentifier: Int32(100 + index),
        bundleIdentifier: saved.id, applicationName: saved.id, role: "AXMenuBarItem",
        frame: ItemFrame(x: 1200 + Double(index * 24), y: 0, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(identifierCandidate: "fixture"),
        observedOrder: index)
    })
  }

  func settle() async {
    for _ in 0..<1_000 {
      if !model.busy { return }
      await Task.yield()
    }
    Issue.record("The synthetic native-order operation did not finish")
  }

  func waitForRequestCount(_ count: Int) async {
    for _ in 0..<1_000 {
      if recorder.requests.count >= count { return }
      await Task.yield()
    }
    Issue.record("The synthetic native-order request was not delivered")
  }

  func notifyExternalReveal() {
    native.onExternalReveal?()
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
    try? FileManager.default.removeItem(at: directory)
  }
}

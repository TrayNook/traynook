import AppKit
import Combine
import Testing

@testable import TrayNook

@Suite("Detail row drag transaction")
@MainActor
struct DetailReorderTests {
  @Test("Crossing rows edits a local draft, then saves once with one Undo",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  func doesNotSaveDuringDrag() throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let native = NativeMenuBarController(launcher: launcher)
    defer {
      native.remove()
      NSStatusBar.system.removeStatusItem(launcher)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutStore(url: directory.appendingPathComponent("layout.json"))
    let original = SavedLayout(items: (0..<24).map { SavedItem(id: "example.app\($0)") })
    try store.save(original)
    let model = AppModel(native: native, store: store)
    model.permissionGranted = true
    model.scanComplete = true
    model.undoManager.groupsByEvent = false
    let session = DetailReorderSession()
    var commits = 0
    #expect(session.begin("example.app0", layout: model.layout, lane: model.layout.items,
      rowHeights: [:], rowSpacing: 8) { keys in
      commits += 1
      model.setOrder(keys, undoable: true)
    })
    let start = ContinuousClock.now
    for index in 0..<30 {
      session.update(translation: index.isMultiple(of: 2) ? 31 : 80)
      #expect(model.layout == original)
      #expect(try store.load() == original)
    }
    print("DETAIL_DRAG_DRAFT: 30 crossed rows, \(commits) commits, \(start.duration(to: .now))")
    #expect(commits == 0)
    model.undoManager.beginUndoGrouping()
    session.finish(currentLayout: model.layout)
    model.undoManager.endUndoGrouping()
    #expect(commits == 1)
    #expect(model.layout.items.prefix(3).map(\.id) == ["example.app1", "example.app2", "example.app0"])
    #expect(try store.load() == model.layout)
    #expect(model.undoManager.canUndo)
    model.undoManager.undo()
    #expect(model.layout == original)
    #expect(!model.undoManager.canUndo)
    model.undoManager.redo()
    #expect(model.layout.items.prefix(3).map(\.id) == ["example.app1", "example.app2", "example.app0"])
    #expect(try store.load() == model.layout)
  }

  @Test("Pointer motion inside a slot does not invalidate the lane")
  func isolatesPointerUpdates() {
    let layout = SavedLayout(items: [SavedItem(id: "example.first"), SavedItem(id: "example.second")])
    let session = DetailReorderSession()
    #expect(session.begin("example.first", layout: layout, lane: layout.items,
      rowHeights: [:], rowSpacing: 8) { _ in Issue.record("Movement must not commit") })
    var publications = 0
    let subscription = session.objectWillChange.sink { publications += 1 }
    for translation in 1...20 { session.update(translation: CGFloat(translation)) }
    #expect(publications == 0)
    #expect(session.pointer.offset == 20)
    session.update(translation: 31)
    #expect(publications == 1)
    #expect(session.order == ["example.second", "example.first"])
    #expect(session.pointer.offset == -21)
    withExtendedLifetime(subscription) {}
  }

  @Test("Cancel, unchanged drags, and a concurrent layout edit do not commit")
  func discardsIncompleteDrags() {
    let layout = SavedLayout(items: [SavedItem(id: "example.first"), SavedItem(id: "example.second")])
    let session = DetailReorderSession()
    var commits = 0
    func begin(_ key: String = "example.first") -> Bool {
      session.begin(key, layout: layout, lane: layout.items,
        rowHeights: [:], rowSpacing: 8) { _ in commits += 1 }
    }
    #expect(!begin("example.missing"))
    #expect(begin())
    #expect(!begin())
    session.update(translation: 31)
    session.cancel()
    #expect(session.key == nil && session.order == nil && session.pointer.offset == 0)
    #expect(begin())
    session.finish(currentLayout: layout)
    #expect(begin())
    session.update(translation: 31)
    var changed = layout
    changed.rowCapacity = 5
    session.finish(currentLayout: changed)
    #expect(commits == 0)
    #expect(session.key == nil && session.order == nil)
  }

  @Test("Upward movement uses measured row heights and can return to its origin")
  func respectsRowHeights() {
    let layout = SavedLayout(items: [SavedItem(id: "example.first"), SavedItem(id: "example.second"),
      SavedItem(id: "example.third")])
    let session = DetailReorderSession()
    #expect(session.begin("example.third", layout: layout, lane: layout.items,
      rowHeights: ["example.first": 20, "example.second": 60], rowSpacing: 8) { _ in
      Issue.record("Returning to the starting order must not commit")
    })
    session.update(translation: -35)
    #expect(session.order == ["example.first", "example.third", "example.second"])
    #expect(session.pointer.offset == 33)
    session.update(translation: -85)
    #expect(session.order == ["example.third", "example.first", "example.second"])
    #expect(session.pointer.offset == 11)
    session.update(translation: 0)
    #expect(session.order == layout.items.map(\.id))
    session.finish(currentLayout: layout)
  }
}

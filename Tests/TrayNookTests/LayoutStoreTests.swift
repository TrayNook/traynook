import Foundation
import Testing

@testable import TrayNook

@Suite("Saved layout")
struct LayoutStoreTests {
  @Test("Round trip persists only bundle identity, placement, and preferences")
  func roundTrip() throws {
    try withStore { store in
      let layout = SavedLayout(rowCapacity: 7, items: [
        SavedItem(id: "example.timer", placement: .dropdown),
        SavedItem(id: "example.helper", placement: .alwaysHidden),
      ])
      try store.save(layout)
      #expect(try store.load() == layout)

      let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
      )
      #expect(Set(object.keys) == ["version", "rowCapacity", "items"])
      let items = try #require(object["items"] as? [[String: Any]])
      #expect(items.count == 2)
      #expect(items.allSatisfy { Set($0.keys) == ["id", "placement"] })
      #expect(items.compactMap { $0["id"] as? String } == layout.items.map(\.id))
    }
  }

  @Test("Unreadable and newer layouts remain untouched", arguments: [
    "not JSON",
    #"{"version":2,"rowCapacity":10,"items":[]}"#,
    #"{"version":1,"rowCapacity":10,"items":[{"id":"example.app","placement":"unknown"}]}"#,
  ])
  func preservesUnreadableData(_ contents: String) throws {
    try withStore { store in
      let original = Data(contents.utf8)
      try FileManager.default.createDirectory(
        at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try original.write(to: store.url)

      #expect(throws: (any Error).self) { try store.load() }
      #expect(try Data(contentsOf: store.url) == original)
    }
  }

  @Test("Malformed and duplicate saved identities cannot replace a valid file")
  func rejectsInvalidIdentities() throws {
    try withStore { store in
      let original = SavedLayout(items: [SavedItem(id: "example.original")])
      try store.save(original)
      let originalData = try Data(contentsOf: store.url)
      let invalidItems = [
        [SavedItem(id: "")],
        [SavedItem(id: "not-a-bundle")],
        [SavedItem(id: "example. app")],
        [SavedItem(id: "example." + String(repeating: "x", count: 256))],
        [SavedItem(id: "example.duplicate"), SavedItem(id: "example.duplicate", placement: .dropdown)],
      ]
      for items in invalidItems {
        #expect(throws: LayoutError.self) { try store.save(SavedLayout(items: items)) }
        #expect(try Data(contentsOf: store.url) == originalData)
      }
      #expect(try store.load() == original)
    }
  }

  @Test("Restore All merges the three zones while retaining their internal order")
  func restoresZoneOrder() {
    var layout = SavedLayout(items: [
      SavedItem(id: "example.hidden1", placement: .alwaysHidden),
      SavedItem(id: "example.dropdown1", placement: .dropdown),
      SavedItem(id: "example.menu1"),
      SavedItem(id: "example.hidden2", placement: .alwaysHidden),
      SavedItem(id: "example.menu2"),
      SavedItem(id: "example.dropdown2", placement: .dropdown),
    ])
    layout.restoreAll()

    #expect(layout.items.map(\.id) == [
      "example.menu1", "example.menu2", "example.dropdown1",
      "example.dropdown2", "example.hidden1", "example.hidden2",
    ])
    #expect(layout.items.allSatisfy { $0.placement == .menuBar })
    let restored = layout
    layout.restoreAll()
    #expect(layout == restored)
  }

  @Test("Row capacity rejects values outside one through thirty")
  func validatesRowCapacity() throws {
    for count in [-1, 0, 31, Int.max] {
      #expect(throws: LayoutError.self) { try SavedLayout(rowCapacity: count).validated() }
    }
    for count in [1, 10, 30] {
      #expect(try SavedLayout(rowCapacity: count).validated().rowCapacity == count)
    }
  }

  private func withStore(_ body: (LayoutStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("TrayNookLayoutTests-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(LayoutStore(url: directory.appendingPathComponent("nested/layout.json")))
  }
}

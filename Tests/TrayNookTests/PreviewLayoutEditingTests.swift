import Foundation
import Testing

@testable import TrayNook

@Suite("Preview layout editing")
struct PreviewLayoutEditingTests {
  private let layout = SavedLayout(rowCapacity: 3, items: [
    SavedItem(id: "example.first", placement: .dropdown),
    SavedItem(id: "example.bar"),
    SavedItem(id: "example.missing", placement: .dropdown),
    SavedItem(id: "example.second", placement: .dropdown),
    SavedItem(id: "example.hidden", placement: .alwaysHidden),
    SavedItem(id: "example.third", placement: .dropdown),
  ])

  @Test("Reordering preserves unrelated items and handles both directions")
  func reordersWithinLane() throws {
    let forward = try #require(layout.moving("example.first", to: .dropdown, before: "example.third"))
    #expect(forward.items.filter { $0.placement == .dropdown }.map(\.id) == [
      "example.missing", "example.second", "example.first", "example.third",
    ])
    #expect(forward.items.filter { $0.id != "example.first" } == layout.items.filter { $0.id != "example.first" })
    #expect(forward.rowCapacity == 3)
    #expect(forward.version == layout.version)

    let backward = try #require(forward.moving("example.first", to: .dropdown, before: "example.missing"))
    #expect(backward.items.filter { $0.placement == .dropdown }.map(\.id)
      == layout.items.filter { $0.placement == .dropdown }.map(\.id))
  }

  @Test("A cross-zone drop inserts at the chosen position or end")
  func changesPlacement() throws {
    let before = try #require(layout.moving("example.hidden", to: .dropdown, before: "example.second"))
    #expect(before.items.filter { $0.placement == .dropdown }.map(\.id) == [
      "example.first", "example.missing", "example.hidden", "example.second", "example.third",
    ])
    #expect(!before.items.contains { $0.placement == .alwaysHidden })
    #expect(before.items.filter { $0.id != "example.hidden" } == layout.items.filter { $0.id != "example.hidden" })

    let end = try #require(layout.moving("example.hidden", to: .dropdown))
    #expect(end.items.filter { $0.placement == .dropdown }.last?.id == "example.hidden")
    #expect(end.items.count == layout.items.count)
    #expect(Set(end.items.map(\.id)) == Set(layout.items.map(\.id)))
  }

  @Test("An empty zone accepts its first item without changing other placements")
  func emptyDestination() throws {
    let original = SavedLayout(items: [SavedItem(id: "example.first"), SavedItem(id: "example.second")])
    let moved = try #require(original.moving("example.first", to: .alwaysHidden))
    #expect(moved.items.first(where: { $0.id == "example.first" })?.placement == .alwaysHidden)
    #expect(moved.items.first(where: { $0.id == "example.second" }) == original.items[1])
  }

  @Test("Visual no-ops keep the complete layout unchanged")
  func unchangedDrops() {
    // A different zone's saved key between two icons must not create a change.
    #expect(layout.moving("example.first", to: .dropdown, before: "example.missing") == layout)
    #expect(layout.moving("example.third", to: .dropdown) == layout)
    #expect(layout.moving("example.first", to: .dropdown, before: "example.first") == layout)
  }

  @Test("Unknown keys, invalid anchors, and duplicate layouts are rejected")
  func rejectsInvalidMoves() {
    #expect(layout.moving("example.unknown", to: .dropdown) == nil)
    #expect(layout.moving("example.first", to: .dropdown, before: "example.unknown") == nil)
    #expect(layout.moving("example.first", to: .dropdown, before: "example.bar") == nil)
    #expect(layout.moving("example.first", to: .menuBar, before: "example.first") == nil)
    var duplicate = layout
    duplicate.items.append(layout.items[0])
    #expect(duplicate.moving("example.first", to: .menuBar) == nil)
    var malformed = layout
    malformed.rowCapacity = 0
    #expect(malformed.moving("example.first", to: .menuBar) == nil)
  }

  @Test("A dropped layout round-trips as one complete saved layout")
  func persistsMove() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrayNookPreview-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutStore(url: directory.appendingPathComponent("layout.json"))
    try store.save(layout)
    let moved = try #require(layout.moving("example.hidden", to: .dropdown, before: "example.second"))
    #expect(try store.load() == layout)
    try store.save(moved)
    #expect(try store.load() == moved)
  }
}

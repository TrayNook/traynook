import Testing

@testable import TrayNook

@Suite("Preview drag transaction")
@MainActor
struct PreviewDragSessionTests {
  private let layout = SavedLayout(items: [
    SavedItem(id: "example.first", placement: .dropdown),
    SavedItem(id: "example.second", placement: .dropdown),
    SavedItem(id: "example.hidden", placement: .alwaysHidden),
  ])

  @Test("Hover changes only the draft and a completed drop commits exactly once")
  func commitsOnce() throws {
    let session = PreviewDragSession()
    var commits: [(String, Placement, String?)] = []
    #expect(session.begin("example.first", layout: layout) { key, zone, anchor in
      commits.append((key, zone, anchor)); return true
    })
    session.move(to: .alwaysHidden, before: "example.hidden")
    #expect(session.hoveredZone == .alwaysHidden)
    session.leave(.dropdown)
    #expect(session.hoveredZone == .alwaysHidden)
    session.leave(.alwaysHidden)
    #expect(session.hoveredZone == nil)
    session.move(to: .alwaysHidden, before: nil)
    #expect(commits.isEmpty)
    #expect(session.draft?.items.last?.id == "example.first")
    #expect(session.drop())
    #expect(commits.count == 1)
    #expect(commits.first?.0 == "example.first")
    #expect(commits.first?.1 == .alwaysHidden)
    #expect(commits.first?.2 == nil)
    #expect(session.key == nil && session.draft == nil)
    #expect(!session.drop())
    #expect(commits.count == 1)
  }

  @Test("Cancel and unchanged drops discard the draft without saving")
  func cancelsAndNoOps() {
    let session = PreviewDragSession()
    var committed = false
    #expect(session.begin("example.first", layout: layout) { _, _, _ in committed = true; return true })
    session.move(to: .menuBar, before: nil)
    session.cancel()
    #expect(!committed && session.draft == nil && session.key == nil)
    #expect(session.begin("example.first", layout: layout) { _, _, _ in committed = true; return true })
    #expect(session.drop())
    #expect(!committed)
  }

  @Test("A rejected drop clears transient state and a new drag starts cleanly")
  func rejectsStaleDrop() {
    let session = PreviewDragSession()
    #expect(session.begin("example.first", layout: layout) { _, _, _ in false })
    session.move(to: .menuBar, before: nil)
    #expect(!session.drop())
    #expect(session.key == nil && session.destination == nil && session.draft == nil)
    #expect(session.begin("example.second", layout: layout) { _, _, _ in true })
    #expect(!session.begin("example.first", layout: layout) { _, _, _ in true })
    session.cancel()
    #expect(!session.begin("example.unknown", layout: layout) { _, _, _ in true })
  }
}

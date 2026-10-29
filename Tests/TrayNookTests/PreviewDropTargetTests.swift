import Foundation
import Testing

@testable import TrayNook

@Suite("Preview drop insertion geometry")
struct PreviewDropTargetTests {
  private let row = [
    (key: "a", frame: CGRect(x: 10, y: 10, width: 30, height: 30)),
    (key: "b", frame: CGRect(x: 54, y: 10, width: 30, height: 30)),
    (key: "c", frame: CGRect(x: 98, y: 10, width: 30, height: 30)),
  ]

  @Test("Each icon's leading half inserts before it; trailing halves advance")
  func iconHalves() {
    for (x, expected) in [(0.0, "a"), (24, "a"), (25, "b"), (40, "b"), (68, "b"), (69, "c"), (112, "c")] {
      #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: x, y: 25), items: row) == expected)
    }
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 113, y: 25), items: row) == nil)
  }

  @Test("Wrapped rows use vertical position and preserve the gap at the end of a row")
  func wrappedRows() {
    let items = row + [
      (key: "d", frame: CGRect(x: 10, y: 54, width: 30, height: 30)),
      (key: "e", frame: CGRect(x: 54, y: 54, width: 30, height: 30)),
    ]
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 200, y: 25), items: items) == "d")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 100, y: 45), items: items) == "d")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 30, y: 65), items: items) == "e")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 90, y: 65), items: items) == nil)
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 200, y: 0), items: items) == "a")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 0, y: 90), items: items) == nil)
  }

  @Test("Scrolled frames remain in the drop zone's coordinate space")
  func scrolledRows() {
    let items = [
      (key: "a", frame: CGRect(x: -34, y: -34, width: 30, height: 30)),
      (key: "b", frame: CGRect(x: 10, y: -34, width: 30, height: 30)),
      (key: "c", frame: CGRect(x: -34, y: 10, width: 30, height: 30)),
      (key: "d", frame: CGRect(x: 10, y: 10, width: 30, height: 30)),
    ]
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 0, y: 20), items: items) == "d")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 30, y: 20), items: items) == nil)
  }

  @Test("Right-to-left rows reverse horizontal insertion while retaining logical order")
  func rightToLeftRows() {
    let items = [
      (key: "a", frame: CGRect(x: 98, y: 10, width: 30, height: 30)),
      (key: "b", frame: CGRect(x: 54, y: 10, width: 30, height: 30)),
      (key: "c", frame: CGRect(x: 10, y: 10, width: 30, height: 30)),
      (key: "d", frame: CGRect(x: 98, y: 54, width: 30, height: 30)),
    ]
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 130, y: 25), items: items, rightToLeft: true) == "a")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 113, y: 25), items: items, rightToLeft: true) == "b")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 60, y: 25), items: items, rightToLeft: true) == "c")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 0, y: 25), items: items, rightToLeft: true) == "d")
    #expect(PreviewDropTarget.insertionKey(at: CGPoint(x: 100, y: 65), items: items, rightToLeft: true) == nil)
  }

  @Test("Empty lanes and unmeasured cells have no insertion anchor")
  func emptyLane() {
    #expect(PreviewDropTarget.insertionKey(at: .zero, items: []) == nil)
    #expect(PreviewDropTarget.insertionKey(at: .zero, items: [(key: "pending", frame: .zero)]) == nil)
  }
}

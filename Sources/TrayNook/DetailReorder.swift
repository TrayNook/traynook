import AppKit
import SwiftUI

@MainActor
final class DetailReorderPointer: ObservableObject {
  @Published var offset: CGFloat = 0
}

/// Pointer movement stays local to the floating row; a lane changes only at row boundaries.
@MainActor
final class DetailReorderSession: ObservableObject {
  @Published private(set) var key: String?
  @Published private(set) var order: [String]?
  private(set) var zone: Placement?
  let pointer = DetailReorderPointer()
  private var original: SavedLayout?
  private var startLane: [SavedItem] = []
  private var startIndex = 0
  private var currentIndex = 0
  private var rowHeights: [String: CGFloat] = [:]
  private var rowSpacing: CGFloat = 0
  private var commit: (([String]) -> Void)?

  func begin(_ key: String, layout: SavedLayout, lane: [SavedItem], rowHeights: [String: CGFloat],
    rowSpacing: CGFloat, commit: @escaping ([String]) -> Void) -> Bool {
    guard self.key == nil, let index = lane.firstIndex(where: { $0.id == key }) else { return false }
    original = layout
    startLane = lane
    startIndex = index
    currentIndex = index
    self.rowHeights = rowHeights
    self.rowSpacing = rowSpacing
    self.commit = commit
    zone = lane[index].placement
    order = lane.map(\.id)
    self.key = key
    return true
  }

  func update(translation: CGFloat) {
    guard let key else { return }
    func height(_ item: SavedItem) -> CGFloat { (rowHeights[item.id] ?? 44) + rowSpacing }
    var desired = startIndex
    var passed: CGFloat = 0
    if translation > 0 {
      for index in startLane.indices where index > startIndex {
        let height = height(startLane[index])
        guard translation > passed + height / 2 else { break }
        passed += height
        desired = index
      }
    } else {
      for index in startLane.indices.reversed() where index < startIndex {
        let height = height(startLane[index])
        guard -translation > passed + height / 2 else { break }
        passed += height
        desired = index
      }
    }
    let offset = translation - (translation > 0 ? passed : -passed)
    if pointer.offset != offset { pointer.offset = offset }
    guard desired != currentIndex else { return }
    currentIndex = desired
    var keys = startLane.map(\.id)
    keys.remove(at: startIndex)
    keys.insert(key, at: desired)
    order = keys
  }

  func finish(currentLayout: SavedLayout) {
    let keys = order
    let commit = self.commit
    let changed = currentLayout == original && keys != startLane.map(\.id)
    cancel()
    if changed, let keys { commit?(keys) }
  }

  func cancel() {
    guard key != nil else { return }
    key = nil
    order = nil
    zone = nil
    original = nil
    startLane = []
    commit = nil
    pointer.offset = 0
  }
}

struct DetailReorderRow: ViewModifier {
  @ObservedObject var pointer: DetailReorderPointer
  let dragged: Bool

  func body(content: Content) -> some View {
    content
      .offset(y: dragged ? pointer.offset : 0)
      .zIndex(dragged ? 1 : 0)
      .transaction { if dragged { $0.animation = nil } }
  }
}

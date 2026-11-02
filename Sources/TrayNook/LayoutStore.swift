import Foundation

enum Placement: String, Codable, CaseIterable, Identifiable {
  case menuBar, dropdown, alwaysHidden
  var id: Self { self }
  var title: String {
    switch self {
    case .menuBar: return L("Menu Bar")
    case .dropdown: return L("Dropdown")
    case .alwaysHidden: return L("Always Hidden")
    }
  }
}

struct SavedItem: Codable, Equatable, Identifiable {
  // `bundle` or `bundle#discriminator` from IdentityAssessment.persistentKey.
  // Never AX titles, labels, geometry, or process/window IDs.
  var id: String
  var placement: Placement = .menuBar
}

struct SavedLayout: Codable, Equatable {
  var version = 1
  var rowCapacity = 10
  var items: [SavedItem] = []

  func validated() throws -> Self {
    guard version == 1, (1...30).contains(rowCapacity),
      Set(items.map(\.id)).count == items.count,
      items.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 255
        && $0.id.contains(".") && !$0.id.contains(where: \.isWhitespace) })
    else { throw LayoutError.invalidData }
    return self
  }

  mutating func place(_ id: String, in placement: Placement) {
    items.removeAll { $0.id == id }
    let index = placement == .menuBar ? items.firstIndex { $0.placement == .menuBar } : nil
    items.insert(SavedItem(id: id, placement: placement), at: index ?? items.endIndex)
  }

  /// A preview draft changes only the dragged item; unrelated saved items,
  /// including ones that are not running, keep their relative order.
  func moving(_ key: String, to placement: Placement, before anchor: String? = nil) -> Self? {
    guard (try? validated()) != nil, let source = items.first(where: { $0.id == key }) else { return nil }
    if anchor == key { return source.placement == placement ? self : nil }
    if let anchor, !items.contains(where: { $0.id == anchor && $0.placement == placement }) { return nil }

    let originalLane = items.filter { $0.placement == placement }.map(\.id)
    var destinationLane = originalLane.filter { $0 != key }
    let position = anchor.flatMap { destinationLane.firstIndex(of: $0) } ?? destinationLane.endIndex
    destinationLane.insert(key, at: position)
    if source.placement == placement && destinationLane == originalLane { return self }

    var next = self
    next.items.removeAll { $0.id == key }
    let index = anchor.flatMap { target in next.items.firstIndex { $0.id == target } }
      ?? next.items.lastIndex(where: { $0.placement == placement }).map { $0 + 1 }
      ?? next.items.endIndex
    next.items.insert(SavedItem(id: key, placement: placement), at: index)
    return next
  }

  mutating func restoreAll() {
    items = Placement.allCases.flatMap { zone in
      items.filter { $0.placement == zone }.map { SavedItem(id: $0.id) }
    }
  }
}

enum LayoutError: LocalizedError {
  case invalidData
  var errorDescription: String? { L("Saved layout cannot be read safely. Reset Layout to start again; the original file is preserved until then.") }
}

struct LayoutStore {
  let url: URL

  func load() throws -> SavedLayout {
    // fileExists also returns false for inaccessible or invalid parent paths.
    // Only an absent file may start a new layout.
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return SavedLayout()
    }
    return try JSONDecoder().decode(SavedLayout.self, from: data).validated()
  }

  func save(_ layout: SavedLayout) throws {
    let data = try JSONEncoder().encode(layout.validated())
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}

private let localizationBundle = Bundle.main.url(forResource: "TrayNook_TrayNook", withExtension: "bundle")
  .flatMap(Bundle.init(url:)) ?? Bundle.module

func L(_ key: String) -> String {
  NSLocalizedString(key, bundle: localizationBundle, comment: "")
}

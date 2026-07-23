import Foundation

/// Retains the last complete inventory baseline. Denied or incomplete scans
/// never replace it, because diffing a partial snapshot can fabricate removals
/// and later additions that are unsafe to act on.
public struct CompleteSnapshotChangeTracker: Sendable {
  private var previousItems: [ClassifiedSourceItem]?

  public init() {}

  public mutating func changes(
    for snapshot: InventorySnapshot,
    using differ: SnapshotDiffer = SnapshotDiffer()
  ) -> [SnapshotChange] {
    guard
      snapshot.permission == .granted,
      snapshot.completeness == .complete
    else {
      return []
    }

    let changes =
      previousItems.map {
        differ.changes(from: $0, to: snapshot.items)
      } ?? []
    previousItems = snapshot.items
    return changes
  }
}

import Foundation

public struct SnapshotDiffer: Sendable {
  public init() {}

  public func changes(
    from previous: [ClassifiedSourceItem],
    to current: [ClassifiedSourceItem]
  ) -> [SnapshotChange] {
    let ambiguousGroups = ambiguousGroups(in: previous)
      .union(ambiguousGroups(in: current))
    let previousItems = uniquelyKeyed(
      previous,
      excluding: ambiguousGroups
    )
    let currentItems = uniquelyKeyed(
      current,
      excluding: ambiguousGroups
    )
    let allKeys = Set(previousItems.keys).union(currentItems.keys)

    let identityChanges = allKeys.sorted(by: keySort).flatMap { key in
      switch (previousItems[key], currentItems[key]) {
      case (nil, let current?):
        return [
          SnapshotChange(
            kind: .created,
            identity: key,
            previousRuntimeID: nil,
            currentRuntimeID: current.observation.runtimeID
          )
        ]

      case (let previous?, nil):
        return [
          SnapshotChange(
            kind: .removed,
            identity: key,
            previousRuntimeID: previous.observation.runtimeID,
            currentRuntimeID: nil
          )
        ]

      case (let previous?, let current?):
        return updates(from: previous, to: current, key: key)

      case (nil, nil):
        return []
      }
    }

    let ambiguousChanges =
      ambiguousGroups
      .sorted { $0.diagnosticDescription < $1.diagnosticDescription }
      .compactMap { group in
        ambiguousChange(
          for: group,
          previous: previous,
          current: current
        )
      }

    return identityChanges + ambiguousChanges
  }

  private func uniquelyKeyed(
    _ items: [ClassifiedSourceItem],
    excluding ambiguousGroups: Set<RuntimeInventoryGroupKey>
  ) -> [ProvisionalIdentityKey: ClassifiedSourceItem] {
    let keyed = items.compactMap { item -> (ProvisionalIdentityKey, ClassifiedSourceItem)? in
      guard
        let key = item.identity.provisionalKey,
        !ambiguousGroups.contains(runtimeGroup(for: item.observation))
      else {
        return nil
      }
      return (key, item)
    }
    let groups = Dictionary(grouping: keyed, by: \.0)

    return groups.reduce(into: [:]) { result, entry in
      guard entry.value.count == 1, let item = entry.value.first?.1 else {
        return
      }
      result[entry.key] = item
    }
  }

  private func ambiguousGroups(
    in items: [ClassifiedSourceItem]
  ) -> Set<RuntimeInventoryGroupKey> {
    Set(
      items
        .filter { $0.identity.status == .ambiguous }
        .map { runtimeGroup(for: $0.observation) }
    )
  }

  private func ambiguousChange(
    for group: RuntimeInventoryGroupKey,
    previous: [ClassifiedSourceItem],
    current: [ClassifiedSourceItem]
  ) -> SnapshotChange? {
    let previousItems = items(previous, in: group)
    let currentItems = items(current, in: group)
    let previousRuntimeIDs = Set(previousItems.map(\.observation.runtimeID))
    let currentRuntimeIDs = Set(currentItems.map(\.observation.runtimeID))

    guard
      previousItems.count != currentItems.count
        || previousRuntimeIDs != currentRuntimeIDs
    else {
      return nil
    }

    return SnapshotChange(
      kind: .ambiguousInventoryChanged,
      runtimeGroup: group,
      previousRuntimeID: previousItems.count == 1
        ? previousItems[0].observation.runtimeID : nil,
      currentRuntimeID: currentItems.count == 1
        ? currentItems[0].observation.runtimeID : nil,
      previousCount: previousItems.count,
      currentCount: currentItems.count
    )
  }

  private func items(
    _ items: [ClassifiedSourceItem],
    in group: RuntimeInventoryGroupKey
  ) -> [ClassifiedSourceItem] {
    items.filter { runtimeGroup(for: $0.observation) == group }
  }

  private func runtimeGroup(
    for observation: RawSourceItemObservation
  ) -> RuntimeInventoryGroupKey {
    if let bundleIdentifier = observation.bundleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !bundleIdentifier.isEmpty
    {
      return RuntimeInventoryGroupKey(
        bundleIdentifier: bundleIdentifier,
        processIdentifierFallback: nil
      )
    }

    return RuntimeInventoryGroupKey(
      bundleIdentifier: nil,
      processIdentifierFallback: observation.processIdentifier
    )
  }

  private func updates(
    from previous: ClassifiedSourceItem,
    to current: ClassifiedSourceItem,
    key: ProvisionalIdentityKey
  ) -> [SnapshotChange] {
    var changes: [SnapshotChange] = []
    let previousObservation = previous.observation
    let currentObservation = current.observation

    if previousObservation.processIdentifier != currentObservation.processIdentifier {
      changes.append(
        change(.processReplaced, key, previousObservation, currentObservation)
      )
    }

    if previousObservation.observedOrder != currentObservation.observedOrder {
      changes.append(
        change(.orderChanged, key, previousObservation, currentObservation)
      )
    }

    if previousObservation.frame != currentObservation.frame
      || previousObservation.metadata != currentObservation.metadata
      || previousObservation.actions != currentObservation.actions
      || previousObservation.statusWindowIdentifier != currentObservation.statusWindowIdentifier
    {
      changes.append(
        change(.runtimeMetadataChanged, key, previousObservation, currentObservation)
      )
    }

    return changes
  }

  private func change(
    _ kind: SnapshotChangeKind,
    _ key: ProvisionalIdentityKey,
    _ previous: RawSourceItemObservation,
    _ current: RawSourceItemObservation
  ) -> SnapshotChange {
    SnapshotChange(
      kind: kind,
      identity: key,
      previousRuntimeID: previous.runtimeID,
      currentRuntimeID: current.runtimeID
    )
  }

  private func keySort(
    _ lhs: ProvisionalIdentityKey,
    _ rhs: ProvisionalIdentityKey
  ) -> Bool {
    lhs.diagnosticDescription < rhs.diagnosticDescription
  }
}

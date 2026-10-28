import Foundation

public struct IdentityAssessor: Sendable {
  public init() {}

  public func classify(_ observations: [RawSourceItemObservation]) -> [ClassifiedSourceItem] {
    let grouped = Dictionary(grouping: observations) {
      normalized($0.bundleIdentifier)
    }

    let classified = grouped.values.flatMap { group in
      classifyApplicationGroup(group)
    }

    return classified.sorted {
      if $0.observation.observedOrder == $1.observation.observedOrder {
        return $0.observation.runtimeID < $1.observation.runtimeID
      }
      return $0.observation.observedOrder < $1.observation.observedOrder
    }
  }

  private func classifyApplicationGroup(
    _ observations: [RawSourceItemObservation]
  ) -> [ClassifiedSourceItem] {
    let bundleIdentifier = observations.compactMap {
      normalized($0.bundleIdentifier)
    }.first

    guard let bundleIdentifier else {
      return observations.map {
        ClassifiedSourceItem(
          observation: $0,
          identity: IdentityAssessment(
            status: .ambiguous,
            provisionalKey: nil,
            reason: "The source process has no bundle identifier."
          ),
          manageability: manageability(for: $0)
        )
      }
    }

    // Only verified AXMenuBarItem rows count as siblings. Other status-level
    // windows of the same app (panels, popovers) must not shift sibling keys.
    let menuItems = observations.filter { $0.role == "AXMenuBarItem" }
    let siblings = menuItems.isEmpty ? observations : menuItems

    if siblings.count == 1 {
      return observations.map { observation in
        let identifier = normalized(observation.metadata.identifierCandidate)
        let isSibling = observation.runtimeID == siblings[0].runtimeID
        return ClassifiedSourceItem(
          observation: observation,
          identity: isSibling
            ? IdentityAssessment(
              status: identifier == nil ? .provisionalBundleIdentity : .provisionalDiscriminator,
              provisionalKey: ProvisionalIdentityKey(
                bundleIdentifier: bundleIdentifier,
                discriminatorCandidate: identifier
              ),
              reason: identifier == nil
                ? "Only one Source Item from this bundle is currently observed."
                : "The AXIdentifier is provisionally useful; only the bundle identifier is persisted for a single item.",
              persistentKey: bundleIdentifier)
            : unverifiedWindowIdentity(observation, bundleIdentifier: bundleIdentifier),
          manageability: manageability(for: observation)
        )
      }
    }

    // Siblings (see ADR 0009) persist as `bundle#ax:<identifier>` when their
    // AXIdentifier is unique and identifier-shaped, else `bundle#w<rank>` by
    // the creation order of their status windows. The plain bundle key is
    // reserved for an application's only item, so keys never alias.
    // ponytail: creation order follows the app's code order; an app that
    // creates items dynamically can shift ranks. AppModel reveals the section
    // when a ranked sibling's window changes; revisit if that is too noisy.
    let identifiers = Dictionary(grouping: siblings) {
      persistableIdentifier($0.metadata.identifierCandidate)
    }
    let windows = siblings.compactMap(\.statusWindowIdentifier)
    let rankedWindows = windows.count == siblings.count && Set(windows).count == windows.count
      ? windows.sorted() : []

    return observations.map { observation in
      guard siblings.contains(where: { $0.runtimeID == observation.runtimeID }) else {
        return ClassifiedSourceItem(
          observation: observation,
          identity: unverifiedWindowIdentity(observation, bundleIdentifier: bundleIdentifier),
          manageability: manageability(for: observation)
        )
      }
      let identifier = persistableIdentifier(observation.metadata.identifierCandidate)
      let uniqueIdentifier = identifier.flatMap { identifiers[$0]?.count == 1 ? $0 : nil }
      let rank = observation.statusWindowIdentifier.flatMap { rankedWindows.firstIndex(of: $0) }

      if let uniqueIdentifier {
        return ClassifiedSourceItem(
          observation: observation,
          identity: IdentityAssessment(
            status: .provisionalDiscriminator,
            // Runtime identity keeps the raw identifier so a single item that
            // gains a sibling is not reported as removed and created.
            provisionalKey: ProvisionalIdentityKey(
              bundleIdentifier: bundleIdentifier,
              discriminatorCandidate: uniqueIdentifier
            ),
            reason: "The AXIdentifier is unique in this bundle and uses only identifier-safe characters.",
            persistentKey: "\(bundleIdentifier)#ax:\(uniqueIdentifier)"
          ),
          manageability: manageability(for: observation)
        )
      }

      if let rank {
        let discriminator = "w\(rank)"
        return ClassifiedSourceItem(
          observation: observation,
          identity: IdentityAssessment(
            status: .provisionalDiscriminator,
            provisionalKey: ProvisionalIdentityKey(
              bundleIdentifier: bundleIdentifier,
              discriminatorCandidate: discriminator
            ),
            reason: "Sibling items are told apart by status-window creation order.",
            persistentKey: "\(bundleIdentifier)#\(discriminator)"
          ),
          manageability: manageability(for: observation)
        )
      }

      return ClassifiedSourceItem(
        observation: observation,
        identity: IdentityAssessment(
          status: .ambiguous,
          provisionalKey: nil,
          reason: "Multiple Source Items from this bundle lack a unique non-content discriminator."
        ),
        manageability: manageability(for: observation)
      )
    }
  }

  /// A status-level window beside a verified item: tracked at runtime by its
  /// window identifier, never persisted, never a placement candidate.
  private func unverifiedWindowIdentity(
    _ observation: RawSourceItemObservation, bundleIdentifier: String
  ) -> IdentityAssessment {
    IdentityAssessment(
      status: .provisionalBundleIdentity,
      provisionalKey: ProvisionalIdentityKey(
        bundleIdentifier: bundleIdentifier,
        discriminatorCandidate: "window:\(observation.statusWindowIdentifier.map(String.init) ?? observation.runtimeID)"
      ),
      reason: "A status window without a verified Accessibility item is tracked at runtime only."
    )
  }

  /// An AXIdentifier is developer-assigned, but it is still app-supplied text.
  /// Only short identifier-shaped values may become part of a saved key.
  func persistableIdentifier(_ value: String?) -> String? {
    guard let value = normalized(value), value.count <= 64,
      value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
    else { return nil }
    return value
  }

  private func manageability(
    for observation: RawSourceItemObservation
  ) -> ManageabilityAssessment {
    guard observation.role == "AXMenuBarItem" else {
      return ManageabilityAssessment(
        status: .protected,
        reason: "The visible status window has no verified Accessibility Source Item. Keep it visible."
      )
    }
    guard let bundleIdentifier = normalized(observation.bundleIdentifier) else {
      return ManageabilityAssessment(
        status: .protected,
        reason: "Ownership cannot be attributed to a source bundle without mutation."
      )
    }

    guard !bundleIdentifier.hasPrefix("com.apple.") else {
      return ManageabilityAssessment(
        status: .protected,
        reason: "Apple system items have no validated safe movement path."
      )
    }

    guard let frame = observation.frame, frame.isUsable else {
      return ManageabilityAssessment(
        status: .protected,
        reason: "No usable Accessibility geometry is available for safe interaction."
      )
    }

    guard observation.actions.contains("AXPress") else {
      return ManageabilityAssessment(
        status: .requiresValidation,
        reason:
          "AXPress is unavailable; a later non-mutating capability probe must establish a safe activation path."
      )
    }

    return ManageabilityAssessment(
      status: .candidate,
      reason: "Public Accessibility metadata exposes geometry and AXPress."
    )
  }

  private func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

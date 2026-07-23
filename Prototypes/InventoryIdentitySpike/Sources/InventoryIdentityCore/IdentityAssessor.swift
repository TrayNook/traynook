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

    if observations.count == 1 {
      return observations.map { observation in
        let identifier = normalized(observation.metadata.identifierCandidate)
        return ClassifiedSourceItem(
          observation: observation,
          identity: IdentityAssessment(
            status: identifier == nil
              ? .provisionalBundleIdentity
              : .provisionalDiscriminator,
            provisionalKey: ProvisionalIdentityKey(
              bundleIdentifier: bundleIdentifier,
              discriminatorCandidate: identifier
            ),
            reason: identifier == nil
              ? "Only one Source Item from this bundle is currently observed."
              : "The AXIdentifier is provisionally useful, but must be verified as stable and non-content before persistence."
          ),
          manageability: manageability(for: observation)
        )
      }
    }

    let identifiers = Dictionary(grouping: observations) {
      normalized($0.metadata.identifierCandidate)
    }

    return observations.map { observation in
      let identifier = normalized(observation.metadata.identifierCandidate)
      let matchingIdentifierCount = identifiers[identifier]?.count ?? 0

      if let identifier, matchingIdentifierCount == 1 {
        return ClassifiedSourceItem(
          observation: observation,
          identity: IdentityAssessment(
            status: .provisionalDiscriminator,
            provisionalKey: ProvisionalIdentityKey(
              bundleIdentifier: bundleIdentifier,
              discriminatorCandidate: identifier
            ),
            reason:
              "The AXIdentifier is unique in this bundle, but must be verified as stable and non-content before persistence."
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

  private func manageability(
    for observation: RawSourceItemObservation
  ) -> ManageabilityAssessment {
    guard normalized(observation.bundleIdentifier) != nil else {
      return ManageabilityAssessment(
        status: .protected,
        reason: "Ownership cannot be attributed to a source bundle without mutation."
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

import Testing

@testable import InventoryIdentityCore

@Suite("Safe-default correction planning")
struct SafeDefaultCorrectionTests {
  private let planner = SafeDefaultCorrectionPlanner(dragStepCount: 4)
  private let boundary = ItemFrame(
    x: 900,
    y: 0,
    width: 24,
    height: 24
  )
  private let launcher = ItemFrame(
    x: 924,
    y: 0,
    width: 24,
    height: 24
  )
  private let safeMenuBar = ItemFrame(
    x: 700,
    y: 0,
    width: 300,
    height: 24
  )
  private let identity = ProvisionalIdentityKey(
    bundleIdentifier: "example.target",
    discriminatorCandidate: "primary"
  )

  @Test("Plans one Command-only drag with exactly one mouse-up")
  func plansCommandDrag() throws {
    let disposition = try planner.plan(
      target: identity,
      in: [item(x: 800)],
      boundaryFrame: boundary,
      launcherFrame: launcher,
      safeMenuBarFrame: safeMenuBar
    )
    let plan = try #require(movePlan(from: disposition))

    #expect(
      plan.events.filter { $0.kind == .leftMouseDown }.count == 1
    )
    #expect(
      plan.events.filter { $0.kind == .leftMouseUp }.count == 1
    )
    #expect(
      plan.events
        .filter {
          $0.kind == .leftMouseDown
            || $0.kind == .leftMouseDragged
            || $0.kind == .leftMouseUp
        }
        .allSatisfy { $0.commandOnly }
    )
    #expect(plan.events.first?.commandOnly == false)
    #expect(plan.events.last?.kind == .leftMouseUp)
    #expect(plan.events.last?.commandOnly == true)

    let draggedX = plan.events
      .filter { $0.kind == .leftMouseDragged }
      .map(\.location.x)
    #expect(draggedX == draggedX.sorted())
  }

  @Test("Does not move a target already on the safe side")
  func acceptsAlreadySafeTarget() throws {
    let disposition = try planner.plan(
      target: identity,
      in: [item(x: 930)],
      boundaryFrame: boundary,
      launcherFrame: launcher,
      safeMenuBarFrame: safeMenuBar
    )

    #expect(disposition == .noMoveRequired)
  }

  @Test("Rejects ambiguous, protected, duplicate, and unsafe plans")
  func rejectsUnsafeTargets() {
    #expect(throws: SafeDefaultCorrectionPlanningError.self) {
      try planner.plan(
        target: identity,
        in: [item(x: 800), item(x: 820)],
        boundaryFrame: boundary,
        launcherFrame: launcher,
        safeMenuBarFrame: safeMenuBar
      )
    }
    #expect(throws: SafeDefaultCorrectionPlanningError.self) {
      try planner.plan(
        target: identity,
        in: [item(x: 800, protected: true)],
        boundaryFrame: boundary,
        launcherFrame: launcher,
        safeMenuBarFrame: safeMenuBar
      )
    }
    #expect(throws: SafeDefaultCorrectionPlanningError.self) {
      try planner.plan(
        target: identity,
        in: [item(x: 800)],
        boundaryFrame: boundary,
        launcherFrame: ItemFrame(
          x: 850,
          y: 0,
          width: 24,
          height: 24
        ),
        safeMenuBarFrame: safeMenuBar
      )
    }
    #expect(throws: SafeDefaultCorrectionPlanningError.self) {
      try planner.plan(
        target: identity,
        in: [item(x: 800, y: 100)],
        boundaryFrame: boundary,
        launcherFrame: launcher,
        safeMenuBarFrame: safeMenuBar
      )
    }
    #expect(throws: SafeDefaultCorrectionPlanningError.self) {
      try planner.plan(
        target: identity,
        in: [item(x: 650)],
        boundaryFrame: boundary,
        launcherFrame: launcher,
        safeMenuBarFrame: safeMenuBar
      )
    }
  }

  private func item(
    x: Double,
    y: Double = 0,
    protected: Bool = false
  ) -> ClassifiedSourceItem {
    let observation = RawSourceItemObservation(
      runtimeID: "100:0",
      processIdentifier: 100,
      bundleIdentifier: identity.bundleIdentifier,
      applicationName: "Target",
      role: "AXMenuBarItem",
      frame: ItemFrame(x: x, y: y, width: 24, height: 24),
      actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(
        identifierCandidate: identity.discriminatorCandidate
      ),
      observedOrder: 0
    )
    return ClassifiedSourceItem(
      observation: observation,
      identity: IdentityAssessment(
        status: .provisionalDiscriminator,
        provisionalKey: identity,
        reason: "fixture"
      ),
      manageability: ManageabilityAssessment(
        status: protected ? .protected : .candidate,
        reason: "fixture"
      )
    )
  }

  private func movePlan(
    from disposition: SafeDefaultCorrectionDisposition
  ) -> SafeDefaultCorrectionPlan? {
    guard case .move(let plan) = disposition else {
      return nil
    }
    return plan
  }
}

import Foundation

public enum SafeDefaultCorrectionTuning {
  public static let menuBarReflowSeconds = 0.2
  public static let reconciliationIntervalSeconds = 0.15
  public static let requiredStableSnapshots = 2
  public static let maximumReconciliationSamples = 12
  public static let pointerEventIntervalSeconds = 0.015
  public static let armTimeoutSeconds = 60.0
}

public enum PointerDragEventKind: String, Equatable, Sendable {
  case move
  case leftMouseDown
  case leftMouseDragged
  case leftMouseUp
}

public struct PointerPoint: Equatable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct PointerDragEventSpecification: Equatable, Sendable {
  public let kind: PointerDragEventKind
  public let location: PointerPoint
  public let commandOnly: Bool

  public init(
    kind: PointerDragEventKind,
    location: PointerPoint,
    commandOnly: Bool
  ) {
    self.kind = kind
    self.location = location
    self.commandOnly = commandOnly
  }
}

public struct SafeDefaultCorrectionPlan: Equatable, Sendable {
  public let identity: ProvisionalIdentityKey
  public let processIdentifier: Int32
  public let events: [PointerDragEventSpecification]

  public init(
    identity: ProvisionalIdentityKey,
    processIdentifier: Int32,
    events: [PointerDragEventSpecification]
  ) {
    self.identity = identity
    self.processIdentifier = processIdentifier
    self.events = events
  }
}

public enum SafeDefaultCorrectionDisposition: Equatable, Sendable {
  case noMoveRequired
  case move(SafeDefaultCorrectionPlan)
}

public enum SafeDefaultCorrectionPlanningError: String, Error, Sendable {
  case targetNotUnique
  case targetAmbiguous
  case targetProtected
  case targetGeometryUnavailable
  case targetOutsideBoundaryRow
  case boundaryGeometryUnavailable
  case launcherGeometryUnavailable
  case launcherNotOnSafeSide
  case unsafeMenuBarGeometry
}

public struct SafeDefaultCorrectionPlanner: Sendable {
  public static let defaultDragStepCount = 8

  private let dragStepCount: Int

  public init(dragStepCount: Int = defaultDragStepCount) {
    precondition(dragStepCount > 0)
    self.dragStepCount = dragStepCount
  }

  public func plan(
    target identity: ProvisionalIdentityKey,
    in items: [ClassifiedSourceItem],
    boundaryFrame: ItemFrame,
    launcherFrame: ItemFrame,
    safeMenuBarFrame: ItemFrame
  ) throws -> SafeDefaultCorrectionDisposition {
    guard boundaryFrame.isUsable else {
      throw SafeDefaultCorrectionPlanningError
        .boundaryGeometryUnavailable
    }
    guard launcherFrame.isUsable else {
      throw SafeDefaultCorrectionPlanningError
        .launcherGeometryUnavailable
    }
    guard launcherFrame.x >= boundaryFrame.maxX else {
      throw SafeDefaultCorrectionPlanningError.launcherNotOnSafeSide
    }
    guard
      safeMenuBarFrame.isUsable,
      safeMenuBarFrame.contains(boundaryFrame),
      safeMenuBarFrame.contains(launcherFrame)
    else {
      throw SafeDefaultCorrectionPlanningError.unsafeMenuBarGeometry
    }

    let matches = items.filter {
      $0.identity.provisionalKey == identity
    }
    guard matches.count == 1, let target = matches.first else {
      throw SafeDefaultCorrectionPlanningError.targetNotUnique
    }
    guard target.identity.status != .ambiguous else {
      throw SafeDefaultCorrectionPlanningError.targetAmbiguous
    }
    guard target.manageability.status != .protected else {
      throw SafeDefaultCorrectionPlanningError.targetProtected
    }
    guard let targetFrame = target.observation.frame, targetFrame.isUsable
    else {
      throw SafeDefaultCorrectionPlanningError
        .targetGeometryUnavailable
    }
    guard
      verticallyOverlaps(targetFrame, boundaryFrame),
      verticallyOverlaps(launcherFrame, boundaryFrame),
      safeMenuBarFrame.contains(targetFrame)
    else {
      throw SafeDefaultCorrectionPlanningError.targetOutsideBoundaryRow
    }

    if targetFrame.midX >= boundaryFrame.maxX {
      return .noMoveRequired
    }

    let source = PointerPoint(x: targetFrame.midX, y: targetFrame.midY)
    let destination = PointerPoint(
      x: launcherFrame.minX + 1,
      y: launcherFrame.midY
    )
    let events = commandDragEvents(
      from: source,
      to: destination
    )

    return .move(
      SafeDefaultCorrectionPlan(
        identity: identity,
        processIdentifier: target.observation.processIdentifier,
        events: events
      )
    )
  }

  private func commandDragEvents(
    from source: PointerPoint,
    to destination: PointerPoint
  ) -> [PointerDragEventSpecification] {
    var events = [
      PointerDragEventSpecification(
        kind: .move,
        location: source,
        commandOnly: false
      ),
      PointerDragEventSpecification(
        kind: .leftMouseDown,
        location: source,
        commandOnly: true
      ),
    ]

    for step in 1...dragStepCount {
      let progress = Double(step) / Double(dragStepCount)
      events.append(
        PointerDragEventSpecification(
          kind: .leftMouseDragged,
          location: PointerPoint(
            x: source.x + ((destination.x - source.x) * progress),
            y: source.y + ((destination.y - source.y) * progress)
          ),
          commandOnly: true
        )
      )
    }

    events.append(
      PointerDragEventSpecification(
        kind: .leftMouseUp,
        location: destination,
        commandOnly: true
      )
    )
    return events
  }

  private func verticallyOverlaps(
    _ lhs: ItemFrame,
    _ rhs: ItemFrame
  ) -> Bool {
    lhs.y < rhs.maxY && lhs.maxY > rhs.y
  }
}

extension ItemFrame {
  public var minX: Double { x }
  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var midX: Double { x + (width / 2) }
  public var midY: Double { y + (height / 2) }

  public func contains(_ other: ItemFrame) -> Bool {
    other.minX >= minX
      && other.maxX <= maxX
      && other.y >= y
      && other.maxY <= maxY
  }
}

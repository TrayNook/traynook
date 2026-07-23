import CoreGraphics
import Foundation
import InventoryIdentityCore

enum QuartzCommandDragPosterError: Error {
  case eventSourceUnavailable
  case eventConstructionFailed
}

struct QuartzCommandDragPoster {
  func physicalInputIsIdle() -> Bool {
    guard
      !CGEventSource.buttonState(
        .combinedSessionState,
        button: .left
      )
    else {
      return false
    }
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let modifiers: CGEventFlags = [
      .maskCommand,
      .maskControl,
      .maskAlternate,
      .maskShift,
    ]
    return flags.intersection(modifiers).isEmpty
  }

  func post(_ plan: SafeDefaultCorrectionPlan) throws {
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      throw QuartzCommandDragPosterError.eventSourceUnavailable
    }

    // Construct the entire sequence before mouse-down so a construction error
    // cannot leave the global pointer in a pressed state.
    let events = try plan.events.map { specification in
      guard
        let event = CGEvent(
          mouseEventSource: source,
          mouseType: eventType(for: specification.kind),
          mouseCursorPosition: CGPoint(
            x: specification.location.x,
            y: specification.location.y
          ),
          mouseButton: .left
        )
      else {
        throw QuartzCommandDragPosterError.eventConstructionFailed
      }
      event.flags = specification.commandOnly ? [.maskCommand] : []
      return event
    }

    for event in events {
      event.post(tap: .cghidEventTap)
      Thread.sleep(
        forTimeInterval:
          SafeDefaultCorrectionTuning.pointerEventIntervalSeconds
      )
    }
  }

  private func eventType(
    for kind: PointerDragEventKind
  ) -> CGEventType {
    switch kind {
    case .move:
      return .mouseMoved
    case .leftMouseDown:
      return .leftMouseDown
    case .leftMouseDragged:
      return .leftMouseDragged
    case .leftMouseUp:
      return .leftMouseUp
    }
  }
}

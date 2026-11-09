import AppKit

struct DropdownEscapeSession {
  enum Action { case pass, consume, dismiss }

  private var escapePressed = false

  mutating func handle(_ event: NSEvent, ownsKeyboard: Bool) -> Action {
    guard ownsKeyboard else { reset(); return .pass }
    guard event.keyCode == 53 else { return .pass }
    switch event.type {
    case .keyDown:
      escapePressed = true
      return .consume
    case .keyUp:
      let dismiss = escapePressed
      reset()
      return dismiss ? .dismiss : .consume
    default:
      return .pass
    }
  }

  mutating func reset() { escapePressed = false }
}

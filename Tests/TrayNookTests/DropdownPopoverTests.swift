import AppKit
import SwiftUI
import Testing

@testable import TrayNook

@Suite("Dropdown popover geometry", .serialized)
@MainActor
struct DropdownPopoverTests {
  @Test("Keyboard and accessibility entry focus the gear; pointer entry leaves it unfocused")
  func activationIntent() {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      #expect(!AppDelegate.focusesDropdownSettings(for: type, voiceOver: false))
      #expect(AppDelegate.focusesDropdownSettings(for: type, voiceOver: true))
    }
    #expect(AppDelegate.focusesDropdownSettings(for: .keyDown, voiceOver: false))
    #expect(AppDelegate.focusesDropdownSettings(for: nil, voiceOver: false))
  }

  // Real keyboard ownership needs NSApplication.run and is checked by the packaged smoke test.

  @Test("Escape down and repeats stay local until release dismisses the dropdown")
  func escapeRelease() throws {
    var session = DropdownEscapeSession()
    #expect(session.handle(try keyEvent(.keyDown), ownsKeyboard: true) == .consume)
    #expect(session.handle(try keyEvent(.keyDown, repeats: true), ownsKeyboard: true) == .consume)
    #expect(session.handle(try keyEvent(.keyDown, repeats: true), ownsKeyboard: true) == .consume)
    #expect(session.handle(try keyEvent(.keyUp), ownsKeyboard: true) == .dismiss)
    #expect(session.handle(try keyEvent(.keyUp), ownsKeyboard: true) == .consume)
  }

  @Test("Escape ignores other windows and a closed session cannot dismiss on a stale release")
  func escapeOwnershipAndReset() throws {
    var session = DropdownEscapeSession()
    #expect(session.handle(try keyEvent(.keyDown, keyCode: 36), ownsKeyboard: true) == .pass)
    #expect(session.handle(try keyEvent(.keyDown), ownsKeyboard: false) == .pass)
    #expect(session.handle(try keyEvent(.keyUp), ownsKeyboard: true) == .consume)
    #expect(session.handle(try keyEvent(.keyDown), ownsKeyboard: true) == .consume)
    #expect(session.handle(try keyEvent(.keyUp), ownsKeyboard: false) == .pass)
    #expect(session.handle(try keyEvent(.keyUp), ownsKeyboard: true) == .consume)
    #expect(session.handle(try keyEvent(.keyDown), ownsKeyboard: true) == .consume)
    session.reset()
    #expect(session.handle(try keyEvent(.keyUp), ownsKeyboard: true) == .consume)
  }

  @Test("Dropdown stays onscreen when its content changes on reopen",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_DROPDOWN_GEOMETRY"] == "1"))
  func staysInsideScreenEdges() async throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let screens = NSScreen.screens
    try #require(!screens.isEmpty, "This regression requires a macOS GUI session.")
    let popover = NSPopover()
    popover.animates = false
    defer { popover.close() }

    for screen in screens {
      let available = screen.visibleFrame
      let anchor = NSWindow(contentRect: CGRect(x: available.minX, y: available.maxY - 24,
        width: 24, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
      anchor.isReleasedWhenClosed = false
      defer { anchor.close() }
      let view = NSView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
      anchor.contentView = view
      anchor.orderFront(nil)

      for x in [available.maxX - 320, available.minX + 12] {
        anchor.setFrameOrigin(CGPoint(x: x, y: available.maxY - 24))
        for width in [CGFloat(180), 460, 684, 180] where width <= available.width - 40 {
          await popover.showDropdown(content: content(width: width), relativeTo: view)
          let window = try #require(popover.contentViewController?.view.window)
          let initialFrame = window.frame
          try await Task.sleep(for: .milliseconds(100))
          let settledFrame = window.frame

          for frame in [initialFrame, settledFrame] {
            #expect(frame.minX >= available.minX - 0.5,
              "Dropdown width \(width), anchor \(x): \(frame) crosses the left screen edge \(available).")
            #expect(frame.maxX <= available.maxX + 0.5,
              "Dropdown width \(width), anchor \(x): \(frame) crosses the right screen edge \(available).")
          }
          #expect(abs(popover.contentSize.width - width) < 0.5)
          popover.close()
        }
      }
    }
  }

  private func content(width: CGFloat) -> some View {
    VStack {
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8),
          count: max(1, Int((width - 20) / 44))), spacing: 8) {
          ForEach(0..<20) { _ in
            Image(systemName: "gearshape").frame(width: 34, height: 34)
          }
        }
      }.frame(height: 88)
    }
    .padding(12)
    .frame(width: width)
  }

  private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16 = 53, repeats: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: keyCode == 53 ? "\u{1b}" : "\r",
      charactersIgnoringModifiers: keyCode == 53 ? "\u{1b}" : "\r", isARepeat: repeats, keyCode: keyCode))
  }
}

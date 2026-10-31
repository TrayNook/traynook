import AppKit
import SwiftUI
import Testing

@testable import TrayNook

@Suite("Dropdown popover geometry")
@MainActor
struct DropdownPopoverTests {
  @Test("Dropdown stays onscreen when its content changes on reopen",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_DROPDOWN_GEOMETRY"] == "1"))
  func staysInsideScreenEdges() throws {
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
          popover.showDropdown(content: content(width: width), relativeTo: view)
          let window = try #require(popover.contentViewController?.view.window)
          let initialFrame = window.frame
          RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
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
}

import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Selected restoration validation")
@MainActor
struct NativeRestorationValidationTests {
  private let frame = ItemFrame(x: 1200, y: 6, width: 24, height: 24)

  @Test("Restoration rebinds only the selected source between fresh native states")
  func selectedOnlyRead() throws {
    let source = StatusWindowState(processIdentifier: 100, windowIdentifier: 10,
      frame: frame, isOnscreen: true)
    let unrelated = StatusWindowState(processIdentifier: 200, windowIdentifier: 20,
      frame: ItemFrame(x: 1250, y: 6, width: 24, height: 24), isOnscreen: true)
    var stages: [String] = []
    // The unrelated owner can have unavailable AX; its native window remains verifiable.
    let result = try NativeMenuBarController.readSelectedRestoration(readState: {
      stages.append("native")
      return [source, unrelated]
    }, rebindSelected: {
      stages.append("selectedAX")
      return frame
    })
    #expect(result.frame == frame)
    #expect(stages == ["native", "selectedAX", "native"])
  }

  @Test("A selected AX failure never authorizes restoration")
  func selectedFailureBlocks() {
    #expect(throws: NativeMenuActionError.inventoryUnavailable) {
      try NativeMenuBarController.readSelectedRestoration(readState: { 1 }, rebindSelected: {
        throw NativeMenuActionError.inventoryUnavailable
      })
    }
  }

  @Test("Changed native bindings, geometry, or visibility invalidate selected AX results")
  func changedNativeStateBlocks() {
    let before = StatusWindowState(processIdentifier: 100, windowIdentifier: 10,
      frame: frame, isOnscreen: true)
    let changes = [
      StatusWindowState(processIdentifier: 200, windowIdentifier: 10, frame: frame, isOnscreen: true),
      StatusWindowState(processIdentifier: 100, windowIdentifier: 11, frame: frame, isOnscreen: true),
      StatusWindowState(processIdentifier: 100, windowIdentifier: 10,
        frame: ItemFrame(x: 1250, y: 6, width: 24, height: 24), isOnscreen: true),
      StatusWindowState(processIdentifier: 100, windowIdentifier: 10, frame: frame, isOnscreen: false),
    ]
    for changed in changes {
      var reads = 0
      #expect(throws: NativeMenuActionError.inventoryUnavailable) {
        try NativeMenuBarController.readSelectedRestoration(readState: {
          reads += 1
          return reads == 1 ? before : changed
        }, rebindSelected: { frame })
      }
    }
  }

  @Test("Selected AX frames must overlap the exact current native source window")
  func selectedFrameMustMatchBoundWindow() {
    #expect(NativeMenuBarController.selectedReturnFrameMatches(frame, window: frame))
    #expect(!NativeMenuBarController.selectedReturnFrameMatches(
      ItemFrame(x: 1250, y: 6, width: 24, height: 24), window: frame))
    #expect(!NativeMenuBarController.selectedReturnFrameMatches(
      ItemFrame(x: 1200, y: 50, width: 24, height: 24), window: frame))
    #expect(!NativeMenuBarController.selectedReturnFrameMatches(
      ItemFrame(x: .nan, y: 6, width: 24, height: 24), window: frame))
  }
}

import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Optional native status-window readback")
@MainActor
struct StatusWindowMatchingTests {
  private let frame = ItemFrame(x: 1200, y: 6, width: 24, height: 24)

  @Test("Missing optional capture geometry returns no window for app-icon fallback")
  func unavailableCaptureReturnsNil() {
    let source = item()
    #expect(NativeMenuBarController.matchingStatusWindow(for: source, in: []) == nil)
    for unavailable in [nil, ItemFrame(x: .nan, y: 6, width: 24, height: 24)] as [ItemFrame?] {
      #expect(NativeMenuBarController.matchingStatusWindow(for: item(frame: unavailable),
        in: [window()]) == nil)
    }
  }

  @Test("A native match requires current owner, bundle, row overlap, and a source-sized window")
  func rejectsUnsafeCandidates() {
    let candidates = [
      window(pid: 200), window(bundle: "example.other"),
      window(frame: ItemFrame(x: 1250, y: 6, width: 24, height: 24)),
      window(frame: ItemFrame(x: 1200, y: 50, width: 24, height: 24)),
      window(frame: ItemFrame(x: 1100, y: 0, width: 500, height: 500)),
    ]
    for candidate in candidates {
      #expect(NativeMenuBarController.matchingStatusWindow(for: item(), in: [candidate]) == nil)
    }
    #expect(NativeMenuBarController.matchingStatusWindow(for: item(), in: [window()])?.binding.id == 10)
  }

  @Test("Ambiguous native windows are rejected even when one has the saved window ID")
  func rejectsAmbiguousWindows() {
    #expect(NativeMenuBarController.matchingStatusWindow(for: item(),
      in: [window(), window(id: 11)]) == nil)
    #expect(NativeMenuBarController.matchingStatusWindow(for: item(),
      in: [window(isOnscreen: false), window(id: 11, isOnscreen: false)]) == nil)
  }

  @Test("One onscreen duplicate is selected and native action visibility remains enforced")
  func selectsVisibleDuplicate() {
    let hidden = window(isOnscreen: false)
    let visible = window(id: 11)
    #expect(NativeMenuBarController.matchingStatusWindow(for: item(),
      in: [hidden, visible], requiringOnscreen: true)?.binding.id == visible.binding.id)
    #expect(NativeMenuBarController.matchingStatusWindow(for: item(),
      in: [hidden])?.binding.id == hidden.binding.id)
    #expect(NativeMenuBarController.matchingStatusWindow(for: item(),
      in: [hidden], requiringOnscreen: true) == nil)
  }

  private func item(frame: ItemFrame? = ItemFrame(x: 1200, y: 6, width: 24, height: 24))
    -> RawSourceItemObservation {
    RawSourceItemObservation(runtimeID: "100:0", processIdentifier: 100,
      bundleIdentifier: "example.source", applicationName: "Source", role: "AXMenuBarItem",
      frame: frame, actions: ["AXPress"], metadata: LiveAccessibilityMetadata(),
      observedOrder: 0, isOnscreen: true, statusWindowIdentifier: 10)
  }

  private func window(id: UInt32 = 10, pid: Int32 = 100, bundle: String = "example.source",
    frame: ItemFrame? = nil, isOnscreen: Bool = true) -> NativeMenuBarController.StatusWindow {
    (.init(id: id, pid: pid, bundle: bundle), frame ?? self.frame, isOnscreen)
  }
}

import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Native Menu Bar ordering")
@MainActor
struct MenuBarOrderTests {
  @Test("A reversed pair moves the desired left source before the current left source")
  func reversesPair() throws {
    let move = try #require(NativeMenuBarController.nextMenuBarOrderMove(
      desired: ["broglow", "tunnelblick"], current: ["tunnelblick", "broglow"]))
    #expect(move.source == "broglow")
    #expect(move.anchor == "tunnelblick")
    let reverse = try #require(NativeMenuBarController.nextMenuBarOrderMove(
      desired: ["tunnelblick", "broglow"], current: ["broglow", "tunnelblick"]))
    #expect(reverse.source == "tunnelblick")
    #expect(reverse.anchor == "broglow")
  }

  @Test("Each insertion fixes the first mismatch while retaining unrelated sources")
  func preservesUnrelatedOrder() throws {
    let desired = ["third", "second", "first"]
    var native = ["first", "protected-left", "second", "protected-right", "third"]
    for _ in 0..<desired.count {
      let manageable = native.filter { desired.contains($0) }
      guard let move = NativeMenuBarController.nextMenuBarOrderMove(desired: desired, current: manageable)
      else { break }
      native.removeAll { $0 == move.source }
      let anchor = try #require(native.firstIndex(of: move.anchor))
      native.insert(move.source, at: anchor)
    }
    #expect(native.filter { desired.contains($0) } == desired)
    #expect(native.filter { !desired.contains($0) } == ["protected-left", "protected-right"])
  }

  @Test("Settled, empty, missing, extra, and duplicate identities do not produce a move")
  func rejectsInvalidPermutations() {
    for (desired, current) in [
      ([String](), [String]()),
      (["first"], ["first"]),
      (["first", "second"], ["first", "second"]),
      (["first", "second"], ["first"]),
      (["first"], ["first", "second"]),
      (["first", "second"], ["first", "other"]),
      (["first", "first"], ["first", "second"]),
      (["first", "second"], ["first", "first"]),
    ] {
      #expect(NativeMenuBarController.nextMenuBarOrderMove(desired: desired, current: current) == nil)
    }
  }

  @Test("Clipped sources are omitted while the visible pair retains its requested order")
  func omitsKnownClippedSources() throws {
    let items = [
      item("clipped", x: 20, onscreen: false),
      item("broglow", x: 150),
      item("offscreen", x: -100, onscreen: false),
      item("tunnelblick", x: 100),
      item("under-camera", x: 210),
    ]
    let visible = try #require(NativeMenuBarController.visibleMenuBarOrderKeys(items,
      boundary: ItemFrame(x: 50, y: 0, width: 2, height: 24),
      safeFrame: ItemFrame(x: 80, y: 0, width: 420, height: 24),
      displayFrame: ItemFrame(x: 0, y: 0, width: 500, height: 24),
      occlusionFrame: ItemFrame(x: 200, y: 0, width: 40, height: 24)))
    #expect(visible == ["example.broglow", "example.tunnelblick"])
    let desired = items.compactMap(\.identity.persistentKey).filter { visible.contains($0) }
    let move = try #require(NativeMenuBarController.nextMenuBarOrderMove(
      desired: desired, current: ["example.tunnelblick", "example.broglow"]))
    #expect(move.source == "example.broglow")
    #expect(move.anchor == "example.tunnelblick")
  }

  @Test("Unknown geometry or a visible source outside the safe row cannot be silently omitted")
  func rejectsUnsafeOmissions() {
    let boundary = ItemFrame(x: 50, y: 0, width: 2, height: 24)
    let safe = ItemFrame(x: 80, y: 0, width: 420, height: 24)
    let display = ItemFrame(x: 0, y: 0, width: 500, height: 24)
    for unsafe in [item("unknown", x: 20, onscreen: nil),
      item("visible-behind", x: 20), item("other-row", x: 100, y: 50),
      item("missing-frame", x: 100, width: 0)] {
      #expect(NativeMenuBarController.visibleMenuBarOrderKeys([unsafe], boundary: boundary,
        safeFrame: safe, displayFrame: display) == nil)
    }
  }

  private func item(_ name: String, x: Double, y: Double = 0, width: Double = 24,
    onscreen: Bool? = true) -> ClassifiedSourceItem {
    IdentityAssessor().classify([
      RawSourceItemObservation(runtimeID: name, processIdentifier: 100,
        bundleIdentifier: "example.\(name)", applicationName: name, role: "AXMenuBarItem",
        frame: ItemFrame(x: x, y: y, width: width, height: 24), actions: ["AXPress"],
        metadata: LiveAccessibilityMetadata(), observedOrder: 0, isOnscreen: onscreen),
    ])[0]
  }
}

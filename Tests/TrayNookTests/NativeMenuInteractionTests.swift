import AppKit
import Testing

@testable import TrayNook

@Suite("Native interaction lifetime")
@MainActor
struct NativeMenuInteractionTests {
  @Test("Custom status-level panels are observed without treating source icons as panels")
  func statusLevelPanels() {
    let layer = Int(CGWindowLevelForKey(.statusWindow))
    let rows = [CGRect(x: 0, y: 0, width: 1728, height: 37)]
    #expect(NativeMenuInteraction.isPanelWindow(
      frame: CGRect(x: 900, y: 30, width: 420, height: 300), layer: layer, menuBarRows: rows))
    #expect(NativeMenuInteraction.isPanelWindow(
      frame: CGRect(x: 900, y: 80, width: 300, height: 50), layer: layer, menuBarRows: rows))
    #expect(!NativeMenuInteraction.isPanelWindow(
      frame: CGRect(x: 1100, y: 0, width: 38, height: 37), layer: layer, menuBarRows: rows))
    #expect(!NativeMenuInteraction.isPanelWindow(
      frame: CGRect(x: 1100, y: 0, width: 38, height: 37), layer: layer, menuBarRows: []))
  }

  @Test("A long-lived menu retains its dismissal state after the foreground timeout")
  func longMenuStillCloses() {
    let started = ContinuousClock.now
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [1])
    state.menuOpened()
    let stillOpen = state.dismissed(currentWindows: [1], at: started.advanced(by: .seconds(61)))
    #expect(!stillOpen)
    #expect(state.observedInterface)
    state.menusClosed(at: started.advanced(by: .seconds(62)))
    let justClosed = state.dismissed(currentWindows: [1], at: started.advanced(by: .seconds(62)))
    #expect(!justClosed)
    let dismissed = state.dismissed(currentWindows: [1], at: started.advanced(by: .milliseconds(62_200)))
    #expect(dismissed)
  }

  @Test("Menu dismissal waits for its observed panel, while existing windows remain irrelevant")
  func menuAndPanelDismissTogether() {
    let started = ContinuousClock.now
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [1])
    state.menuOpened()
    let menuAndPanel = state.dismissed(currentWindows: [1, 2], at: started)
    #expect(!menuAndPanel)
    state.menusClosed(at: started)
    let panelRemains = state.dismissed(currentWindows: [1, 2], at: started.advanced(by: .seconds(1)))
    #expect(!panelRemains)
    let panelJustClosed = state.dismissed(currentWindows: [1], at: started.advanced(by: .seconds(2)))
    #expect(!panelJustClosed)
    let dismissed = state.dismissed(currentWindows: [1], at: started.advanced(by: .milliseconds(2_200)))
    #expect(dismissed)
  }

  @Test("Unavailable window metadata and unobserved UI cannot prove dismissal")
  func missingMetadataDoesNotDismiss() {
    let started = ContinuousClock.now
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [])
    let unobserved = state.dismissed(currentWindows: [], at: started.advanced(by: .seconds(90)))
    #expect(!unobserved)
    let appeared = state.dismissed(currentWindows: [2], at: started)
    #expect(!appeared)
    let unavailable = state.dismissed(currentWindows: nil, at: started.advanced(by: .seconds(90)))
    #expect(!unavailable)
  }

  @Test("An observed panel remains open when the same window moves into source-row geometry")
  func panelShapeChangeIsNotClosure() throws {
    let row = CGRect(x: 0, y: 0, width: 1728, height: 37)
    func metadata(_ bounds: [String: Any]) -> [[String: Any]] {
      [[kCGWindowOwnerPID as String: NSNumber(value: 100),
        kCGWindowNumber as String: NSNumber(value: 2),
        kCGWindowLayer as String: NSNumber(value: CGWindowLevelForKey(.statusWindow)),
        kCGWindowBounds as String: bounds]]
    }
    let panel = try #require(NativeMenuInteraction.windowSnapshot(in: metadata(
      CGRect(x: 900, y: 30, width: 420, height: 300).dictionaryRepresentation as NSDictionary as! [String: Any]),
      owner: 100, menuBarRows: [row]))
    let moved = try #require(NativeMenuInteraction.windowSnapshot(in: metadata(
      CGRect(x: 1100, y: 0, width: 38, height: 37).dictionaryRepresentation as NSDictionary as! [String: Any]),
      owner: 100, menuBarRows: [row]))
    let malformed = try #require(NativeMenuInteraction.windowSnapshot(in: metadata([:]),
      owner: 100, menuBarRows: [row]))
    #expect(moved.panelIDs.isEmpty)
    #expect(moved.visibleIDs == [2])
    #expect(malformed.visibleIDs == [2])

    let started = ContinuousClock.now
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [])
    let appeared = state.dismissed(currentWindows: panel.visibleIDs,
      candidatePanels: panel.panelIDs, at: started)
    #expect(!appeared)
    let resized = state.dismissed(currentWindows: moved.visibleIDs,
      candidatePanels: moved.panelIDs, at: started.advanced(by: .seconds(1)))
    #expect(!resized)
    let stillOpen = state.dismissed(currentWindows: malformed.visibleIDs,
      candidatePanels: malformed.panelIDs, at: started.advanced(by: .seconds(2)))
    #expect(!stillOpen)
  }

  @Test("Incomplete owner and ID enumeration cannot prove an observed panel closed")
  func incompleteWindowEnumerationIsUnknown() {
    #expect(NativeMenuInteraction.windowSnapshot(in: nil, owner: 100, menuBarRows: []) == nil)
    #expect(NativeMenuInteraction.windowSnapshot(in: [[kCGWindowOwnerPID as String: NSNumber(value: 100)]],
      owner: 100, menuBarRows: []) == nil)
    #expect(NativeMenuInteraction.windowSnapshot(in: [[kCGWindowNumber as String: NSNumber(value: 2)]],
      owner: 100, menuBarRows: []) == nil)
  }
}

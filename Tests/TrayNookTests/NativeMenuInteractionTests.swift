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

  @Test("An ordinary window never keeps an observed menu handoff open",
    arguments: [-1, 0, 1])
  func ordinaryWindowDoesNotHoldMenu(opensRelativeToMenu: Int) throws {
    let ordinary = window(2, layer: .normalWindow)
    let started = ContinuousClock.now
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [])
    if opensRelativeToMenu < 0 {
      #expect(try !dismissed(&state, windows: [ordinary], at: started))
    }
    state.menuOpened()
    let whileOpen = opensRelativeToMenu <= 0 ? [ordinary] : []
    #expect(try !dismissed(&state, windows: whileOpen, at: started))
    state.menusClosed(at: started)
    #expect(try !dismissed(&state, windows: [ordinary], at: started))
    #expect(try dismissed(&state, windows: [ordinary], at: started.advanced(by: .milliseconds(200))))
  }

  @Test("A replacement popup extends handoff without tracking an ordinary window")
  func popupReplacementDoesNotTrackOrdinaryWindow() throws {
    let ordinary = window(1, layer: .normalWindow)
    let firstMenu = window(2, layer: .popUpMenuWindow)
    let secondMenu = window(3, layer: .popUpMenuWindow, layerOffset: -1)
    let started = ContinuousClock.now
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [])
    #expect(try !dismissed(&state, windows: [ordinary, firstMenu], at: started))
    #expect(try !dismissed(&state, windows: [ordinary], at: started.advanced(by: .milliseconds(100))))
    #expect(try !dismissed(&state, windows: [ordinary, secondMenu], at: started.advanced(by: .milliseconds(200))))
    #expect(try !dismissed(&state, windows: [ordinary], at: started.advanced(by: .milliseconds(300))))
    #expect(try dismissed(&state, windows: [ordinary], at: started.advanced(by: .milliseconds(500))))
  }

  @Test("A custom panel at normal window level still holds a panel-only handoff")
  func customPanelWithoutMenuRemainsTracked() throws {
    let panel = window(2, layer: .normalWindow)
    let unrelatedMenu = window(3, layer: .popUpMenuWindow, owner: 101)
    let started = ContinuousClock.now
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [1])
    let existing = window(1, layer: .normalWindow)
    #expect(try !dismissed(&state, windows: [existing, panel, unrelatedMenu], at: started))
    #expect(state.observedWindowIDs == [2])
    #expect(try !dismissed(&state, windows: [existing, panel, unrelatedMenu], at: started.advanced(by: .seconds(1))))
    #expect(try !dismissed(&state, windows: [existing, unrelatedMenu], at: started.advanced(by: .seconds(2))))
    #expect(try dismissed(&state, windows: [existing, unrelatedMenu], at: started.advanced(by: .milliseconds(2_200))))
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

  private func window(_ id: UInt32, layer: CGWindowLevelKey, layerOffset: Int32 = 0,
    owner: Int32 = 100) -> [String: Any] {
    [kCGWindowOwnerPID as String: NSNumber(value: owner),
      kCGWindowNumber as String: NSNumber(value: id),
      kCGWindowLayer as String: NSNumber(value: CGWindowLevelForKey(layer) + layerOffset),
      kCGWindowBounds as String: CGRect(x: 800, y: 50, width: 450, height: 350).dictionaryRepresentation]
  }

  private func dismissed(_ state: inout NativeMenuInteraction.DismissalState,
    windows: [[String: Any]], at now: ContinuousClock.Instant) throws -> Bool {
    let snapshot = try #require(NativeMenuInteraction.windowSnapshot(in: windows, owner: 100,
      menuBarRows: [CGRect(x: 0, y: 0, width: 1728, height: 37)]))
    return state.dismissed(currentWindows: snapshot.visibleIDs, candidatePanels: snapshot.panelIDs,
      candidateNormalWindows: snapshot.normalWindowIDs, at: now)
  }
}

import Testing

@testable import TrayNook

@Suite("Placement updates")
@MainActor
struct PlacementUpdateTests {
  private let layout = SavedLayout(items: [
    SavedItem(id: "example.visible", placement: .menuBar),
    SavedItem(id: "example.dropdown", placement: .dropdown),
    SavedItem(id: "example.hidden", placement: .alwaysHidden),
  ])

  @Test("Changing hidden placements does not require applying unrelated Menu Bar items")
  func hidesOnlyTheChangedItems() {
    let batches: [Set<String>] = [["example.dropdown"], ["example.hidden"],
      ["example.dropdown", "example.hidden"]]
    for keys in batches {
      #expect(AppModel.canApplyPlacementsIndividually(keys: keys, layout: layout,
        concealed: true, hasPendingActivation: false))
    }
  }

  @Test("Visible and mixed placement batches move only their selected sources")
  func showsOnlyTheChangedItems() {
    for keys: Set<String> in [["example.visible"], ["example.visible", "example.dropdown"]] {
      #expect(AppModel.canApplyPlacementsIndividually(keys: keys, layout: layout,
        concealed: true, hasPendingActivation: false))
    }
  }

  @Test("Missing and empty batches cannot use individual placement")
  func rejectsIneligibleBatches() {
    let batches: [Set<String>] = [["example.missing"], ["example.dropdown", "example.missing"], []]
    for keys in batches {
      #expect(!AppModel.canApplyPlacementsIndividually(keys: keys, layout: layout,
        concealed: true, hasPendingActivation: false))
    }
  }

  @Test("Picker promotion inserts before existing apps and protected system items")
  func newMenuBarItemUsesLeftmostSlot() {
    var requested = SavedLayout(items: [
      SavedItem(id: "example.visible"),
      SavedItem(id: "com.apple.controlcenter"),
      SavedItem(id: "example.target", placement: .alwaysHidden),
      SavedItem(id: "example.other", placement: .dropdown),
    ])
    let unrelated = requested.items.filter { $0.id != "example.target" }
    requested.place("example.target", in: .menuBar)
    #expect(requested.items.filter { $0.placement == .menuBar }.map(\.id)
      == ["example.target", "example.visible", "com.apple.controlcenter"])
    #expect(requested.items.filter { $0.id != "example.target" } == unrelated)
  }

  @Test("Revealed sections and active native handoffs retain full-layout handling")
  func requiresIdleConcealment() {
    #expect(!AppModel.canApplyPlacementsIndividually(keys: ["example.dropdown"], layout: layout,
      concealed: false, hasPendingActivation: false))
    #expect(!AppModel.canApplyPlacementsIndividually(keys: ["example.dropdown"], layout: layout,
      concealed: true, hasPendingActivation: true))
  }

  @Test("Using another picker retains placement requests until physical input settles",
    arguments: [NativeMenuActionError.inputNotIdle, .inputInterrupted, .placementInterrupted])
  func retriesInputInterruptions(_ error: NativeMenuActionError) {
    #expect(AppModel.shouldRetryPlacement(after: error))
  }

  @Test("Cancellation and failures requiring user action never retry automatically")
  func stopsOnOtherFailures() {
    #expect(!AppModel.shouldRetryPlacement(after: CancellationError()))
    #expect(!AppModel.shouldRetryPlacement(after: NativeMenuActionError.inventoryUnavailable))
    #expect(!AppModel.shouldRetryPlacement(after: NativeMenuActionError.responseTimedOut))
    #expect(!AppModel.shouldRetryPlacement(after: AppError.message("placement mismatch")))
  }
}

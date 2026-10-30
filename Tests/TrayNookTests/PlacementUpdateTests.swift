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

  @Test("Visible, mixed, missing, and empty batches retain full-layout handling")
  func rejectsIneligibleBatches() {
    let batches: [Set<String>] = [["example.visible"], ["example.visible", "example.dropdown"],
      ["example.missing"], ["example.dropdown", "example.missing"], []]
    for keys in batches {
      #expect(!AppModel.canApplyPlacementsIndividually(keys: keys, layout: layout,
        concealed: true, hasPendingActivation: false))
    }
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

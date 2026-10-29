import Testing

@testable import TrayNook

@Suite("Placement update interruptions")
@MainActor
struct PlacementUpdateTests {
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

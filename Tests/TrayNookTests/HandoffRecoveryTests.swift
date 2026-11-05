import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Selected item return recovery")
@MainActor
struct HandoffRecoveryTests {
  private let source = NativeMenuBarController.StatusWindowBinding(id: 10, pid: 100, bundle: "example.source")
  private let original = NativeMenuBarController.StatusWindowBinding(id: 20, pid: 200, bundle: "example.neighbor")
  private let boundary = NativeMenuBarController.StatusWindowBinding(id: 30, pid: 300, bundle: "example.traynook")

  @Test("A vanished return neighbor falls back to the validated separator")
  func missingNeighborUsesBoundary() throws {
    #expect(try NativeMenuBarController.restorationAnchor(source: source, preferred: original,
      boundary: boundary, current: [source, boundary]) == boundary)
    let reused = NativeMenuBarController.StatusWindowBinding(id: original.id, pid: original.pid,
      bundle: "example.replacement")
    #expect(throws: NativeMenuActionError.inventoryUnavailable) {
      try NativeMenuBarController.restorationAnchor(source: source, preferred: original,
        boundary: boundary, current: [source, reused, boundary])
    }
  }

  @Test("Existing anchors retain their position, while vanished sources never move replacements")
  func exactBindingsRemainRequired() throws {
    #expect(try NativeMenuBarController.restorationAnchor(source: source, preferred: original,
      boundary: boundary, current: [source, original, boundary]) == original)
    let replacement = NativeMenuBarController.StatusWindowBinding(id: source.id, pid: source.pid,
      bundle: "example.replacement")
    #expect(throws: NativeMenuActionError.inventoryUnavailable) {
      try NativeMenuBarController.restorationAnchor(source: source, preferred: original,
        boundary: boundary, current: [replacement, original, boundary])
    }
    #expect(try NativeMenuBarController.restorationAnchor(source: source, preferred: original,
      boundary: boundary, current: [original, boundary]) == nil)
    #expect(throws: NativeMenuActionError.inventoryUnavailable) {
      try NativeMenuBarController.restorationAnchor(source: source, preferred: original,
        boundary: boundary, current: [source])
    }
  }

  @Test("Transient return failures retry only restoration after a paced delay")
  func transientReturnRetries() async throws {
    var pending = true
    var attempts = 0
    var delays: [Duration] = []
    try await NativeMenuBarController.retrySelectedReturn(isPending: { pending }, restore: {
      attempts += 1
      if attempts == 1 { throw NativeMenuActionError.inventoryUnavailable }
      pending = false
    }, sleep: { delays.append($0) })
    #expect(attempts == 2)
    #expect(delays == [.seconds(3)])
    #expect(!pending)
  }

  @Test("Cancellation and permanent failures do not replay the return")
  func permanentFailuresStop() async {
    for error: Error in [CancellationError(), NativeMenuActionError.responseTimedOut,
      AppError.message("ambiguous source")] {
      var attempts = 0
      var delays = 0
      await #expect(throws: (any Error).self) {
        try await NativeMenuBarController.retrySelectedReturn(isPending: { true }, restore: {
          attempts += 1
          throw error
        }, sleep: { _ in delays += 1 })
      }
      #expect(attempts == 1)
      #expect(delays == 0)
    }
  }

  @Test("A completed return performs no further native work")
  func completedReturnDoesNotReplay() async throws {
    var attempts = 0
    var delays = 0
    try await NativeMenuBarController.retrySelectedReturn(isPending: { false }, restore: {
      attempts += 1
    }, sleep: { _ in delays += 1 })
    #expect(attempts == 0)
    #expect(delays == 0)
  }

  @Test("A promoted source returns after proven pre-delivery failure without replaying activation",
    arguments: [NativeMenuActionError.inputNotIdle, .inventoryUnavailable])
  func undeliveredActivationReturns(_ failure: NativeMenuActionError) async throws {
    var promoted = true
    var pending = true
    var activationAttempts = 0
    var cleanupScheduled = false
    var returnAttempts = 0
    var delays: [Duration] = []
    await #expect(throws: failure) {
      try await AppModel.deliverActivationOnce(activate: {
        #expect(promoted)
        activationAttempts += 1
        throw failure
      }, cleanupUndelivered: { cleanupScheduled = true })
    }
    #expect(cleanupScheduled)
    if cleanupScheduled {
      try await NativeMenuBarController.retrySelectedReturn(isPending: { pending }, restore: {
        returnAttempts += 1
        if returnAttempts == 1 { throw NativeMenuActionError.inputNotIdle }
        promoted = false
        pending = false
      }, sleep: { delays.append($0) })
    }
    #expect(activationAttempts == 1)
    #expect(returnAttempts == 2)
    #expect(delays == [.seconds(3)])
    #expect(!promoted)
  }

  @Test("Uncertain delivery and cancellation never trigger undelivered-action cleanup")
  func uncertainDeliveryIsNotCleanedUp() async {
    for error: Error in [NativeMenuActionError.responseTimedOut, NativeMenuActionError.placementInterrupted,
      CancellationError(), AppError.message("unknown delivery")] {
      var cleanupAttempts = 0
      await #expect(throws: (any Error).self) {
        try await AppModel.deliverActivationOnce(activate: { throw error },
          cleanupUndelivered: { cleanupAttempts += 1 })
      }
      #expect(cleanupAttempts == 0)
    }
  }

  @Test("Explicit cancellation prevents delivery and new cleanup work")
  func cancelledActivationDoesNotScheduleCleanup() async {
    var activationAttempts = 0
    var cleanupAttempts = 0
    let operation = Task { @MainActor in
      await #expect(throws: CancellationError.self) {
        try await AppModel.deliverActivationOnce(activate: { activationAttempts += 1 },
          cleanupUndelivered: { cleanupAttempts += 1 })
      }
    }
    operation.cancel()
    _ = await operation.value
    #expect(activationAttempts == 0)
    #expect(cleanupAttempts == 0)
  }

  @Test("An original neighbor moved visibly cannot be used as a hidden return destination")
  func visibleNeighborUsesBoundary() throws {
    #expect(try NativeMenuBarController.restorationAnchor(source: source, preferred: original,
      boundary: boundary, current: [source, original, boundary], preferredIsHidden: false) == boundary)
    #expect(!NativeMenuBarController.restorationVerified(
      source: ItemFrame(x: 1200, y: 0, width: 24, height: 37),
      destination: ItemFrame(x: 1224, y: 0, width: 24, height: 37),
      boundary: ItemFrame(x: -599, y: 7.5, width: 1730, height: 22), originalGap: 0))
    #expect(NativeMenuBarController.restorationVerified(
      source: ItemFrame(x: -645, y: 0, width: 38, height: 37),
      destination: ItemFrame(x: -607, y: 0, width: 1746, height: 37),
      boundary: ItemFrame(x: -599, y: 7.5, width: 1730, height: 22), originalGap: nil))
  }

  @Test("Confirmed owner termination retires an open-menu handoff without moving its replacement")
  func terminatedOwnerReleasesPendingHandoff() throws {
    var state = NativeMenuInteraction.DismissalState(windowsBefore: [])
    state.menuOpened()
    let dismissed = state.dismissed(currentWindows: [], ownerTerminated: true, at: .now)
    #expect(dismissed)
    var pending = true
    if dismissed {
      let destination = try NativeMenuBarController.restorationAnchor(source: source,
        preferred: original, boundary: boundary, current: [original, boundary])
      if destination == nil { pending = false }
    }
    #expect(!pending)

    var unobservable = NativeMenuInteraction.DismissalState(windowsBefore: nil)
    let terminatedWithoutUI = unobservable.dismissed(currentWindows: nil,
      ownerTerminated: true, at: .now)
    #expect(terminatedWithoutUI)
  }
}

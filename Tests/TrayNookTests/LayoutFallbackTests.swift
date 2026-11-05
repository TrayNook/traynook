import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Layout concealment fallbacks")
@MainActor
struct LayoutFallbackTests {
  private let placements = [SavedItem(id: "example.refusing", placement: .dropdown),
    SavedItem(id: "example.working", placement: .alwaysHidden)]

  @Test("One refusing source does not prevent another source from being hidden")
  func isolatesSourceFailure() async throws {
    var calls: [String] = []
    let warnings = try await AppModel.applyPlacementsWithFallback(placements, move: { saved in
      calls.append("move:\(saved.id)")
      if saved.id == "example.refusing" { throw AppError.message("Refusing app: placement failed") }
      return true
    }, refresh: { calls.append("refresh") }, repairBoundary: { calls.append("repair") },
      conceal: { calls.append("conceal") }, reorder: { calls.append("reorder") })
    #expect(calls == ["move:example.refusing", "refresh", "repair", "refresh",
      "move:example.working", "refresh", "conceal", "reorder"])
    #expect(warnings == ["Refusing app: placement failed"])
    #expect(placements.map(\.placement) == [.dropdown, .alwaysHidden])
  }

  @Test("Repairing a failed source's boundary rechecks previously hidden sources")
  func rechecksPlacementsAfterBoundaryRepair() async throws {
    let requested = [SavedItem(id: "example.first", placement: .dropdown),
      SavedItem(id: "example.refusing", placement: .dropdown)]
    var firstHidden = false
    var firstMoves = 0
    var refusedMoves = 0
    var concealed = false
    let warnings = try await AppModel.applyPlacementsWithFallback(requested, move: { saved in
      if saved.id == "example.refusing" {
        refusedMoves += 1
        throw AppError.message("Refusing app: placement failed")
      }
      guard !firstHidden else { return false }
      firstHidden = true
      firstMoves += 1
      return true
    }, refresh: {}, repairBoundary: {
      firstHidden = false // Keeping a new protected source visible shifts the divider left.
    }, conceal: {
      #expect(firstHidden, "Boundary repair must not strand a previously placed hidden source.")
      concealed = true
    }, reorder: {})
    #expect(concealed)
    #expect(firstHidden)
    #expect(firstMoves == 2)
    #expect(refusedMoves == 1, "A refused source is not replayed during replanning.")
    #expect(warnings == ["Refusing app: placement failed"])
  }

  @Test("Optional Menu Bar order failure preserves completed concealment")
  func orderFailureDoesNotBlockConcealment() async throws {
    var hidden = false
    let warnings = try await AppModel.applyPlacementsWithFallback([], move: { _ in false },
      refresh: {}, repairBoundary: {}, conceal: { hidden = true }, reorder: {
        #expect(hidden)
        throw AppError.message("Visible app rejected ordering")
      })
    #expect(hidden)
    #expect(warnings == ["Visible app rejected ordering"])
  }

  @Test("Typed transient or uncertain-delivery errors are never downgraded to source warnings",
    arguments: [NativeMenuActionError.inventoryUnavailable, .inputNotIdle, .responseTimedOut])
  func propagatesNativeFailures(_ error: NativeMenuActionError) async throws {
    var followingActions = 0
    do {
      _ = try await AppModel.applyPlacementsWithFallback(placements, move: { _ in throw error },
        refresh: { followingActions += 1 }, repairBoundary: { followingActions += 1 },
        conceal: { followingActions += 1 }, reorder: { followingActions += 1 })
      Issue.record("The native error must abort this attempt")
    } catch let caught as NativeMenuActionError { #expect(caught == error) }
    #expect(followingActions == 0)
  }

  @Test("A failed permission, complete-inventory, or identity recheck prevents fallback native work",
    arguments: ["Permission unavailable", "Complete inventory unavailable", "Source identity reassigned"])
  func freshInventoryFailureStopsFallback(_ reason: String) async throws {
    var repairs = 0
    var concealed = false
    do {
      _ = try await AppModel.applyPlacementsWithFallback(placements, move: { _ in
        throw AppError.message("Source refused placement")
      }, refresh: { throw AppError.message(reason) },
        repairBoundary: { repairs += 1 }, conceal: { concealed = true }, reorder: {})
      Issue.record("A failed fresh safety check must abort fallback")
    } catch {
      #expect(error.localizedDescription == reason)
    }
    #expect(repairs == 0)
    #expect(!concealed)
  }

  @Test("Cancellation never attempts another source or hides using unverified state")
  func cancellationStopsFallback() async throws {
    var followingActions = 0
    do {
      _ = try await AppModel.applyPlacementsWithFallback(placements, move: { _ in throw CancellationError() },
        refresh: { followingActions += 1 }, repairBoundary: { followingActions += 1 },
        conceal: { followingActions += 1 }, reorder: { followingActions += 1 })
      Issue.record("Cancellation must propagate")
    } catch is CancellationError {}
    #expect(followingActions == 0)
  }

  @Test("A final unsafe concealment failure is not reported as partial success")
  func concealmentSafetyFailurePropagates() async throws {
    var reordered = false
    do {
      _ = try await AppModel.applyPlacementsWithFallback([], move: { _ in false }, refresh: {},
        repairBoundary: {}, conceal: { throw AppError.message("Unassigned source behind boundary") },
        reorder: { reordered = true })
      Issue.record("Unsafe concealment must propagate")
    } catch { #expect(error.localizedDescription == "Unassigned source behind boundary") }
    #expect(!reordered)
  }

  @Test("Changing status-level preview panels cannot block source-row stability")
  func unrelatedPanelsDoNotInvalidateRow() {
    let row = ItemFrame(x: 956, y: -1, width: 772, height: 39)
    for source in [ItemFrame(x: 1100, y: 0, width: 38, height: 37),
      ItemFrame(x: -600, y: 0, width: 1730, height: 37),
      ItemFrame(x: 1200, y: 6.5, width: 24, height: 24)] {
      #expect(NativeMenuBarController.isStatusWindowOnRow(source, row: row))
    }
    for panel in [ItemFrame(x: 24, y: 19, width: 1680, height: 1079),
      ItemFrame(x: 778, y: 1066, width: 172, height: 36),
      ItemFrame(x: 1100, y: -1440, width: 38, height: 24)] {
      #expect(!NativeMenuBarController.isStatusWindowOnRow(panel, row: row))
    }
  }
}

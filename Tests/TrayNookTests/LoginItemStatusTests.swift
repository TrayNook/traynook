import AppKit
import InventoryIdentityCore
import ServiceManagement
import Testing

@testable import TrayNook

@Suite("Login item status refresh")
@MainActor
struct LoginItemStatusTests {
  @Test("Cached presentation reads do not query the service")
  func cachedReads() {
    let fixture = Fixture(status: .enabled)
    let login = fixture.makeStatus()
    #expect(fixture.reads == 1)
    for _ in 0..<10 {
      #expect(login.isEnabled)
      #expect(login.status == .enabled)
    }
    #expect(fixture.reads == 1)
  }

  @Test("Explicit refresh observes an external setting change with one query")
  func externalChange() {
    let fixture = Fixture(status: .enabled)
    let login = fixture.makeStatus()
    fixture.status = .notRegistered
    #expect(login.isEnabled)
    #expect(login.refresh() == .notRegistered)
    #expect(!login.isEnabled)
    #expect(fixture.reads == 2)
    #expect(fixture.registrations == 0 && fixture.unregistrations == 0)
  }

  @Test("Changes refresh the actual result, including required approval")
  func settingChanges() throws {
    let fixture = Fixture(status: .notRegistered)
    let login = fixture.makeStatus()
    fixture.afterRegister = .requiresApproval
    #expect(try login.setEnabled(true) == .requiresApproval)
    #expect(!login.isEnabled)
    #expect(fixture.registrations == 1 && fixture.unregistrations == 0)
    #expect(fixture.reads == 2)

    fixture.status = .enabled
    fixture.afterUnregister = .notRegistered
    #expect(try login.setEnabled(false) == .notRegistered)
    #expect(!login.isEnabled)
    #expect(fixture.registrations == 1 && fixture.unregistrations == 1)
    #expect(fixture.reads == 3)
  }

  @Test("A failed change still refreshes actual state and preserves the error")
  func failedChanges() {
    for enabled in [true, false] {
      let fixture = Fixture(status: .notRegistered)
      let login = fixture.makeStatus()
      fixture.status = .enabled
      fixture.failure = true
      #expect(throws: Fixture.Failure.operation) { try login.setEnabled(enabled) }
      #expect(login.isEnabled)
      #expect(fixture.reads == 2)
      #expect(fixture.registrations == (enabled ? 1 : 0))
      #expect(fixture.unregistrations == (enabled ? 0 : 1))
    }
  }

  @Test("Inventory polling reuses cached login state while General refreshes external changes",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  func modelRefreshTriggers() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let native = NativeMenuBarController(launcher: launcher)
    launcher.isVisible = false
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
    }
    let fixture = Fixture(status: .enabled)
    let login = fixture.makeStatus()
    let model = AppModel(native: native, store: nil, loginItemStatus: login)
    #expect(fixture.reads == 1)
    #expect(model.loginEnabled)

    let inventory = InventorySnapshot(capturedAt: Date(), permission: .granted, completeness: .complete,
      items: [], warnings: [],
      metrics: ScanMetrics(durationMilliseconds: 0, inspectedApplicationCount: 0, sourceItemCount: 0))
    model.accept(inventory)
    model.accept(inventory)
    #expect(fixture.reads == 1)

    fixture.status = .notRegistered
    model.selectedTab = 2
    #expect(fixture.reads == 2)
    #expect(!model.loginEnabled)
    model.selectedTab = 2
    #expect(fixture.reads == 2)

    fixture.status = .enabled
    model.refreshLoginStatus()
    #expect(fixture.reads == 3)
    #expect(model.loginEnabled)

    fixture.afterRegister = .requiresApproval
    model.setLoginEnabled(true)
    #expect(fixture.reads == 4)
    #expect(!model.loginEnabled)
    #expect(model.message == L("Approve TrayNook in System Settings → General → Login Items."))

    fixture.status = .enabled
    fixture.failure = true
    model.setLoginEnabled(false)
    #expect(fixture.reads == 5)
    #expect(model.loginEnabled)
    #expect(model.message == L("Could not change Launch at Login. Check System Settings → General → Login Items."))
  }
}

@MainActor
private final class Fixture {
  enum Failure: Error, Equatable { case operation }
  var status: SMAppService.Status
  var afterRegister = SMAppService.Status.enabled
  var afterUnregister = SMAppService.Status.notRegistered
  var failure = false
  var reads = 0
  var registrations = 0
  var unregistrations = 0

  init(status: SMAppService.Status) { self.status = status }

  func makeStatus() -> LoginItemStatus {
    LoginItemStatus(read: {
      self.reads += 1
      return self.status
    }, register: {
      self.registrations += 1
      if self.failure { throw Failure.operation }
      self.status = self.afterRegister
    }, unregister: {
      self.unregistrations += 1
      if self.failure { throw Failure.operation }
      self.status = self.afterUnregister
    })
  }
}

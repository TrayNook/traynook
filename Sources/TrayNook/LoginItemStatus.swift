import ServiceManagement

@MainActor
final class LoginItemStatus {
  private let read: () -> SMAppService.Status
  private let register: () throws -> Void
  private let unregister: () throws -> Void
  private(set) var status: SMAppService.Status

  var isEnabled: Bool { status == .enabled }

  init(read: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
    register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
    unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
    self.read = read
    self.register = register
    self.unregister = unregister
    status = read()
  }

  @discardableResult
  func refresh() -> SMAppService.Status {
    status = read()
    return status
  }

  @discardableResult
  func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
    do {
      if enabled { try register() }
      else { try unregister() }
    } catch {
      refresh()
      throw error
    }
    return refresh()
  }
}

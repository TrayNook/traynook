import AppKit

/// Presentation-only cache. Native interaction still resolves and validates its own targets.
@MainActor
final class ApplicationIconCache {
  private struct Application {
    let url: URL?
    let retryAfter: TimeInterval
    var icon: NSImage?
  }

  private var applications: [String: Application] = [:]
  private var symbols: [String: NSImage] = [:]
  private let resolveApplication: @MainActor (String) -> URL?
  private let loadIcon: @MainActor (URL) -> NSImage
  private let loadSymbol: @MainActor (String) -> NSImage?
  private let uptime: @MainActor () -> TimeInterval

  init(resolveApplication: @escaping @MainActor (String) -> URL? = {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
  }, loadIcon: @escaping @MainActor (URL) -> NSImage = {
    NSWorkspace.shared.icon(forFile: $0.path)
  }, loadSymbol: @escaping @MainActor (String) -> NSImage? = {
    NSImage(systemSymbolName: $0, accessibilityDescription: nil)
  }, uptime: @escaping @MainActor () -> TimeInterval = {
    ProcessInfo.processInfo.systemUptime
  }) {
    self.resolveApplication = resolveApplication
    self.loadIcon = loadIcon
    self.loadSymbol = loadSymbol
    self.uptime = uptime
  }

  func applicationURL(for bundle: String) -> URL? {
    if let cached = applications[bundle], cached.url != nil || uptime() < cached.retryAfter {
      return cached.url
    }
    let url = resolveApplication(bundle)
    // Back off repeated missing-app lookups during redraws, but discover later installs.
    applications[bundle] = Application(url: url, retryAfter: uptime() + 2)
    return url
  }

  func icon(bundle: String, systemSymbol: String? = nil) -> NSImage {
    if let systemSymbol, let image = symbol(systemSymbol) { return image }
    if let url = applicationURL(for: bundle) {
      if let image = applications[bundle]?.icon { return image }
      let image = loadIcon(url)
      applications[bundle]?.icon = image
      return image
    }
    return symbol("app.dashed")!
  }

  func invalidate(bundle: String) {
    applications.removeValue(forKey: bundle)
  }

  func invalidateAll() {
    applications.removeAll()
    symbols.removeAll()
  }

  private func symbol(_ name: String) -> NSImage? {
    if let image = symbols[name] { return image }
    guard let image = loadSymbol(name) else { return nil }
    symbols[name] = image
    return image
  }
}

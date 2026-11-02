import AppKit
import Testing

@testable import TrayNook

@Suite("Application icon cache")
@MainActor
struct ApplicationIconCacheTests {
  @Test("Warm URL and icon requests share one application lookup and image")
  func warmApplication() {
    let url = URL(fileURLWithPath: "/Applications/Fixture.app")
    let image = NSImage(size: NSSize(width: 26, height: 26))
    var resolutions = 0
    var loads = 0
    let cache = ApplicationIconCache(resolveApplication: { _ in resolutions += 1; return url },
      loadIcon: { loadedURL in
        #expect(loadedURL == url)
        loads += 1
        return image
      })

    #expect(cache.applicationURL(for: "example.app") == url)
    for _ in 0..<20 {
      #expect(cache.icon(bundle: "example.app") === image)
      #expect(cache.applicationURL(for: "example.app") == url)
    }
    #expect(resolutions == 1)
    #expect(loads == 1)
  }

  @Test("Missing apps back off redraw lookups and discover a later installation")
  func missingApplicationExpires() {
    let url = URL(fileURLWithPath: "/Applications/Installed Later.app")
    let image = NSImage(size: NSSize(width: 26, height: 26))
    let fallback = NSImage(size: NSSize(width: 26, height: 26))
    let state = ApplicationLookupState()
    var resolutions = 0
    var fallbackLoads = 0
    let cache = ApplicationIconCache(resolveApplication: { _ in
      resolutions += 1
      return state.url
    }, loadIcon: { _ in image }, loadSymbol: { name in
      #expect(name == "app.dashed")
      fallbackLoads += 1
      return fallback
    }, uptime: { state.uptime })

    for _ in 0..<20 { #expect(cache.icon(bundle: "example.later") === fallback) }
    #expect(resolutions == 1)
    #expect(fallbackLoads == 1)
    state.url = url
    state.uptime = 1
    #expect(cache.applicationURL(for: "example.later") == nil)
    state.uptime = 2
    #expect(cache.applicationURL(for: "example.later") == url)
    #expect(cache.icon(bundle: "example.later") === image)
    #expect(resolutions == 2)
  }

  @Test("Application invalidation reloads a changed path without discarding other apps")
  func invalidatesChangedApplication() {
    let oldURL = URL(fileURLWithPath: "/Applications/Old.app")
    let newURL = URL(fileURLWithPath: "/Volumes/Apps/New.app")
    let state = ApplicationLookupState(url: oldURL)
    var resolutions: [String] = []
    var loadedPaths: [URL] = []
    let cache = ApplicationIconCache(resolveApplication: { bundle in
      resolutions.append(bundle)
      return state.url
    }, loadIcon: { url in
      loadedPaths.append(url)
      return NSImage(size: NSSize(width: 26, height: 26))
    })
    let previous = cache.icon(bundle: "example.first")
    let unaffected = cache.icon(bundle: "example.second")
    state.url = newURL
    cache.invalidate(bundle: "example.first")
    let reloaded = cache.icon(bundle: "example.first")

    #expect(reloaded !== previous)
    #expect(cache.applicationURL(for: "example.first") == newURL)
    #expect(cache.icon(bundle: "example.second") === unaffected)
    #expect(resolutions == ["example.first", "example.second", "example.first"])
    #expect(loadedPaths == [oldURL, oldURL, newURL])
    cache.invalidateAll()
    #expect(cache.icon(bundle: "example.second") !== unaffected)
    #expect(cache.applicationURL(for: "example.second") == newURL)
  }

  @Test("System symbols are shared by symbol name and bypass application lookups")
  func cachesSymbols() {
    var resolutions = 0
    var loadedSymbols: [String] = []
    let cache = ApplicationIconCache(resolveApplication: { _ in resolutions += 1; return nil },
      loadSymbol: { name in
        loadedSymbols.append(name)
        return NSImage(size: NSSize(width: 26, height: 26))
      })
    let clock = cache.icon(bundle: "com.apple.controlcenter", systemSymbol: "clock")
    #expect(cache.icon(bundle: "com.apple.other", systemSymbol: "clock") === clock)
    #expect(cache.icon(bundle: "com.apple.controlcenter", systemSymbol: "wifi") !== clock)
    #expect(loadedSymbols == ["clock", "wifi"])
    #expect(resolutions == 0)
    cache.invalidateAll()
    #expect(cache.icon(bundle: "com.apple.controlcenter", systemSymbol: "clock") !== clock)
    #expect(loadedSymbols == ["clock", "wifi", "clock"])
  }
}

@MainActor
private final class ApplicationLookupState {
  var url: URL?
  var uptime: TimeInterval = 0

  init(url: URL? = nil) { self.url = url }
}

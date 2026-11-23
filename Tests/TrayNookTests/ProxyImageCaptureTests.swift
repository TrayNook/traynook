import AppKit
import Combine
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Proxy image capture")
struct ProxyImageCaptureTests {
  @Test("Majority luminance of opaque pixels picks the backdrop; transparent pixels are ignored")
  func glyphBrightness() {
    // 2x2 premultiplied RGBA: white, black, transparent white, half-alpha white.
    let mixed: [UInt8] = [
      255, 255, 255, 255,
      0, 0, 0, 255,
      255, 255, 255, 0,
      128, 128, 128, 128,
    ]
    #expect(ProxyImageCapture.glyphsAreLight(rgba: mixed, width: 2, height: 2) == true)
    let darkMajority: [UInt8] = [
      255, 255, 255, 255,
      0, 0, 0, 255,
      0, 0, 0, 255,
      40, 40, 40, 255,
    ]
    #expect(ProxyImageCapture.glyphsAreLight(rgba: darkMajority, width: 2, height: 2) == false)
    let empty: [UInt8] = [255, 255, 255, 0, 0, 0, 0, 0]
    #expect(ProxyImageCapture.glyphsAreLight(rgba: empty, width: 2, height: 1) == nil)
    #expect(ProxyImageCapture.glyphsAreLight(rgba: empty, width: 3, height: 1) == nil)
  }

  @Test("Grey and white glyphs are monochrome; a red icon is not; antialiased edges do not count")
  func monochromeDetection() {
    let white: [UInt8] = [255, 255, 255, 255, 128, 128, 128, 255, 0, 0, 0, 0]
    #expect(ProxyImageCapture.glyphsAreMonochrome(rgba: white))
    let red: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255]
    #expect(!ProxyImageCapture.glyphsAreMonochrome(rgba: red))
    let faintlyTinted: [UInt8] = [200, 200, 210, 255]
    #expect(ProxyImageCapture.glyphsAreMonochrome(rgba: faintlyTinted))
    #expect(ProxyImageCapture.glyphsAreMonochrome(rgba: []))
  }

  @Test("An unchanged or empty capture preserves the glyph, but a new point size updates it")
  func repeatedPixels() throws {
    let frame = ItemFrame(x: 100, y: 6, width: 24, height: 24)
    let white = try sampleImage(.white)
    let first = try #require(ProxyImageCapture.prepare(white, frame: frame, previous: nil))
    #expect(ProxyImageCapture.prepare(white, frame: frame, previous: first) == nil)
    #expect(ProxyImageCapture.prepare(try sampleImage(.clear), frame: frame, previous: first) == nil)
    let resized = ItemFrame(x: 100, y: 6, width: 12, height: 12)
    #expect(ProxyImageCapture.prepare(white, frame: resized, previous: first)?.image.size
      == NSSize(width: 12, height: 12))
  }

  @Test("Glyph refresh publishes only when the captured preview changes",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  @MainActor
  func publishesChangedGlyphOnly() throws {
    let frame = ItemFrame(x: 100, y: 6, width: 24, height: 24)
    let raw = RawSourceItemObservation(runtimeID: "1:0", processIdentifier: 1,
      bundleIdentifier: "example.source", applicationName: "Source", role: "AXMenuBarItem",
      frame: frame, actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: 0,
      isOnscreen: true, statusWindowIdentifier: 1)
    let windows: [NativeMenuBarController.StatusWindow] = [
      (.init(id: 1, pid: 1, bundle: "example.source"), frame, true),
    ]
    let white = try sampleImage(.white)
    let red = try sampleImage(.red)
    withNativeController { native in
      let model = AppModel(native: native, store: nil)
      model.items = IdentityAssessor().classify([raw])
      model.layout.items = [SavedItem(id: "example.source", placement: .dropdown)]
      var publications = 0
      let subscription = model.$proxyImages.dropFirst().sink { _ in publications += 1 }
      defer { subscription.cancel() }

      for (image, expected) in [(white, 1), (white, 1), (red, 2), (red, 2)] {
        model.refreshProxyImages(showGlyphs: true, authorized: true, readWindows: { windows },
          capture: { _, frame, previous in ProxyImageCapture.prepare(image, frame: frame, previous: previous) })
        #expect(publications == expected)
      }
      #expect(model.proxyImages["example.source"]?.isMonochrome == false)
    }
  }

  @Test("App icon mode discards a previously captured glyph even with Screen Recording granted",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  @MainActor
  func appIconModeDiscardsCapture() {
    withNativeController { native in
      let model = AppModel(native: native, store: nil)
      model.layout.items = [SavedItem(id: "example.source", placement: .dropdown)]
      model.proxyImages["example.source"] = ProxyImage(image: NSImage(size: NSSize(width: 12, height: 12)),
        pixelWidth: 1, pixels: [255, 255, 255, 255], hasLightGlyphs: true, isMonochrome: true)

      model.refreshProxyImages(showGlyphs: true, authorized: true)
      #expect(model.proxyImages["example.source"] != nil)

      model.refreshProxyImages(showGlyphs: false, authorized: true)
      #expect(model.screenRecordingGranted)
      #expect(model.proxyImages.isEmpty)
    }
  }

  private func sampleImage(_ color: NSColor) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
      bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return try #require(context.makeImage())
  }

  @Test("Glyph refresh reads the window list once and skips hidden or replaced native windows",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  @MainActor
  func batchCaptureUsesOneCurrentSnapshot() {
    func observation(_ pid: Int32, isOnscreen: Bool = true) -> RawSourceItemObservation {
      RawSourceItemObservation(runtimeID: "\(pid):0", processIdentifier: pid,
        bundleIdentifier: "example.source\(pid)", applicationName: "Source", role: "AXMenuBarItem",
        frame: ItemFrame(x: 1000 + Double(pid) * 24, y: 6, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: Int(pid),
        isOnscreen: isOnscreen, statusWindowIdentifier: UInt32(pid))
    }
    let observations = [observation(1), observation(2), observation(3), observation(4)]
    let hidden = IdentityAssessor().classify([observation(5, isOnscreen: false)])
    let items = IdentityAssessor().classify(observations)
    let windows: [NativeMenuBarController.StatusWindow] = observations.compactMap { item in
      guard let frame = item.frame, let id = item.statusWindowIdentifier else { return nil }
      return (.init(id: id == 4 ? 40 : id, pid: item.processIdentifier, bundle: item.bundleIdentifier),
        frame, id != 3)
    }

    withNativeController { native in
      var reads = 0
      let read = { reads += 1; return windows }
      #expect(native.proxyCaptureWindows(for: hidden, readWindows: read).isEmpty)
      #expect(reads == 0)
      let targets = native.proxyCaptureWindows(for: items, readWindows: read)
      #expect(Set(targets.map { $0.window.binding.id }) == [1, 2])
      #expect(reads == 1)
    }
  }

  @MainActor
  private func withNativeController(_ test: (NativeMenuBarController) -> Void) {
    NSApplication.shared.setActivationPolicy(.accessory)
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let native = NativeMenuBarController(launcher: launcher)
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
    }
    test(native)
  }
}

import AppKit
import InventoryIdentityCore

/// Captured pixels of one status window. Held in memory for the session only;
/// never written to disk. Public capture works only while the window is
/// onscreen, so hidden items show their last image from when they were visible.
struct ProxyImage {
  let image: NSImage
  /// Light glyphs mean the source draws for a dark menu bar. The proxy cell
  /// uses a matching backdrop so the glyph stays visible in the dropdown.
  let hasLightGlyphs: Bool
}

enum ProxyImageCapture {
  static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

  /// Shows the system prompt once per process; later calls only open System Settings.
  static func request() {
    // TCC lists an app under Screen Recording only after it actually attempts a
    // capture; the request call alone did not register the ad-hoc build. One
    // onscreen pixel is enough and nothing is kept.
    _ = CGWindowListCreateImage(CGRect(x: 0, y: 0, width: 1, height: 1), .optionOnScreenOnly, kCGNullWindowID, [])
    if !CGRequestScreenCaptureAccess() {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
  }

  /// One onscreen status window. Returns nil without Screen Recording, and
  /// nil for offscreen windows: the public API does not composite those
  /// (verified on macOS 15.7; Ice needs a private SkyLight call for that).
  static func capture(windowID: UInt32, frame: ItemFrame) -> ProxyImage? {
    guard isAuthorized, frame.isUsable,
      let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(windowID),
        [.boundsIgnoreFraming, .bestResolution]),
      cgImage.width > 1, cgImage.height > 1,
      let pixels = rgba(of: cgImage),
      let light = glyphsAreLight(rgba: pixels, width: cgImage.width, height: cgImage.height)
    else { return nil }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: frame.width, height: frame.height))
    return ProxyImage(image: image, hasLightGlyphs: light)
  }

  private static func rgba(of image: CGImage) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return drawn ? pixels : nil
  }

  /// Majority luminance of the opaque pixels. nil when the capture is empty,
  /// which usually means the window has no backing store yet.
  static func glyphsAreLight(rgba: [UInt8], width: Int, height: Int) -> Bool? {
    guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
    var light = 0, dark = 0
    for offset in stride(from: 0, to: rgba.count, by: 4) {
      let alpha = Int(rgba[offset + 3])
      guard alpha >= 128 else { continue }
      // Premultiplied components lie in 0...alpha. Compare the weighted sum
      // against half brightness scaled by alpha instead of dividing first.
      let weighted = 299 * Int(rgba[offset]) + 587 * Int(rgba[offset + 1]) + 114 * Int(rgba[offset + 2])
      if weighted * 255 >= 128 * 1000 * alpha { light += 1 } else { dark += 1 }
    }
    guard light + dark > 0 else { return nil }
    return light >= dark
  }
}

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
}

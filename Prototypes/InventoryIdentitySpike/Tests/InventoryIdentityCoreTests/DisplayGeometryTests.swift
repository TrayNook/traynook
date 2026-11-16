import CoreGraphics
import Testing

@testable import InventoryIdentityCore

@Suite("Live display geometry")
struct DisplayGeometryTests {
  @Test("Null and disconnected display identifiers never reach the bounds reader")
  func unavailableDisplayDoesNotQueryBounds() {
    var queries = 0
    for display: CGDirectDisplayID in [kCGNullDirectDisplay, 99] {
      let result = DisplayGeometry.bounds(of: display, isOnline: { $0 == kCGNullDirectDisplay },
        readBounds: { _ in queries += 1; return CGRect(x: 0, y: 0, width: 100, height: 100) })
      #expect(result == nil)
    }
    #expect(queries == 0)
  }

  @Test("Disconnect during a bounds read rejects the result")
  func disconnectDuringRead() {
    var online = true
    let result = DisplayGeometry.bounds(of: 42, isOnline: { _ in online }, readBounds: { _ in
      online = false
      return CGRect(x: 0, y: 0, width: 100, height: 100)
    })
    #expect(result == nil)
  }

  @Test("Malformed bounds are unavailable even for an online display")
  func malformedBounds() {
    for frame in [CGRect.zero, CGRect(x: 0, y: 0, width: -100, height: 100),
      CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
      CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)] {
      #expect(DisplayGeometry.bounds(of: 42, isOnline: { _ in true }, readBounds: { _ in frame }) == nil)
    }
  }

  @Test("Online displays preserve native bounds including negative coordinates")
  func onlineBoundsArePreserved() {
    let frame = CGRect(x: -2560, y: -1440, width: 2560, height: 1440)
    #expect(DisplayGeometry.bounds(of: 42, isOnline: { _ in true }, readBounds: { _ in frame }) == frame)
  }
}

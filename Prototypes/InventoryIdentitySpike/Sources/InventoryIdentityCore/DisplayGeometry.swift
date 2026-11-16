import CoreGraphics

public enum DisplayGeometry {
  public static func bounds(of display: CGDirectDisplayID) -> CGRect? {
    bounds(of: display, isOnline: { CGDisplayIsOnline($0) != 0 }, readBounds: CGDisplayBounds)
  }

  static func bounds(of display: CGDirectDisplayID, isOnline: (CGDirectDisplayID) -> Bool,
    readBounds: (CGDirectDisplayID) -> CGRect) -> CGRect? {
    guard display != kCGNullDirectDisplay, isOnline(display) else { return nil }
    let frame = readBounds(display)
    guard isOnline(display), frame.origin.x.isFinite, frame.origin.y.isFinite,
      frame.size.width.isFinite, frame.size.height.isFinite,
      frame.size.width > 0, frame.size.height > 0,
      (frame.origin.x + frame.size.width).isFinite,
      (frame.origin.y + frame.size.height).isFinite else { return nil }
    return frame
  }
}

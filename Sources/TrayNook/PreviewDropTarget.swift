import Foundation

enum PreviewDropTarget {
  /// Frames use top-origin zone coordinates; item order follows reading order.
  static func insertionKey(at point: CGPoint, items: [(key: String, frame: CGRect)],
    rightToLeft: Bool = false) -> String? {
    let items = items.filter { !$0.frame.isNull && !$0.frame.isInfinite && $0.frame.width > 0 && $0.frame.height > 0 }
    var start = 0
    while start < items.count {
      var end = start + 1
      var top = items[start].frame.minY
      var bottom = items[start].frame.maxY
      while end < items.count, items[end].frame.minY < bottom, items[end].frame.maxY > top {
        top = min(top, items[end].frame.minY)
        bottom = max(bottom, items[end].frame.maxY)
        end += 1
      }
      if point.y < top { return items[start].key }
      if point.y <= bottom {
        for index in start..<end {
          let midpoint = items[index].frame.midX
          if rightToLeft ? point.x > midpoint : point.x < midpoint { return items[index].key }
        }
        return end < items.count ? items[end].key : nil
      }
      start = end
    }
    return nil
  }
}

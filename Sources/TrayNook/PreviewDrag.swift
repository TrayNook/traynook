import AppKit
import SwiftUI

@MainActor
final class PreviewDragPointer: ObservableObject {
  @Published var location = CGPoint.zero
}

/// The session outlives its source cell when a live move changes that cell's lane.
@MainActor
final class PreviewDragSession: NSObject, ObservableObject {
  @Published private(set) var key: String?
  @Published private(set) var draft: SavedLayout?
  @Published private(set) var destination: Placement?
  @Published private(set) var hoveredZone: Placement?
  let pointer = PreviewDragPointer()
  private(set) var image: NSImage?
  var screenToPreview: ((CGPoint) -> CGPoint?)?
  private var original: SavedLayout?
  private var beforeKey: String?
  private var commit: ((String, Placement, String?) -> Bool)?
  private var pointerMoved: ((CGPoint) -> Void)?
  private var eventMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var cursorPushed = false
  private var grabOffset = CGSize.zero

  func begin(_ key: String, layout: SavedLayout,
    commit: @escaping (String, Placement, String?) -> Bool) -> Bool {
    guard self.key == nil, let item = layout.items.first(where: { $0.id == key }) else { return false }
    original = layout
    draft = layout
    self.key = key
    destination = item.placement
    self.commit = commit
    return true
  }

  func move(to placement: Placement, before anchor: String?) {
    guard hoveredZone != placement || destination != placement || beforeKey != anchor else { return }
    guard let key, let next = draft?.moving(key, to: placement, before: anchor) else { return }
    if destination != placement { destination = placement }
    if hoveredZone != placement { hoveredZone = placement }
    beforeKey = anchor
    if draft != next { draft = next }
  }

  func leave(_ placement: Placement) {
    if hoveredZone == placement { hoveredZone = nil }
  }

  func drop() -> Bool {
    guard let key, let destination, let commit else { return false }
    let changed = draft != original
    let anchor = beforeKey
    cancel()
    return !changed || commit(key, destination, anchor)
  }

  func cancel() {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if cursorPushed { NSCursor.pop(); cursorPushed = false }
    guard key != nil || draft != nil else { return }
    key = nil
    draft = nil
    destination = nil
    hoveredZone = nil
    beforeKey = nil
    original = nil
    commit = nil
    image = nil
    pointerMoved = nil
  }

  func track(from down: NSEvent, event: NSEvent, image: NSImage, cell: CGRect,
    moved: @escaping (CGPoint) -> Void) -> Bool {
    guard let window = down.window,
      let start = screenToPreview?(window.convertPoint(toScreen: down.locationInWindow)) else { cancel(); return false }
    self.image = image
    grabOffset = CGSize(width: start.x - cell.midX, height: start.y - cell.midY)
    pointerMoved = moved
    NSCursor.closedHand.push()
    cursorPushed = true
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
      let consumed = MainActor.assumeIsolated {
        guard let self else { return false }
        return self.handle(event) == nil
      }
      return consumed ? nil : event
    }
    for (name, object) in [(NSApplication.didResignActiveNotification, NSApp as AnyObject),
      (NSWindow.didResignKeyNotification, window as AnyObject),
      (NSWindow.willCloseNotification, window as AnyObject)] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancel() }
      })
    }
    updatePointer(event)
    return true
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard key != nil else { return event }
    if event.type == .keyDown {
      guard event.keyCode == 53 else { return event }
      cancel()
      return nil
    }
    updatePointer(event)
    if event.type == .leftMouseUp {
      if hoveredZone != nil { _ = drop() } else { cancel() }
    }
    return nil
  }

  private func updatePointer(_ event: NSEvent) {
    let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    guard let location = screenToPreview?(screen) else { cancel(); return }
    pointer.location = CGPoint(x: location.x - grabOffset.width, y: location.y - grabOffset.height)
    pointerMoved?(location)
    (hoveredZone == nil ? NSCursor.operationNotAllowed : NSCursor.closedHand).set()
  }
}

/// Just the floating image observes every pointer update; the grid updates at slot boundaries.
struct PreviewFloatingIcon: View {
  @ObservedObject var pointer: PreviewDragPointer
  let image: NSImage

  var body: some View {
    Image(nsImage: image).resizable().frame(width: 30, height: 30)
      .padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
      .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
      .position(pointer.location)
      .transaction { $0.animation = nil }
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// A stable, flipped coordinate surface underneath the SwiftUI preview.
struct PreviewDragSurface: NSViewRepresentable {
  let session: PreviewDragSession
  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    session.screenToPreview = { [weak view] point in
      guard let view, let window = view.window else { return nil }
      return view.convert(window.convertPoint(fromScreen: point), from: nil)
    }
  }
  final class Surface: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

struct PreviewDragSource: NSViewRepresentable {
  let key: String
  let toolTip: String
  let begin: (NSEvent, NSEvent) -> Void
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ view: DragView, context: Context) {
    view.identifier = NSUserInterfaceItemIdentifier(key)
    view.toolTip = toolTip
    view.begin = begin
  }

  final class DragView: NSView {
    var begin: ((NSEvent, NSEvent) -> Void)?
    private var down: NSEvent?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = event }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
      guard let down, hypot(event.locationInWindow.x - down.locationInWindow.x,
        event.locationInWindow.y - down.locationInWindow.y) >= 3 else { return }
      self.down = nil
      begin?(down, event)
    }
  }
}

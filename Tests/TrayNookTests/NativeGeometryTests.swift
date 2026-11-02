import AppKit
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Native menu-bar geometry")
@MainActor
struct NativeGeometryTests {
  private let safeFrame = ItemFrame(x: 900, y: 0, width: 540, height: 24)
  private let boundary = ItemFrame(x: 1222, y: 0, width: 18, height: 24)
  private let launcher = ItemFrame(x: 1240, y: 0, width: 24, height: 24)

  @Test("Physical camera clipping uses display coordinates without a boundary window")
  func cameraCutoutCoordinates() {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let left = CGRect(x: 0, y: 1085, width: 772, height: 32)
    let right = CGRect(x: 956, y: 1085, width: 772, height: 32)
    #expect(NativeMenuBarController.cameraOcclusion(left: left, right: right,
      screenFrame: screen, displayBounds: screen) == ItemFrame(x: 772, y: 0, width: 184, height: 32))
    #expect(NativeMenuBarController.cameraOcclusion(left: nil, right: nil,
      screenFrame: screen, displayBounds: screen) == nil)
    #expect(NativeMenuBarController.cameraOcclusion(left: left, right: left,
      screenFrame: screen, displayBounds: screen) == nil)
    #expect(NativeMenuBarController.cameraOcclusion(
      left: CGRect(x: -1920, y: 1956, width: 800, height: 24),
      right: CGRect(x: -960, y: 1956, width: 960, height: 24),
      screenFrame: CGRect(x: -1920, y: 900, width: 1920, height: 1080),
      displayBounds: CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
      == ItemFrame(x: -1120, y: -1080, width: 160, height: 24))
  }

  @Test("Polling another row preserves concealment when its launcher exceeds the default bar height")
  func liveRowSafety() throws {
    // Captured at the false reveal: the global bar thickness was 22, but
    // the mirrored launcher filled a 24-point WindowServer status window.
    let horizontal = ItemFrame(x: -495, y: -1440, width: 2560, height: 22)
    let window = CGRect(x: 1862, y: -1440, width: 38, height: 24)
    let safe = NativeMenuBarController.menuBarSafeFrame(horizontalArea: horizontal, controlWindow: window)
    let launcher = ItemFrame(x: 1869.75, y: -1440, width: 22.5, height: 24)
    for boundary in [ItemFrame(x: 1475, y: -1439, width: 2, height: 22),
      ItemFrame(x: -1085, y: -1439, width: 2562, height: 22)] {
      #expect(NativeMenuBarController.launcherIsSafe(launcher, boundary: boundary,
        safeFrame: safe, expanded: boundary.width > 2))
    }
    #expect(safe.contains(ItemFrame(x: 1525, y: -1440, width: 26, height: 24)))

    // A notched display also has taller native windows than its auxiliary
    // area. Its horizontal cutout exclusion must remain intact.
    let notched = NativeMenuBarController.menuBarSafeFrame(
      horizontalArea: ItemFrame(x: 956, y: 0, width: 772, height: 32),
      controlWindow: CGRect(x: 1527, y: 0, width: 38, height: 37))
    #expect(notched.contains(ItemFrame(x: 1535, y: 2.5, width: 22, height: 32)))
    #expect(!notched.contains(ItemFrame(x: 940, y: 2.5, width: 22, height: 32)))
    #expect(!notched.contains(ItemFrame(x: 1535, y: 40, width: 22, height: 24)))
  }

  @Test("Live Quartz status-window frames keep the content's right edge fixed while expanding")
  func liveControlButtonFrames() throws {
    let compact = try #require(NativeMenuBarController.controlButtonFrame(
      in: CGRect(x: 1132, y: 0, width: 18, height: 37), width: 2, height: 22))
    let expanded = try #require(NativeMenuBarController.controlButtonFrame(
      in: CGRect(x: -1428, y: 0, width: 2578, height: 37), width: 2562, height: 22))
    #expect(compact == CGRect(x: 1140, y: 7.5, width: 2, height: 22))
    #expect(expanded == CGRect(x: -1420, y: 7.5, width: 2562, height: 22))
    #expect(expanded.maxX == compact.maxX)

    let launcher = try #require(NativeMenuBarController.controlButtonFrame(
      in: CGRect(x: 1527, y: 0, width: 38, height: 37), width: 22, height: 22))
    #expect(launcher == CGRect(x: 1535, y: 7.5, width: 22, height: 22))
    let mirror = try #require(NativeMenuBarController.controlButtonFrame(
      in: CGRect(x: -1093, y: -1440, width: 2578, height: 24), width: 2562, height: 32))
    #expect(mirror == CGRect(x: -1085, y: -1440, width: 2562, height: 24))
    #expect(mirror.maxX == 1477)
  }

  @Test("Requested content is unavailable until its native status window has expanded")
  func rejectsUnallocatedControlContent() {
    let compact = CGRect(x: 1132, y: 0, width: 18, height: 37)
    #expect(NativeMenuBarController.controlButtonFrame(in: compact, width: 2562, height: 22) == nil)
    for size in [CGSize(width: 0, height: 22), CGSize(width: 2, height: 0),
      CGSize(width: CGFloat.infinity, height: 22), CGSize(width: 2, height: CGFloat.nan)] {
      #expect(NativeMenuBarController.controlButtonFrame(in: compact,
        width: size.width, height: size.height) == nil)
    }
  }

  @Test("A wide control belongs to the menu row containing its right edge")
  func liveControlDisplay() {
    let rows: [(display: UInt32, frame: CGRect)] = [
      (1, CGRect(x: 0, y: 0, width: 1728, height: 37)),
      (2, CGRect(x: -1920, y: 0, width: 1920, height: 24)),
      (3, CGRect(x: 0, y: -1440, width: 2560, height: 24)),
      (4, CGRect(x: 2500, y: -900, width: 1800, height: 24)),
    ]
    // Most of this expanded window lies on display 2; its recovery edge remains on display 1.
    #expect(NativeMenuBarController.controlDisplay(
      for: CGRect(x: -1428, y: 0, width: 2578, height: 37), menuBarRows: rows) == 1)
    #expect(NativeMenuBarController.controlDisplay(
      for: CGRect(x: -1093, y: -1440, width: 2578, height: 24), menuBarRows: rows) == 3)
    #expect(NativeMenuBarController.controlDisplay(
      for: CGRect(x: 2400, y: -900, width: 250, height: 24), menuBarRows: rows) == 4)
    for unmatched in [
      CGRect(x: 1100, y: 100, width: 18, height: 24),
      CGRect(x: 3000, y: 0, width: 18, height: 24),
      CGRect(x: -100, y: 0, width: 100, height: 24), // Right edge shared by two rows.
    ] {
      #expect(NativeMenuBarController.controlDisplay(for: unmatched, menuBarRows: rows) == nil)
    }
    #expect(NativeMenuBarController.controlDisplay(
      for: CGRect(x: 1100, y: 0, width: 18, height: 24), menuBarRows: []) == nil)
  }

  @Test("An external display's control retains its own window identity and button geometry")
  func mirroredControlGeometry() throws {
    let home = NativeMenuBarController.ControlWindow(id: 10, display: 1,
      frame: CGRect(x: 1400, y: 860, width: 28, height: 40), isVisible: true)
    let button = CGRect(x: 1402, y: 868, width: 24, height: 32)
    // Display layouts can put the mirror to the left, right, or above home.
    for origin in [CGPoint(x: -60, y: 876), CGPoint(x: 2500, y: 876), CGPoint(x: 1400, y: 1776)] {
      let mirror = NativeMenuBarController.ControlWindow(id: 20, display: 2,
        frame: CGRect(origin: origin, size: CGSize(width: 28, height: 24)), isVisible: true)
      let geometry = try #require(NativeMenuBarController.controlGeometry(
        home: home, button: button, on: 2, statusWindows: [home, mirror]))
      #expect(geometry.windowID == 20)
      #expect(geometry.button == CGRect(x: origin.x + 2, y: origin.y, width: 24, height: 24))
    }
    let geometry = try #require(NativeMenuBarController.controlGeometry(
      home: home, button: button, on: 1, statusWindows: []))
    #expect(geometry.windowID == home.id)
    #expect(geometry.button == button)
  }

  @Test("Missing, invisible, wrong-display, and ambiguous control mirrors are rejected")
  func rejectsUnreliableControlMirrors() {
    let home = NativeMenuBarController.ControlWindow(id: 10, display: 1,
      frame: CGRect(x: 1400, y: 860, width: 28, height: 40), isVisible: true)
    let button = CGRect(x: 1402, y: 868, width: 24, height: 32)
    func mirror(_ id: UInt32, display: UInt32 = 2, width: Double = 28, visible: Bool = true)
      -> NativeMenuBarController.ControlWindow {
      .init(id: id, display: display,
        frame: CGRect(x: 2500, y: 876, width: width, height: 24), isVisible: visible)
    }
    for candidates in [[], [home], [mirror(20, display: 3)], [mirror(20, width: 18)],
      [mirror(20, visible: false)], [mirror(20), mirror(21)]] {
      #expect(NativeMenuBarController.controlGeometry(
        home: home, button: button, on: 2, statusWindows: candidates) == nil)
    }
  }

  @Test("A mirror is unavailable until its status window finishes expanding")
  func waitsForExpandedMirrorGeometry() throws {
    let home = NativeMenuBarController.ControlWindow(id: 10, display: 1,
      frame: CGRect(x: -1428, y: 0, width: 2578, height: 37), isVisible: true)
    let button = CGRect(x: -1420, y: 7.5, width: 2562, height: 22)
    let compact = NativeMenuBarController.ControlWindow(id: 20, display: 2,
      frame: CGRect(x: 1467, y: -1440, width: 18, height: 24), isVisible: true)
    #expect(NativeMenuBarController.controlGeometry(home: home, button: button,
      on: 2, statusWindows: [compact]) == nil)
    let expanded = NativeMenuBarController.ControlWindow(id: 20, display: 2,
      frame: CGRect(x: -1093, y: -1440, width: 2578, height: 24), isVisible: true)
    let geometry = try #require(NativeMenuBarController.controlGeometry(home: home,
      button: button, on: 2, statusWindows: [expanded]))
    #expect(geometry.windowID == 20)
    #expect(geometry.button.maxX == 1477)
  }

  @Test("A stale ranked proxy cannot activate the sibling that inherited its rank")
  func rejectsReassignedSiblingIdentity() throws {
    func siblings(_ windows: [UInt32]) -> [ClassifiedSourceItem] {
      IdentityAssessor().classify(windows.enumerated().map { index, window in
        observation(bundle: "example.pair", x: 1150 + Double(index) * 28, window: window)
      })
    }
    let original = try #require(siblings([10, 20]).first { $0.identity.persistentKey == "example.pair#w0" })
    let replacement = try #require(siblings([20, 30]).first { $0.identity.persistentKey == "example.pair#w0" })
    #expect(NativeMenuBarController.preservesSourceIdentity(original: original, current: original))
    #expect(!NativeMenuBarController.preservesSourceIdentity(original: original, current: replacement))
    // Once a new inventory is accepted, a new user action binds that inventory.
    #expect(NativeMenuBarController.preservesSourceIdentity(original: replacement, current: replacement))
    let missingWindow = ClassifiedSourceItem(
      observation: observation(bundle: "example.pair", x: 1150),
      identity: original.identity, manageability: original.manageability)
    #expect(!NativeMenuBarController.preservesSourceIdentity(original: original, current: missingWindow))
  }

  @Test("Stable AX sibling keys survive window replacement but never process replacement")
  func preservesAXSiblingIdentity() throws {
    func sibling(window: UInt32, pid: Int32) throws -> ClassifiedSourceItem {
      let items = IdentityAssessor().classify([
        observation(bundle: "example.pair", x: 1150, window: window, identifier: "primary", pid: pid),
        observation(bundle: "example.pair", x: 1180, window: window + 1, identifier: "secondary", pid: pid),
      ])
      return try #require(items.first { $0.identity.persistentKey == "example.pair#ax:primary" })
    }
    let original = try sibling(window: 10, pid: 100)
    #expect(NativeMenuBarController.preservesSourceIdentity(
      original: original, current: try sibling(window: 20, pid: 100)))
    #expect(!NativeMenuBarController.preservesSourceIdentity(
      original: original, current: try sibling(window: 20, pid: 200)))
  }

  @Test("Launcher stays completely visible to the right of the separator")
  func launcherVisibility() {
    #expect(NativeMenuBarController.launcherIsSafe(
      launcher, boundary: boundary, safeFrame: safeFrame, expanded: false))

    for unsafeLauncher in [
      ItemFrame(x: 890, y: 0, width: 24, height: 24), // Across the notch edge.
      ItemFrame(x: 1430, y: 0, width: 24, height: 24), // Across the screen edge.
      ItemFrame(x: 1220, y: 0, width: 24, height: 24), // Overlapping the separator.
      ItemFrame(x: 1240, y: 24, width: 24, height: 24), // Different menu-bar row.
      ItemFrame(x: 1240, y: 0, width: 0, height: 24),
    ] {
      #expect(!NativeMenuBarController.launcherIsSafe(
        unsafeLauncher, boundary: boundary, safeFrame: safeFrame, expanded: false))
    }
    #expect(!NativeMenuBarController.launcherIsSafe(
      launcher, boundary: ItemFrame(x: 890, y: 0, width: 18, height: 24),
      safeFrame: safeFrame, expanded: false))
  }

  @Test("A two-point invisible boundary preserves safe placement without an icon-sized gap")
  func compactInvisibleBoundary() {
    let compact = ItemFrame(x: 1238, y: 0, width: 2, height: 24)
    let hidden = observation(bundle: "example.hidden", x: 1214)
    #expect(NativeMenuBarController.launcherIsSafe(
      launcher, boundary: compact, safeFrame: safeFrame, expanded: false))
    #expect(NativeMenuBarController.hiddenSide(hidden.frame!, boundary: compact) == true)
    #expect(NativeMenuBarController.hiddenSide(launcher, boundary: compact) == false)
    #expect(NativeMenuBarController.hiddenSide(
      ItemFrame(x: 1237, y: 0, width: 4, height: 24), boundary: compact) == nil)
    let inventory = IdentityAssessor().classify([hidden])
    #expect(NativeMenuBarController.canConceal(inventory, allowedKeys: ["example.hidden"],
      boundary: compact, safeFrame: safeFrame))
    #expect(!NativeMenuBarController.canConceal(inventory, allowedKeys: [],
      boundary: compact, safeFrame: safeFrame))
  }

  @Test("Expanded separator may extend offscreen only while its recovery edge remains visible")
  func expandedRecoveryEdge() {
    let expanded = ItemFrame(x: -218, y: 0, width: 1458, height: 24)
    #expect(NativeMenuBarController.launcherIsSafe(
      launcher, boundary: expanded, safeFrame: safeFrame, expanded: true))
    #expect(!NativeMenuBarController.launcherIsSafe(
      launcher, boundary: expanded, safeFrame: safeFrame, expanded: false))
    #expect(!NativeMenuBarController.launcherIsSafe(
      launcher, boundary: ItemFrame(x: -540, y: 0, width: 1440, height: 24),
      safeFrame: safeFrame, expanded: true))
  }

  @Test("Only whole items on the same row have a known separator side")
  func sourceItemSides() {
    #expect(NativeMenuBarController.hiddenSide(
      ItemFrame(x: 1198, y: 0, width: 24, height: 24), boundary: boundary) == true)
    #expect(NativeMenuBarController.hiddenSide(launcher, boundary: boundary) == false)

    for uncertain in [
      ItemFrame(x: 1210, y: 0, width: 24, height: 24),
      ItemFrame(x: 1198, y: 24, width: 24, height: 24),
      ItemFrame(x: .nan, y: 0, width: 24, height: 24),
      ItemFrame(x: 1198, y: 0, width: 0, height: 24),
    ] {
      #expect(NativeMenuBarController.hiddenSide(uncertain, boundary: boundary) == nil)
    }
    #expect(NativeMenuBarController.hiddenSide(
      ItemFrame(x: -260, y: 0, width: 24, height: 24),
      boundary: ItemFrame(x: -218, y: 0, width: 1458, height: 24)) == true)
  }

  @Test("A fresh inventory must keep new, duplicate, system, and partly visible items safe")
  func validatesInventoryBeforeConcealing() {
    let hidden = observation(bundle: "example.hidden", x: 1198)
    let system = observation(bundle: "com.apple.controlcenter", x: 1280)
    let allowed: Set<String> = ["example.hidden", "com.apple.controlcenter"]
    let assessor = IdentityAssessor()
    #expect(NativeMenuBarController.canConceal(
      assessor.classify([hidden, system]), allowedKeys: allowed,
      boundary: boundary, safeFrame: safeFrame))
    #expect(NativeMenuBarController.canConceal(
      assessor.classify([hidden, system,
        observation(bundle: "com.apple.controlcenter", x: 1304)]),
      allowedKeys: allowed, boundary: boundary, safeFrame: safeFrame))

    for unsafeInventory in [
      [hidden, observation(bundle: "example.new", x: 1170)],
      [hidden, observation(bundle: "example.hidden", x: 1170)],
      [hidden, observation(bundle: "com.apple.controlcenter", x: 1170)],
      [observation(bundle: "example.hidden", x: 880)],
    ] {
      #expect(!NativeMenuBarController.canConceal(
        assessor.classify(unsafeInventory), allowedKeys: allowed,
        boundary: boundary, safeFrame: safeFrame))
    }
  }

  @Test("Verified visibility excludes offscreen, clipped, hidden-side, and unsafe items")
  func verifiedVisibility() {
    let display = ItemFrame(x: 0, y: 0, width: 1440, height: 900)
    func visible(_ item: RawSourceItemObservation) -> Bool {
      NativeMenuBarController.isVerifiedVisible(item, boundary: boundary, safeFrame: safeFrame, displayFrame: display)
    }
    #expect(visible(observation(bundle: "example.bar", x: 1300)))
    #expect(!visible(observation(bundle: "example.bar", x: -4096)))
    #expect(!visible(observation(bundle: "example.bar", x: 1300, isOnscreen: false)))
    #expect(!visible(observation(bundle: "example.bar", x: 1100)))
    #expect(!visible(observation(bundle: "example.bar", x: 880)))
    #expect(!visible(observation(bundle: "example.bar", x: 1230)))
  }

  @Test("A visible-side system window extending past the display edge does not block concealment")
  func visibleSystemWindowEdgeOverflow() throws {
    let display = ItemFrame(x: 0, y: 0, width: 1728, height: 1117)
    let divider = ItemFrame(x: 1126, y: 7.5, width: 2, height: 22)
    let safe = NativeMenuBarController.menuBarSafeFrame(
      horizontalArea: ItemFrame(x: 956, y: 0, width: 772, height: 32),
      controlWindow: CGRect(x: 1120, y: 0, width: 38, height: 37))
    func inventory(x: Double, y: Double = 7.5) -> [ClassifiedSourceItem] {
      IdentityAssessor().classify([RawSourceItemObservation(
        runtimeID: "769:window:30", processIdentifier: 769, bundleIdentifier: nil,
        applicationName: nil, role: "UnverifiedStatusWindow",
        frame: ItemFrame(x: x, y: y, width: 135, height: 22), actions: [],
        metadata: LiveAccessibilityMetadata(), observedOrder: 0, isOnscreen: true,
        statusWindowIdentifier: 30)])
    }
    // Captured after display-change recovery failed: Control Center extended two
    // points past the 1728-point display while remaining right of the divider.
    let systemWindow = inventory(x: 1595)
    let item = try #require(systemWindow.first)
    #expect(item.identity.persistentKey == nil)
    #expect(item.manageability.status == .protected)
    let frame = try #require(item.observation.frame)
    for boundary in [divider, ItemFrame(x: -1434, y: 7.5, width: 2562, height: 22)] {
      #expect(NativeMenuBarController.hiddenSide(frame, boundary: boundary) == false)
      #expect(NativeMenuBarController.visibleSideIsSafe(frame, safeFrame: safe))
      #expect(!NativeMenuBarController.isVerifiedVisible(item.observation,
        boundary: boundary, safeFrame: safe, displayFrame: display))
    }
    #expect(NativeMenuBarController.canConceal(systemWindow, allowedKeys: [],
      boundary: divider, safeFrame: safe, displayFrame: display))
    for unsafe in [inventory(x: -2), inventory(x: 1595, y: 40), inventory(x: 1100)] {
      #expect(!NativeMenuBarController.canConceal(unsafe, allowedKeys: [],
        boundary: divider, safeFrame: safe, displayFrame: display))
    }
  }

  @Test("Visible-side safety retains valid leading-edge and full-row geometry")
  func visibleSideSafetyGuards() {
    for frame in [
      ItemFrame(x: 1300, y: 0, width: 0, height: 24),
      ItemFrame(x: .nan, y: 0, width: 24, height: 24),
      ItemFrame(x: 1300, y: 0, width: .infinity, height: 24),
      ItemFrame(x: 1300, y: -1, width: 24, height: 24),
      ItemFrame(x: 1300, y: 1, width: 24, height: 24),
      ItemFrame(x: 899, y: 0, width: 24, height: 24),
      ItemFrame(x: 1440, y: 0, width: 24, height: 24),
    ] {
      #expect(!NativeMenuBarController.visibleSideIsSafe(frame, safeFrame: safeFrame))
    }
  }

  @Test("Each hidden sibling needs its own assignment")
  func siblingsNeedIndividualAssignments() {
    let assessor = IdentityAssessor()
    let siblings = assessor.classify([
      observation(bundle: "example.pair", x: 1150, window: 10),
      observation(bundle: "example.pair", x: 1180, window: 11),
    ])
    #expect(siblings.compactMap(\.identity.persistentKey) == ["example.pair#w0", "example.pair#w1"])
    #expect(NativeMenuBarController.canConceal(siblings,
      allowedKeys: ["example.pair#w0", "example.pair#w1"], boundary: boundary, safeFrame: safeFrame))
    #expect(!NativeMenuBarController.canConceal(siblings,
      allowedKeys: ["example.pair#w1"], boundary: boundary, safeFrame: safeFrame))
    #expect(!NativeMenuBarController.canConceal(siblings,
      allowedKeys: ["example.pair"], boundary: boundary, safeFrame: safeFrame))
  }

  @Test("Already offscreen sources do not block concealment, but visible unsafe geometry does")
  func distinguishesOffscreenSources() {
    let display = ItemFrame(x: 0, y: 0, width: 1440, height: 900)
    let hidden = observation(bundle: "example.hidden", x: 1198)
    let assessor = IdentityAssessor()
    #expect(NativeMenuBarController.canConceal(
      assessor.classify([hidden, observation(bundle: "example.unassigned", x: -4096)]),
      allowedKeys: ["example.hidden"], boundary: boundary,
      safeFrame: safeFrame, displayFrame: display))

    for unsafeX in [-12.0, 880, Double.nan] {
      #expect(!NativeMenuBarController.canConceal(
        assessor.classify([hidden, observation(bundle: "example.unassigned", x: unsafeX)]),
        allowedKeys: ["example.hidden"], boundary: boundary,
        safeFrame: safeFrame, displayFrame: display))
    }
    #expect(NativeMenuBarController.outsideDisplay(
      ItemFrame(x: -24, y: 0, width: 24, height: 24), display: display))
    #expect(!NativeMenuBarController.outsideDisplay(
      ItemFrame(x: -24, y: 0, width: 0, height: 24), display: display))
  }

  @Test("Only confirmed offscreen items on this display's menu row count as already clipped")
  func validatesClippedVisibility() {
    let display = ItemFrame(x: 0, y: 0, width: 1440, height: 900)
    let assessor = IdentityAssessor()
    let hidden = observation(bundle: "example.hidden", x: 1198)
    for visibility: Bool? in [false, true, nil] {
      let clipped = observation(bundle: "example.clipped", x: 880, isOnscreen: visibility)
      #expect(NativeMenuBarController.isClipped(
        clipped, boundary: boundary, displayFrame: display) == (visibility == false))
      #expect(NativeMenuBarController.canConceal(
        assessor.classify([hidden, clipped]), allowedKeys: ["example.hidden"],
        boundary: boundary, safeFrame: safeFrame, displayFrame: display) == (visibility == false))
    }
    let wrongRow = observation(bundle: "example.clipped", x: 880, y: 24, isOnscreen: false)
    #expect(!NativeMenuBarController.isClipped(wrongRow, boundary: boundary, displayFrame: display))
    #expect(!NativeMenuBarController.canConceal(
      assessor.classify([hidden, wrongRow]), allowedKeys: ["example.hidden"],
      boundary: boundary, safeFrame: safeFrame, displayFrame: display))
    #expect(!NativeMenuBarController.isClipped(
      observation(bundle: "example.clipped", x: 3000, isOnscreen: false),
      boundary: boundary, displayFrame: display))
  }

  @Test("A whole source under this display's notch is occluded even when WindowServer says onscreen")
  func recognizesPhysicalNotchOcclusion() {
    let display = ItemFrame(x: 0, y: 0, width: 1440, height: 900)
    let cutout = ItemFrame(x: 780, y: 0, width: 120, height: 32)
    for visibility: Bool? in [true, nil] {
      let covered = observation(bundle: "example.covered", x: 840, isOnscreen: visibility)
      #expect(NativeMenuBarController.isClipped(covered, boundary: boundary,
        displayFrame: display, occlusionFrame: cutout))
      #expect(NativeMenuBarController.canConceal(
        IdentityAssessor().classify([covered]), allowedKeys: ["example.covered"],
        boundary: boundary, safeFrame: safeFrame, displayFrame: display, occlusionFrame: cutout))
      #expect(!NativeMenuBarController.isClipped(covered, boundary: boundary, displayFrame: display))
    }

    for uncovered in [
      observation(bundle: "example.touchingLeft", x: 756, isOnscreen: true),
      observation(bundle: "example.touchingRight", x: 900, isOnscreen: true),
      observation(bundle: "example.farLeft", x: 300, isOnscreen: true),
      observation(bundle: "example.wrongRow", x: 840, y: 32, isOnscreen: true),
      observation(bundle: "example.otherDisplay", x: 2280, isOnscreen: true),
    ] {
      #expect(!NativeMenuBarController.isClipped(uncovered, boundary: boundary,
        displayFrame: display, occlusionFrame: cutout))
    }
    let otherDisplay = ItemFrame(x: 1440, y: 0, width: 1440, height: 900)
    #expect(!NativeMenuBarController.isClipped(
      observation(bundle: "example.covered", x: 840, isOnscreen: true), boundary: boundary,
      displayFrame: otherDisplay, occlusionFrame: cutout))
  }

  @Test("A partially notch-covered source uses AX, but concealment still requires a safe assignment")
  func validatesPartiallyOccludedSources() {
    let display = ItemFrame(x: 0, y: 0, width: 1728, height: 1117)
    let cutout = ItemFrame(x: 772, y: 0, width: 184, height: 32)
    let safe = ItemFrame(x: 956, y: -1, width: 772, height: 34)
    let divider = ItemFrame(x: 1122, y: 6.5, width: 20, height: 24)
    let assessor = IdentityAssessor()
    let bundle = "example.partial"
    for visibility: Bool? in [true, nil] {
      let partial = observation(bundle: bundle, x: 936, y: 6.5, width: 38, isOnscreen: visibility)
      #expect(NativeMenuBarController.isClipped(partial, boundary: divider,
        displayFrame: display, occlusionFrame: cutout))
      #expect(NativeMenuBarController.canConceal(assessor.classify([partial]),
        allowedKeys: [bundle], boundary: divider, safeFrame: safe,
        displayFrame: display, occlusionFrame: cutout))
      #expect(!NativeMenuBarController.canConceal(assessor.classify([partial]),
        allowedKeys: [], boundary: divider, safeFrame: safe,
        displayFrame: display, occlusionFrame: cutout))
      #expect(!NativeMenuBarController.canConceal(
        assessor.classify([partial, observation(bundle: bundle, x: 1050)]),
        allowedKeys: [bundle], boundary: divider, safeFrame: safe,
        displayFrame: display, occlusionFrame: cutout))
      #expect(!NativeMenuBarController.canConceal(assessor.classify([partial]),
        allowedKeys: [bundle],
        boundary: ItemFrame(x: 960, y: 6.5, width: 20, height: 24), safeFrame: safe,
        displayFrame: display, occlusionFrame: cutout))
    }
    for protected in [
      observation(bundle: "com.apple.protected", x: 936, y: 6.5, width: 38, isOnscreen: true),
      observation(bundle: bundle, x: 936, y: 6.5, width: 38,
        role: "UnverifiedStatusWindow", isOnscreen: true),
    ] {
      #expect(!NativeMenuBarController.canConceal(assessor.classify([protected]),
        allowedKeys: [bundle, "com.apple.protected"], boundary: divider,
        safeFrame: safe, displayFrame: display, occlusionFrame: cutout))
    }
  }

  private func observation(bundle: String, x: Double, y: Double = 0, width: Double = 24,
    role: String = "AXMenuBarItem",
    isOnscreen: Bool? = nil, window: UInt32? = nil, identifier: String? = nil,
    pid: Int32 = 100) -> RawSourceItemObservation {
    RawSourceItemObservation(
      runtimeID: "fixture:\(x)", processIdentifier: pid, bundleIdentifier: bundle,
      applicationName: "Fixture", role: role,
      frame: ItemFrame(x: x, y: y, width: width, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(identifierCandidate: identifier), observedOrder: 0, isOnscreen: isOnscreen,
      statusWindowIdentifier: window)
  }
}

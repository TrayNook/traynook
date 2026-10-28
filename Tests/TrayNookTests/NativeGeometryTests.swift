import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Native menu-bar geometry")
@MainActor
struct NativeGeometryTests {
  private let safeFrame = ItemFrame(x: 900, y: 0, width: 540, height: 24)
  private let boundary = ItemFrame(x: 1222, y: 0, width: 18, height: 24)
  private let launcher = ItemFrame(x: 1240, y: 0, width: 24, height: 24)

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
    isOnscreen: Bool? = nil, window: UInt32? = nil) -> RawSourceItemObservation {
    RawSourceItemObservation(
      runtimeID: "fixture:\(x)", processIdentifier: 100, bundleIdentifier: bundle,
      applicationName: "Fixture", role: role,
      frame: ItemFrame(x: x, y: y, width: width, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 0, isOnscreen: isOnscreen,
      statusWindowIdentifier: window)
  }
}

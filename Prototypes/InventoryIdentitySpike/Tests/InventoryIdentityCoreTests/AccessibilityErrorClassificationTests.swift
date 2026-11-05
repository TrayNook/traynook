import ApplicationServices
import Foundation
import Testing

@testable import InventoryIdentityCore

@Suite("Accessibility scan error classification")
struct AccessibilityErrorClassificationTests {
  @Test("Every timeout-configuration failure invalidates the snapshot")
  func configurationFailuresAreStrict() {
    let failures: [AXError] = [
      .failure,
      .illegalArgument,
      .invalidUIElement,
      .invalidUIElementObserver,
      .cannotComplete,
      .attributeUnsupported,
      .actionUnsupported,
      .notificationUnsupported,
      .notImplemented,
      .notificationAlreadyRegistered,
      .notificationNotRegistered,
      .apiDisabled,
      .noValue,
      .parameterizedAttributeUnsupported,
      .notEnoughPrecision,
    ]

    #expect(
      failures.allSatisfy {
        accessibilityErrorRequiresIncompleteSnapshot(
          $0,
          for: .timeoutConfiguration
        )
      }
    )
    #expect(
      !accessibilityErrorRequiresIncompleteSnapshot(
        .success,
        for: .timeoutConfiguration
      )
    )
  }

  @Test("Ordinary unsupported attributes remain valid absences")
  func unsupportedAttributesAreNotTransientFailures() {
    #expect(
      !accessibilityErrorRequiresIncompleteSnapshot(
        .attributeUnsupported,
        for: .message
      )
    )
    #expect(
      accessibilityErrorRequiresIncompleteSnapshot(
        .cannotComplete,
        for: .message
      )
    )
  }

  @Test("A fatal message stops the current application scan")
  func fatalMessageStopsCurrentApplication() {
    let tracker = AccessibilityScanIssueTracker()
    tracker.beginApplication(100)

    tracker.record(.attributeUnsupported)
    #expect(tracker.currentApplicationIsComplete)

    tracker.record(.cannotComplete)
    #expect(!tracker.currentApplicationIsComplete)
    #expect(tracker.incompleteApplicationCount == 1)
    #expect(tracker.cannotCompleteApplicationCount == 1)

    tracker.finishApplication(durationMilliseconds: 10)
    tracker.beginApplication(200)
    #expect(tracker.currentApplicationIsComplete)
  }

  @Test("Descendant traversal cannot exceed its fixed budget")
  func traversalBudgetIsBounded() {
    let limit = AccessibilityInventoryTuning.maximumDescendantCount

    #expect(
      accessibilityTraversalCanAppend(
        currentCount: limit - 1,
        additionalCount: 1
      )
    )
    #expect(
      !accessibilityTraversalCanAppend(
        currentCount: limit,
        additionalCount: 1
      )
    )
    #expect(
      !accessibilityTraversalCanAppend(
        currentCount: limit - 1,
        additionalCount: 2
      )
    )
  }

  @Test("Inventory stops at status icons without inspecting their popup menus")
  func statusIconsAreTraversalLeaves() {
    #expect(!accessibilityTraversalVisitsChildren(role: kAXMenuBarItemRole as String))
    #expect(accessibilityTraversalVisitsChildren(role: kAXMenuBarRole as String))
    #expect(accessibilityTraversalVisitsChildren(role: "AXGroup"))
    #expect(accessibilityTraversalVisitsChildren(role: nil))
  }

  @Test("The whole-scan deadline stops further messages and invalidates partial inventory")
  func scanDeadlineStopsWork() {
    var now: UInt64 = 0
    let tracker = AccessibilityScanIssueTracker(deadline: 2_000_000_000, uptimeNanoseconds: { now })
    tracker.beginApplication(100)
    now = 1_999_999_999
    #expect(tracker.currentApplicationIsComplete)
    #expect(tracker.snapshotIsComplete)

    now = 2_000_000_000
    #expect(tracker.scanBudgetExceeded)
    #expect(!tracker.currentApplicationIsComplete)
    #expect(!tracker.snapshotIsComplete)
    #expect(tracker.incompleteApplicationCount == 1)
    #expect(tracker.cannotCompleteApplicationCount == 0)
  }

  @Test("A deadline between applications cannot label a partial scan complete")
  func scanDeadlineBetweenApplications() {
    var now: UInt64 = 0
    let tracker = AccessibilityScanIssueTracker(deadline: 2_000_000_000, uptimeNanoseconds: { now })
    tracker.beginApplication(100)
    tracker.finishApplication(durationMilliseconds: 10)
    #expect(tracker.snapshotIsComplete)

    now = 2_000_000_000
    #expect(!tracker.snapshotIsComplete)
    #expect(tracker.incompleteApplicationCount == 0)
  }

  @Test("Inventory selects status-window owners including offscreen items, never unrelated apps")
  func selectsStatusWindowOwners() {
    let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    let windows: [[String: Any]] = [
      windowMetadata(owner: 100, identifier: 1, onscreen: false),
      windowMetadata(owner: 100, identifier: 2),
      windowMetadata(owner: 200, identifier: 3),
      [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 300],
    ]
    let statusWindows = statusWindowObservations(in: windows)
    #expect(Set(statusWindows?.map(\.processIdentifier) ?? []) == [100, 200])
    #expect(Set(statusWindows?.map(\.windowIdentifier) ?? []) == [1, 2, 3])
    #expect(statusWindowObservations(in: nil) == nil)
    #expect(statusWindowObservations(in: [[kCGWindowLayer as String: statusLevel]]) == nil)
    #expect(statusWindowObservations(in: []) == [])
  }

  @Test("Panel-only owners cannot poison discovery; real and concealed items on every display remain candidates")
  func excludesConclusivePanelOwners() throws {
    let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let external = CGRect(x: -495, y: -1440, width: 2560, height: 1440)
    let own = ProcessInfo.processInfo.processIdentifier
    func window(_ owner: Int32, _ id: Int, _ frame: CGRect, visible: Bool = true) -> [String: Any] {
      var result = windowMetadata(owner: Int(owner), identifier: id, onscreen: visible)
      result[kCGWindowBounds as String] = frame.dictionaryRepresentation
      return result
    }
    let metadata = [
      window(own, 10, CGRect(x: 1500, y: 0, width: 24, height: 37)),
      window(own, 11, CGRect(x: 1800, y: -1440, width: 24, height: 24)),
      window(own, 12, CGRect(x: 1000, y: 0, width: 300, height: 200)),
      window(100, 1, CGRect(x: 1300, y: 0, width: 24, height: 37)),
      window(200, 2, CGRect(x: 0, y: 0, width: 1728, height: 1000)),
      window(300, 3, CGRect(x: 400, y: 400, width: 400, height: 200)),
      window(100, 4, CGRect(x: 0, y: 0, width: 1728, height: 1000)),
      window(400, 5, CGRect(x: -2000, y: 0, width: 24, height: 37), visible: false),
      window(500, 6, CGRect(x: 1200, y: -1440, width: 24, height: 24)),
    ]
    let windows = try #require(statusWindowObservations(in: metadata))
    let candidates = statusWindowSourceCandidates(in: windows, windowMetadata: metadata,
      displays: [main, external, external], ownProcessIdentifier: own)
    #expect(candidates.map(\.windowIdentifier) == [1, 5, 6])
    #expect(Set(candidates.map(\.processIdentifier)) == [100, 400, 500])
    #expect(unrepresentedStatusWindows(candidates, comparedTo: []).map(\.windowIdentifier) == [1, 6])
  }

  @Test("Unknown display rows retain possible sources instead of guessing their height")
  func unknownMenuRowsRemainCandidates() throws {
    let own = ProcessInfo.processInfo.processIdentifier
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    var panel = windowMetadata(owner: 200, identifier: 2)
    panel[kCGWindowBounds as String] = CGRect(x: 400, y: 400, width: 400, height: 200).dictionaryRepresentation
    var ownPopover = windowMetadata(owner: Int(own), identifier: 3)
    ownPopover[kCGWindowBounds as String] = CGRect(x: 1000, y: 37, width: 300, height: 200).dictionaryRepresentation
    let metadata = [windowMetadata(owner: 100, identifier: 1), panel, ownPopover]
    let windows = try #require(statusWindowObservations(in: metadata))
    #expect(statusWindowSourceCandidates(in: windows, windowMetadata: metadata,
      displays: [display], ownProcessIdentifier: own) == windows)
    #expect(statusWindowSourceCandidates(in: windows, windowMetadata: metadata,
      displays: [], ownProcessIdentifier: own) == windows)
    var malformedOwnWindow = ownPopover
    malformedOwnWindow[kCGWindowBounds as String] = CGRect(x: Double.nan, y: 0, width: 24, height: 37).dictionaryRepresentation
    #expect(statusWindowSourceCandidates(in: windows, windowMetadata: metadata + [malformedOwnWindow],
      displays: [display], ownProcessIdentifier: own) == windows)
  }

  @Test("Concealment baselines ignore unrelated panels but retain genuine source changes")
  func panelsDoNotInvalidateConcealmentBaseline() throws {
    let own = Int(ProcessInfo.processInfo.processIdentifier)
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    func metadata(panel: CGRect? = nil, sourceX: CGFloat = 1300) -> [[String: Any]] {
      var control = windowMetadata(owner: own, identifier: 10)
      control[kCGWindowBounds as String] = CGRect(x: 1500, y: 0, width: 24, height: 37).dictionaryRepresentation
      var source = windowMetadata(owner: 100, identifier: 1)
      source[kCGWindowBounds as String] = CGRect(x: sourceX, y: 0, width: 24, height: 37).dictionaryRepresentation
      var result = [control, source]
      if let panel {
        var preview = windowMetadata(owner: 100, identifier: 2)
        preview[kCGWindowBounds as String] = panel.dictionaryRepresentation
        result.append(preview)
      }
      return result
    }
    func inventory(_ metadata: [[String: Any]], displays: [CGRect] = [display]) throws -> StatusWindowInventory {
      StatusWindowInventory(windows: try #require(statusWindowObservations(in: metadata)),
        metadata: metadata, displays: displays)
    }
    let baseline = try inventory(metadata()).concealmentStates
    for panel in [CGRect(x: 24, y: 19, width: 1680, height: 1079),
      CGRect(x: 400, y: 400, width: 400, height: 200)] {
      let changed = try inventory(metadata(panel: panel))
      #expect(changed.windows.count == 2, "Raw windows remain available for diagnostics.")
      #expect(changed.concealmentStates == baseline)
      #expect(try inventory(metadata(panel: panel), displays: []).concealmentStates.count == 2,
        "Unknown rows must retain possible sources.")
    }
    #expect(try inventory(metadata(sourceX: 1320)).concealmentStates != baseline)
  }

  @Test("Unexposed visible status windows are Protected; offscreen identities remain trackable")
  func unexposedStatusWindowsAreProtected() throws {
    let windows = try #require(statusWindowObservations(in: [
      windowMetadata(owner: 100, identifier: 1),
      windowMetadata(owner: 200, identifier: 2, x: 1050),
      windowMetadata(owner: 300, identifier: 3, onscreen: false),
    ]))
    let known = RawSourceItemObservation(
      runtimeID: "100:0", processIdentifier: 100, bundleIdentifier: "example.known",
      applicationName: "Known", role: "AXMenuBarItem",
      frame: ItemFrame(x: 1000, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 0)
    let fallback = try #require(unrepresentedStatusWindows(windows, comparedTo: [known]).first)
    #expect(unrepresentedStatusWindows(windows, comparedTo: [known]).count == 1)
    #expect(fallback.windowIdentifier == 2)
    #expect(fallback.frame == ItemFrame(x: 1050, y: 0, width: 24, height: 24))
    #expect(Set(windows.map(\.windowIdentifier)).contains(3))

    let raw = RawSourceItemObservation(
      runtimeID: "200:window:2", processIdentifier: 200, bundleIdentifier: "example.unexposed",
      applicationName: "Unexposed", role: "UnverifiedStatusWindow", frame: fallback.frame,
      actions: [], metadata: LiveAccessibilityMetadata(), observedOrder: 1)
    #expect(IdentityAssessor().classify([raw]).first?.manageability.status == .protected)
  }

  @Test("Status windows on another display's menu bar are not unexposed sources")
  func ignoresOtherDisplayStatusWindows() throws {
    var secondDisplay = windowMetadata(owner: 200, identifier: 2, x: 1300)
    secondDisplay[kCGWindowBounds as String] = CGRect(x: 1300, y: -1440, width: 24, height: 24).dictionaryRepresentation
    let windows = try #require(statusWindowObservations(in: [
      windowMetadata(owner: 100, identifier: 1), secondDisplay,
    ]))
    let known = RawSourceItemObservation(
      runtimeID: "100:0", processIdentifier: 100, bundleIdentifier: "example.known",
      applicationName: "Known", role: "AXMenuBarItem",
      frame: ItemFrame(x: 1000, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 0)
    #expect(unrepresentedStatusWindows(windows, comparedTo: [known]).isEmpty)
    #expect(unrepresentedStatusWindows(windows, comparedTo: []).map(\.windowIdentifier) == [1, 2])

    // A display-sized status-level panel of a known app is not an unexposed item.
    var panel = windowMetadata(owner: 100, identifier: 5)
    panel[kCGWindowBounds as String] = CGRect(x: 0, y: 0, width: 1700, height: 1000).dictionaryRepresentation
    let withPanel = try #require(statusWindowObservations(in: [windowMetadata(owner: 100, identifier: 1), panel]))
    #expect(unrepresentedStatusWindows(withPanel, comparedTo: [known]).isEmpty)
  }

  @Test("Opening our own status-level popover cannot change source owners, fallbacks, or runtime IDs")
  func excludesOwnPopoverFromInventory() throws {
    let ownOwner = Int(ProcessInfo.processInfo.processIdentifier)
    let sourceOwner = ownOwner == 100 ? 200 : 100
    let baseline = [
      windowMetadata(owner: sourceOwner, identifier: 1),
      windowMetadata(owner: ownOwner, identifier: 2),
    ]
    var popover = windowMetadata(owner: ownOwner, identifier: 3)
    popover[kCGWindowBounds as String] = CGRect(x: 1000, y: 24, width: 300, height: 200).dictionaryRepresentation
    let before = try #require(statusWindowObservations(in: baseline))
    let after = try #require(statusWindowObservations(in: baseline + [popover]))
    #expect(before == after)
    #expect(Set(after.map(\.processIdentifier)) == [Int32(sourceOwner)])
    #expect(Set(after.map(\.windowIdentifier)) == [1])
    #expect(unrepresentedStatusWindows(after, comparedTo: []).map(\.windowIdentifier) == [1])
  }

  @Test("Malformed status metadata cannot silently erase a source window")
  func rejectsMalformedStatusMetadata() throws {
    let valid = windowMetadata(owner: 100, identifier: 1)
    let invalidValues: [(String, Any)] = [
      (kCGWindowIsOnscreen as String, "true"),
      (kCGWindowIsOnscreen as String, 1),
      (kCGWindowOwnerPID as String, 0),
      (kCGWindowNumber as String, 0),
      (kCGWindowBounds as String, CGRect.zero.dictionaryRepresentation),
      (kCGWindowBounds as String, CGRect(x: Double.infinity, y: 0, width: 24, height: 24).dictionaryRepresentation),
    ]
    for (key, value) in invalidValues {
      var malformed = valid
      malformed[key] = value
      #expect(statusWindowObservations(in: [malformed]) == nil)
    }
    var offscreen = valid
    offscreen.removeValue(forKey: kCGWindowIsOnscreen as String)
    #expect(try #require(statusWindowObservations(in: [offscreen])?.first).isOnscreen == false)
  }

  @Test("Empty offscreen DockDoor windows do not invalidate the menu-bar inventory")
  func ignoresEmptyOffscreenWindows() throws {
    let baseline = [windowMetadata(owner: 100, identifier: 1)]
    let before = try #require(statusWindowObservations(in: baseline))
    for size in [CGSize.zero, CGSize(width: 0, height: 24), CGSize(width: 24, height: 0)] {
      for visibility in [false as Bool?, nil] {
        var placeholder = windowMetadata(owner: 200, identifier: 2, onscreen: false)
        placeholder[kCGWindowBounds as String] = CGRect(origin: CGPoint(x: 0, y: 1117), size: size).dictionaryRepresentation
        placeholder[kCGWindowIsOnscreen as String] = visibility
        let after = try #require(statusWindowObservations(in: baseline + [placeholder]))
        #expect(after == before)
        #expect(Set(after.map(\.windowIdentifier)) == [1])
        #expect(unrepresentedStatusWindows(after, comparedTo: []).map(\.windowIdentifier) == [1])
        placeholder[kCGWindowIsOnscreen as String] = true
        #expect(statusWindowObservations(in: baseline + [placeholder]) == nil)
      }
    }
  }

  @Test("Empty offscreen windows still require valid ownership, visibility, and finite nonnegative bounds")
  func rejectsMalformedOffscreenWindows() {
    var placeholder = windowMetadata(owner: 200, identifier: 2, onscreen: false)
    placeholder[kCGWindowBounds as String] = CGRect(x: 0, y: 1117, width: 0, height: 0).dictionaryRepresentation
    let invalidValues: [(String, Any)] = [
      (kCGWindowOwnerPID as String, 0),
      (kCGWindowNumber as String, 0),
      (kCGWindowIsOnscreen as String, "false"),
      (kCGWindowBounds as String, ["X": 0]),
      (kCGWindowBounds as String, CGRect(x: Double.infinity, y: 1117, width: 0, height: 0).dictionaryRepresentation),
      (kCGWindowBounds as String, CGRect(x: 0, y: 1117, width: -1, height: 0).dictionaryRepresentation),
      (kCGWindowBounds as String, CGRect(x: 0, y: 1117, width: 0, height: -1).dictionaryRepresentation),
    ]
    for (key, value) in invalidValues {
      var malformed = placeholder
      malformed[key] = value
      #expect(statusWindowObservations(in: [malformed]) == nil)
    }
  }

  @Test("Visible-looking AX geometry inherits visibility only from overlapping windows of its owner")
  func distinguishesOffscreenAXGeometry() throws {
    let item = RawSourceItemObservation(
      runtimeID: "100:0", processIdentifier: 100, bundleIdentifier: "example.source",
      applicationName: "Source", role: "AXMenuBarItem",
      frame: ItemFrame(x: 1000, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(), observedOrder: 0)
    var panel = windowMetadata(owner: 100, identifier: 5) // Same app, display-sized status-level panel.
    panel[kCGWindowBounds as String] = CGRect(x: 0, y: 0, width: 1700, height: 1000).dictionaryRepresentation
    let unrelated = [
      windowMetadata(owner: 200, identifier: 2), // Same position, different app.
      windowMetadata(owner: 100, identifier: 3, x: 3000), // Same app, another display.
      panel,
    ]
    let offscreen = try #require(statusWindowObservations(in:
      [windowMetadata(owner: 100, identifier: 1, onscreen: false)] + unrelated))
    #expect(statusWindowVisibility(of: item, in: offscreen) == false)
    let visible = try #require(statusWindowObservations(in:
      [windowMetadata(owner: 100, identifier: 4)]))
    #expect(statusWindowVisibility(of: item, in: offscreen + visible) == true)
    #expect(statusWindowVisibility(of: item,
      in: try #require(statusWindowObservations(in: unrelated))) == nil)
  }

  @Test("Legacy observations decode with unknown runtime visibility")
  func legacyVisibilityIsUnknown() throws {
    let legacy = Data(#"{"runtimeID":"100:0","processIdentifier":100,"role":"AXMenuBarItem","actions":[],"metadata":{},"observedOrder":0}"#.utf8)
    let observation = try JSONDecoder().decode(RawSourceItemObservation.self, from: legacy)
    #expect(observation.isOnscreen == nil)
  }

  private func windowMetadata(owner: Int, identifier: Int, x: Double = 1000, onscreen: Bool = true) -> [String: Any] {
    [kCGWindowLayer as String: Int(CGWindowLevelForKey(.statusWindow)),
     kCGWindowOwnerPID as String: owner, kCGWindowNumber as String: identifier,
     kCGWindowIsOnscreen as String: onscreen,
     kCGWindowBounds as String: CGRect(x: x, y: -1, width: 24, height: 42).dictionaryRepresentation]
  }
}

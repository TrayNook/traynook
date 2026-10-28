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

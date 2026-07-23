import ApplicationServices
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
}

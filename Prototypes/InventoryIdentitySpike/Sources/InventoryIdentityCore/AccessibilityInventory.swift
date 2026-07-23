import AppKit
import ApplicationServices
import Foundation

public enum AccessibilityInventoryTuning {
  /// Public Accessibility messaging is synchronous. A bounded timeout prevents
  /// one unresponsive process from stalling the complete inventory loop.
  public static let defaultMessagingTimeoutSeconds = 0.2
  public static let minimumMessagingTimeoutSeconds = 0.01
  public static let maximumMessagingTimeoutSeconds = 2.0
  public static let maximumDescendantCount = 512
}

enum AccessibilityScanOperation: Equatable {
  case message
  case timeoutConfiguration
}

func accessibilityErrorRequiresIncompleteSnapshot(
  _ error: AXError,
  for operation: AccessibilityScanOperation
) -> Bool {
  if operation == .timeoutConfiguration {
    return error != .success
  }

  switch error {
  case .success, .attributeUnsupported, .actionUnsupported,
    .notificationUnsupported, .notImplemented, .noValue,
    .parameterizedAttributeUnsupported:
    return false
  default:
    return true
  }
}

func accessibilityTraversalCanAppend(
  currentCount: Int,
  additionalCount: Int
) -> Bool {
  guard currentCount >= 0, additionalCount >= 0 else {
    return false
  }
  return additionalCount
    <= AccessibilityInventoryTuning.maximumDescendantCount - currentCount
}

final class AccessibilityScanIssueTracker {
  private var currentProcessIdentifier: Int32?
  private var incompleteProcessIdentifiers = Set<Int32>()
  private var cannotCompleteProcessIdentifiers = Set<Int32>()

  private(set) var maximumApplicationScanMilliseconds = 0.0

  var incompleteApplicationCount: Int {
    incompleteProcessIdentifiers.count
  }

  var cannotCompleteApplicationCount: Int {
    cannotCompleteProcessIdentifiers.count
  }

  var currentApplicationIsComplete: Bool {
    guard let currentProcessIdentifier else {
      return false
    }
    return !incompleteProcessIdentifiers.contains(
      currentProcessIdentifier
    )
  }

  func beginApplication(_ processIdentifier: Int32) {
    currentProcessIdentifier = processIdentifier
  }

  func finishApplication(durationMilliseconds: Double) {
    maximumApplicationScanMilliseconds = max(
      maximumApplicationScanMilliseconds,
      durationMilliseconds
    )
    currentProcessIdentifier = nil
  }

  func record(
    _ error: AXError,
    operation: AccessibilityScanOperation = .message
  ) {
    guard
      accessibilityErrorRequiresIncompleteSnapshot(
        error,
        for: operation
      ),
      let currentProcessIdentifier
    else {
      return
    }

    incompleteProcessIdentifiers.insert(currentProcessIdentifier)
    if error == .cannotComplete {
      cannotCompleteProcessIdentifiers.insert(currentProcessIdentifier)
    }
  }

  func markCurrentApplicationIncomplete() {
    guard let currentProcessIdentifier else {
      return
    }
    incompleteProcessIdentifiers.insert(currentProcessIdentifier)
  }
}

public protocol InventoryScanning: Sendable {
  func scan(promptForPermission: Bool) -> InventorySnapshot
}

public struct AccessibilityInventoryScanner: InventoryScanning, Sendable {
  private let assessor: IdentityAssessor
  private let messagingTimeoutSeconds: Double

  public init(
    assessor: IdentityAssessor = IdentityAssessor(),
    messagingTimeoutSeconds: Double =
      AccessibilityInventoryTuning.defaultMessagingTimeoutSeconds
  ) {
    precondition(
      messagingTimeoutSeconds
        >= AccessibilityInventoryTuning.minimumMessagingTimeoutSeconds
        && messagingTimeoutSeconds
          <= AccessibilityInventoryTuning.maximumMessagingTimeoutSeconds
    )
    self.assessor = assessor
    self.messagingTimeoutSeconds = messagingTimeoutSeconds
  }

  public func scan(promptForPermission: Bool = false) -> InventorySnapshot {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let trusted = accessibilityIsTrusted(prompt: promptForPermission)
    let capturedAt = Date()

    guard trusted else {
      return InventorySnapshot(
        capturedAt: capturedAt,
        permission: .denied,
        completeness: .incomplete,
        items: [],
        warnings: [
          "Accessibility is not granted. No Source Items were inspected."
        ],
        metrics: ScanMetrics(
          durationMilliseconds: elapsedMilliseconds(since: startedAt),
          inspectedApplicationCount: 0,
          sourceItemCount: 0,
          messagingTimeoutMilliseconds:
            messagingTimeoutSeconds * 1_000
        )
      )
    }

    let applications = NSWorkspace.shared.runningApplications
      .filter { $0.processIdentifier > 0 }
      .sorted { $0.processIdentifier < $1.processIdentifier }
    var rawItems: [RawSourceItemObservation] = []
    var warnings: [String] = []
    let issueTracker = AccessibilityScanIssueTracker()

    for application in applications {
      let applicationStartedAt = DispatchTime.now().uptimeNanoseconds
      issueTracker.beginApplication(application.processIdentifier)
      let result = observations(
        for: application,
        issueTracker: issueTracker
      )
      issueTracker.finishApplication(
        durationMilliseconds: elapsedMilliseconds(
          since: applicationStartedAt
        )
      )
      rawItems.append(contentsOf: result.items)
      if let warning = result.warning {
        warnings.append(warning)
      }
    }

    if issueTracker.incompleteApplicationCount > 0 {
      warnings.append(
        "\(issueTracker.incompleteApplicationCount) applications could not be "
          + "scanned completely; this snapshot must not drive changes."
      )
    }

    let orderedItems =
      physicallyOrdered(rawItems)
      .enumerated()
      .map { index, item in
        RawSourceItemObservation(
          runtimeID: item.runtimeID,
          processIdentifier: item.processIdentifier,
          bundleIdentifier: item.bundleIdentifier,
          applicationName: item.applicationName,
          role: item.role,
          subrole: item.subrole,
          frame: item.frame,
          actions: item.actions,
          metadata: item.metadata,
          observedOrder: index
        )
      }
    let classifiedItems = assessor.classify(orderedItems)

    return InventorySnapshot(
      capturedAt: capturedAt,
      permission: .granted,
      completeness:
        issueTracker.incompleteApplicationCount == 0
        ? .complete
        : .incomplete,
      items: classifiedItems,
      warnings: warnings,
      metrics: ScanMetrics(
        durationMilliseconds: elapsedMilliseconds(since: startedAt),
        inspectedApplicationCount: applications.count,
        sourceItemCount: classifiedItems.count,
        incompleteApplicationCount:
          issueTracker.incompleteApplicationCount,
        cannotCompleteApplicationCount:
          issueTracker.cannotCompleteApplicationCount,
        maximumApplicationScanMilliseconds:
          issueTracker.maximumApplicationScanMilliseconds,
        messagingTimeoutMilliseconds:
          messagingTimeoutSeconds * 1_000
      )
    )
  }

  private func accessibilityIsTrusted(prompt: Bool) -> Bool {
    // The SDK imports kAXTrustedCheckOptionPrompt as mutable global state,
    // which Swift 6 rejects under strict concurrency checking. Its public
    // dictionary key is stable and documented by the same API.
    let options =
      [
        "AXTrustedCheckOptionPrompt": prompt
      ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  private func observations(
    for application: NSRunningApplication,
    issueTracker: AccessibilityScanIssueTracker
  ) -> (items: [RawSourceItemObservation], warning: String?) {
    let processIdentifier = application.processIdentifier
    let applicationElement = AXUIElementCreateApplication(processIdentifier)
    guard configure(applicationElement, issueTracker: issueTracker) else {
      return ([], nil)
    }

    guard
      let extrasMenuBar = axElement(
        attribute: kAXExtrasMenuBarAttribute as CFString,
        from: applicationElement,
        issueTracker: issueTracker
      )
    else {
      return ([], nil)
    }

    let descendants = descendants(
      of: extrasMenuBar,
      maximumDepth: 5,
      issueTracker: issueTracker
    )
    guard issueTracker.currentApplicationIsComplete else {
      return ([], nil)
    }

    var menuItems: [AXUIElement] = []
    for element in descendants {
      guard issueTracker.currentApplicationIsComplete else {
        return ([], nil)
      }
      let role = string(
        attribute: kAXRoleAttribute as CFString,
        from: element,
        issueTracker: issueTracker
      )
      guard issueTracker.currentApplicationIsComplete else {
        return ([], nil)
      }
      if role == (kAXMenuBarItemRole as String) {
        menuItems.append(element)
      }
    }

    var observations: [RawSourceItemObservation] = []
    for (index, element) in menuItems.enumerated() {
      guard
        let item = observation(
          for: element,
          application: application,
          traversalIndex: index,
          issueTracker: issueTracker
        )
      else {
        return ([], nil)
      }
      observations.append(item)
    }

    guard observations.isEmpty else {
      return (observations, nil)
    }

    let bundle = application.bundleIdentifier ?? "pid \(processIdentifier)"
    return (
      [],
      "\(bundle) exposes AXExtrasMenuBar but no AXMenuBarItem descendants."
    )
  }

  private func observation(
    for element: AXUIElement,
    application: NSRunningApplication,
    traversalIndex: Int,
    issueTracker: AccessibilityScanIssueTracker
  ) -> RawSourceItemObservation? {
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }

    let processIdentifier = application.processIdentifier
    var actionValues: CFArray?
    let actionError = AXUIElementCopyActionNames(element, &actionValues)
    issueTracker.record(actionError)
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let actions =
      actionError == .success
      ? (actionValues as? [String] ?? [])
      : []

    let role =
      string(
        attribute: kAXRoleAttribute as CFString,
        from: element,
        issueTracker: issueTracker
      ) ?? "AXUnknown"
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let subrole = string(
      attribute: kAXSubroleAttribute as CFString,
      from: element,
      issueTracker: issueTracker
    )
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let frame = frame(of: element, issueTracker: issueTracker)
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let identifierCandidate = string(
      attribute: kAXIdentifierAttribute as CFString,
      from: element,
      issueTracker: issueTracker
    )
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let title = string(
      attribute: kAXTitleAttribute as CFString,
      from: element,
      issueTracker: issueTracker
    )
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let label = string(
      attribute: kAXDescriptionAttribute as CFString,
      from: element,
      issueTracker: issueTracker
    )
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let help = string(
      attribute: kAXHelpAttribute as CFString,
      from: element,
      issueTracker: issueTracker
    )
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    let roleDescription = string(
      attribute: kAXRoleDescriptionAttribute as CFString,
      from: element,
      issueTracker: issueTracker
    )
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }

    return RawSourceItemObservation(
      runtimeID: "\(processIdentifier):\(traversalIndex)",
      processIdentifier: processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      applicationName: application.localizedName,
      role: role,
      subrole: subrole,
      frame: frame,
      actions: actions.sorted(),
      metadata: LiveAccessibilityMetadata(
        identifierCandidate: identifierCandidate,
        title: title,
        label: label,
        help: help,
        roleDescription: roleDescription
      ),
      observedOrder: traversalIndex
    )
  }

  private func descendants(
    of root: AXUIElement,
    maximumDepth: Int,
    issueTracker: AccessibilityScanIssueTracker
  ) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var visited: [AXUIElement] = [root]
    var nextIndex = 0

    while nextIndex < queue.count {
      guard issueTracker.currentApplicationIsComplete else {
        return []
      }
      guard
        accessibilityTraversalCanAppend(
          currentCount: result.count,
          additionalCount: 1
        )
      else {
        issueTracker.markCurrentApplicationIncomplete()
        return []
      }

      let next = queue[nextIndex]
      nextIndex += 1
      result.append(next.element)

      guard next.depth < maximumDepth else {
        continue
      }

      for child in axElements(
        attribute: kAXChildrenAttribute as CFString,
        from: next.element,
        issueTracker: issueTracker
      ) {
        guard issueTracker.currentApplicationIsComplete else {
          return []
        }
        if visited.contains(where: { CFEqual($0, child) }) {
          continue
        }
        guard
          accessibilityTraversalCanAppend(
            currentCount: visited.count,
            additionalCount: 1
          )
        else {
          issueTracker.markCurrentApplicationIncomplete()
          return []
        }
        visited.append(child)
        queue.append((child, next.depth + 1))
      }
    }

    return result
  }

  private func frame(
    of element: AXUIElement,
    issueTracker: AccessibilityScanIssueTracker
  ) -> ItemFrame? {
    guard
      let positionValue = axValue(
        attribute: kAXPositionAttribute as CFString,
        from: element,
        issueTracker: issueTracker
      ),
      let sizeValue = axValue(
        attribute: kAXSizeAttribute as CFString,
        from: element,
        issueTracker: issueTracker
      ),
      AXValueGetType(positionValue) == .cgPoint,
      AXValueGetType(sizeValue) == .cgSize
    else {
      return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(positionValue, .cgPoint, &position),
      AXValueGetValue(sizeValue, .cgSize, &size)
    else {
      return nil
    }

    return ItemFrame(
      x: position.x,
      y: position.y,
      width: size.width,
      height: size.height
    )
  }

  private func axElement(
    attribute: CFString,
    from element: AXUIElement,
    issueTracker: AccessibilityScanIssueTracker
  ) -> AXUIElement? {
    guard
      let value = attributeValue(
        attribute,
        from: element,
        issueTracker: issueTracker
      )
    else {
      return nil
    }
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
      issueTracker.markCurrentApplicationIncomplete()
      return nil
    }
    let result = unsafeDowncast(value, to: AXUIElement.self)
    guard configure(result, issueTracker: issueTracker) else {
      return nil
    }
    return result
  }

  private func axElements(
    attribute: CFString,
    from element: AXUIElement,
    issueTracker: AccessibilityScanIssueTracker
  ) -> [AXUIElement] {
    guard issueTracker.currentApplicationIsComplete else {
      return []
    }
    guard
      let value = attributeValue(
        attribute,
        from: element,
        issueTracker: issueTracker
      )
    else {
      return []
    }
    guard CFGetTypeID(value) == CFArrayGetTypeID() else {
      issueTracker.markCurrentApplicationIncomplete()
      return []
    }
    let array = unsafeDowncast(value, to: CFArray.self)
    guard
      accessibilityTraversalCanAppend(
        currentCount: 0,
        additionalCount: CFArrayGetCount(array)
      )
    else {
      issueTracker.markCurrentApplicationIncomplete()
      return []
    }
    guard let children = value as? [AXUIElement] else {
      issueTracker.markCurrentApplicationIncomplete()
      return []
    }

    var configuredElements: [AXUIElement] = []
    for child in children {
      guard issueTracker.currentApplicationIsComplete else {
        return []
      }
      guard configure(child, issueTracker: issueTracker) else {
        return []
      }
      configuredElements.append(child)
    }
    return configuredElements
  }

  private func axValue(
    attribute: CFString,
    from element: AXUIElement,
    issueTracker: AccessibilityScanIssueTracker
  ) -> AXValue? {
    guard
      let value = attributeValue(
        attribute,
        from: element,
        issueTracker: issueTracker
      ),
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXValue.self)
  }

  private func string(
    attribute: CFString,
    from element: AXUIElement,
    issueTracker: AccessibilityScanIssueTracker
  ) -> String? {
    attributeValue(
      attribute,
      from: element,
      issueTracker: issueTracker
    ) as? String
  }

  private func attributeValue(
    _ attribute: CFString,
    from element: AXUIElement,
    issueTracker: AccessibilityScanIssueTracker
  ) -> CFTypeRef? {
    guard issueTracker.currentApplicationIsComplete else {
      return nil
    }
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    issueTracker.record(error)
    guard error == .success else {
      return nil
    }
    return value
  }

  private func configure(
    _ element: AXUIElement,
    issueTracker: AccessibilityScanIssueTracker
  ) -> Bool {
    guard issueTracker.currentApplicationIsComplete else {
      return false
    }
    let error = AXUIElementSetMessagingTimeout(
      element,
      Float(messagingTimeoutSeconds)
    )
    issueTracker.record(error, operation: .timeoutConfiguration)
    return error == .success
  }

  private func elapsedMilliseconds(since start: UInt64) -> Double {
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return Double(elapsed) / 1_000_000
  }
}

func physicallyOrdered(
  _ observations: [RawSourceItemObservation]
) -> [RawSourceItemObservation] {
  observations.sorted {
    PhysicalOrderKey(observation: $0) < PhysicalOrderKey(observation: $1)
  }
}

private struct PhysicalOrderKey: Comparable {
  let geometryBucket: Int
  let y: Double
  let x: Double
  let runtimeID: String

  init(observation: RawSourceItemObservation) {
    if let frame = observation.frame, frame.isUsable {
      geometryBucket = 0
      y = frame.y
      x = frame.x
    } else {
      geometryBucket = 1
      y = 0
      x = 0
    }
    runtimeID = observation.runtimeID
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.geometryBucket != rhs.geometryBucket {
      return lhs.geometryBucket < rhs.geometryBucket
    }
    if lhs.y != rhs.y {
      return lhs.y < rhs.y
    }
    if lhs.x != rhs.x {
      return lhs.x < rhs.x
    }
    return lhs.runtimeID < rhs.runtimeID
  }
}

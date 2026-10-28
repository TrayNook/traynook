import AppKit
import ApplicationServices
import Foundation

public enum AccessibilityInventoryTuning {
  /// Public Accessibility messaging is synchronous. A bounded timeout prevents
  /// one unresponsive process from stalling the complete inventory loop.
  public static let defaultMessagingTimeoutSeconds = 0.2
  public static let minimumMessagingTimeoutSeconds = 0.01
  public static let maximumMessagingTimeoutSeconds = 2.0
  public static let defaultScanBudgetSeconds = 2.0
  public static let allowedScanBudgetSeconds = 0.01...10.0
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

struct StatusWindowObservation: Equatable {
  let processIdentifier: Int32
  let windowIdentifier: UInt32
  let frame: ItemFrame
  let isOnscreen: Bool
}

func statusWindowObservations(in windows: [[String: Any]]?) -> [StatusWindowObservation]? {
  guard let windows else { return nil }
  var result: [StatusWindowObservation] = []
  for window in windows {
    guard let level = window[kCGWindowLayer as String] as? Int else { return nil }
    guard level == Int(CGWindowLevelForKey(.statusWindow)) else { continue }
    guard let rawOwner = window[kCGWindowOwnerPID as String] as? Int,
      let owner = Int32(exactly: rawOwner), owner > 0 else { return nil }
    // Our own controls and popover also use the status-window level. They are
    // managed directly and must not become sources or invalidate concealment.
    guard owner != ProcessInfo.processInfo.processIdentifier else { continue }
    guard let rawIdentifier = window[kCGWindowNumber as String] as? Int,
      let identifier = UInt32(exactly: rawIdentifier), identifier > 0,
      let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { return nil }
    let frame = ItemFrame(x: rectangle.minX, y: rectangle.minY,
      width: rectangle.width, height: rectangle.height)
    guard frame.isUsable else { return nil }
    // CGWindow.h explicitly defines an absent visibility key as offscreen.
    // A present value must be a real Boolean, not malformed metadata.
    var isOnscreen = false
    if let value = window[kCGWindowIsOnscreen as String] {
      guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
        let visibility = value as? Bool else { return nil }
      isOnscreen = visibility
    }
    result.append(StatusWindowObservation(
      processIdentifier: owner, windowIdentifier: identifier,
      frame: frame, isOnscreen: isOnscreen))
  }
  return result
}

private func statusWindow(_ window: StatusWindowObservation, overlaps item: RawSourceItemObservation) -> Bool {
  guard item.processIdentifier == window.processIdentifier,
    let frame = item.frame, frame.isUsable, window.frame.isUsable,
    // Apps also open panels at the status level (DockDoor's preview spans the
    // display). Only a menu-bar-row-sized window can be the item's own.
    window.frame.height <= 2 * frame.height else { return false }
  return frame.x < window.frame.maxX && frame.maxX > window.frame.x
    && frame.y < window.frame.maxY && frame.maxY > window.frame.y
}

func statusWindowVisibility(
  of item: RawSourceItemObservation, in windows: [StatusWindowObservation]
) -> Bool? {
  let matching = windows.filter { statusWindow($0, overlaps: item) }
  guard !matching.isEmpty else { return nil }
  return matching.contains(where: \.isOnscreen)
}

func statusWindowIdentifier(
  of item: RawSourceItemObservation, in windows: [StatusWindowObservation]
) -> UInt32? {
  var matching = windows.filter { statusWindow($0, overlaps: item) }
  if matching.count > 1 { matching = matching.filter(\.isOnscreen) } // stale offscreen duplicates
  return matching.count == 1 ? matching[0].windowIdentifier : nil
}

func unrepresentedStatusWindows(
  _ windows: [StatusWindowObservation], comparedTo items: [RawSourceItemObservation]
) -> [StatusWindowObservation] {
  let rows = items.compactMap(\.frame).filter(\.isUsable)
  return windows.filter { window in
    window.isOnscreen && !items.contains { statusWindow(window, overlaps: $0) }
      // Every status item owns one window per display. Windows on another
      // display's menu bar share no row with any AX item and are duplicates;
      // status-level panels taller than the row are not items either.
      && (rows.isEmpty || rows.contains {
        $0.y < window.frame.maxY && $0.maxY > window.frame.y && window.frame.height <= 2 * $0.height
      })
  }.map { window in
    // Status-window bounds include vertical padding outside the AX menu row.
    // Retain horizontal extent; unknown rows keep their full protected frame.
    let row = items.compactMap(\.frame).first {
      $0.isUsable && $0.y < window.frame.maxY && $0.maxY > window.frame.y
    }
    let y = max(window.frame.y, row?.y ?? window.frame.y)
    let maxY = min(window.frame.maxY, row?.maxY ?? window.frame.maxY)
    return StatusWindowObservation(processIdentifier: window.processIdentifier,
      windowIdentifier: window.windowIdentifier,
      frame: ItemFrame(x: window.frame.x, y: y, width: window.frame.width, height: maxY - y),
      isOnscreen: true)
  }
}

final class AccessibilityScanIssueTracker {
  private let deadline: UInt64
  private let uptimeNanoseconds: () -> UInt64
  private var currentProcessIdentifier: Int32?
  private(set) var incompleteProcessIdentifiers = Set<Int32>()
  private var cannotCompleteProcessIdentifiers = Set<Int32>()

  private(set) var maximumApplicationScanMilliseconds = 0.0

  init(
    deadline: UInt64 = .max,
    uptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.deadline = deadline
    self.uptimeNanoseconds = uptimeNanoseconds
  }

  var scanBudgetExceeded: Bool { uptimeNanoseconds() >= deadline }

  var snapshotIsComplete: Bool { !scanBudgetExceeded && incompleteApplicationCount == 0 }

  var incompleteApplicationCount: Int {
    incompleteProcessIdentifiers.count
  }

  var cannotCompleteApplicationCount: Int {
    cannotCompleteProcessIdentifiers.count
  }

  var currentApplicationIsComplete: Bool {
    guard !scanBudgetExceeded else {
      markCurrentApplicationIncomplete()
      return false
    }
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
  private let scanBudgetSeconds: Double

  public init(
    assessor: IdentityAssessor = IdentityAssessor(),
    messagingTimeoutSeconds: Double =
      AccessibilityInventoryTuning.defaultMessagingTimeoutSeconds,
    scanBudgetSeconds: Double = AccessibilityInventoryTuning.defaultScanBudgetSeconds
  ) {
    precondition(
      messagingTimeoutSeconds
        >= AccessibilityInventoryTuning.minimumMessagingTimeoutSeconds
        && messagingTimeoutSeconds
          <= AccessibilityInventoryTuning.maximumMessagingTimeoutSeconds
    )
    precondition(AccessibilityInventoryTuning.allowedScanBudgetSeconds.contains(scanBudgetSeconds))
    self.assessor = assessor
    self.messagingTimeoutSeconds = messagingTimeoutSeconds
    self.scanBudgetSeconds = scanBudgetSeconds
  }

  public func scan(promptForPermission: Bool = false) -> InventorySnapshot {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let trusted = accessibilityIsTrusted(prompt: promptForPermission)
    let capturedAt = Date()
    // All windows includes concealed/offscreen status items. Only metadata is
    // read; there is no window capture and no Screen Recording requirement.
    let statusWindows = trusted ? statusWindowObservations(
      in: CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    ) : nil

    guard trusted, let statusWindows else {
      return InventorySnapshot(
        capturedAt: capturedAt,
        permission: trusted ? .granted : .denied,
        completeness: .incomplete,
        items: [],
        warnings: [
          trusted
            ? "Status-window ownership is unavailable. This snapshot must not drive changes."
            : "Accessibility is not granted. No Source Items were inspected."
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

    var rawItems: [RawSourceItemObservation] = []
    var warnings: [String] = []
    var inspectedApplicationCount = 0
    let issueTracker = AccessibilityScanIssueTracker(
      deadline: startedAt + UInt64(scanBudgetSeconds * 1_000_000_000)
    )

    for processIdentifier in Set(statusWindows.map(\.processIdentifier)).sorted() {
      guard !issueTracker.scanBudgetExceeded else { break }
      inspectedApplicationCount += 1
      let applicationStartedAt = DispatchTime.now().uptimeNanoseconds
      issueTracker.beginApplication(processIdentifier)
      guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
        issueTracker.markCurrentApplicationIncomplete()
        issueTracker.finishApplication(durationMilliseconds: elapsedMilliseconds(since: applicationStartedAt))
        continue
      }
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

    for window in unrepresentedStatusWindows(statusWindows, comparedTo: rawItems) {
      let application = NSRunningApplication(processIdentifier: window.processIdentifier)
      rawItems.append(RawSourceItemObservation(
        runtimeID: "\(window.processIdentifier):window:\(window.windowIdentifier)",
        processIdentifier: window.processIdentifier,
        bundleIdentifier: application?.bundleIdentifier,
        applicationName: application?.localizedName,
        role: "UnverifiedStatusWindow", frame: window.frame,
        actions: [], metadata: LiveAccessibilityMetadata(), observedOrder: rawItems.count,
        statusWindowIdentifier: window.windowIdentifier))
    }

    if issueTracker.incompleteApplicationCount > 0 {
      let names = issueTracker.incompleteProcessIdentifiers.sorted().map {
        NSRunningApplication(processIdentifier: $0)?.bundleIdentifier ?? "pid \($0)"
      }
      warnings.append(
        "\(issueTracker.incompleteApplicationCount) applications could not be "
          + "scanned completely (\(names.joined(separator: ", "))); this snapshot must not drive changes."
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
          observedOrder: index,
          isOnscreen: statusWindowVisibility(of: item, in: statusWindows),
          statusWindowIdentifier: statusWindowIdentifier(of: item, in: statusWindows)
        )
      }
    let classifiedItems = assessor.classify(orderedItems)
    if issueTracker.scanBudgetExceeded {
      warnings.append("The inventory scan exceeded its time budget; this snapshot must not drive changes.")
    }

    return InventorySnapshot(
      capturedAt: capturedAt,
      permission: .granted,
      completeness:
        issueTracker.snapshotIsComplete
        ? .complete
        : .incomplete,
      items: classifiedItems,
      statusWindowRuntimeIDs: Set(statusWindows.map(\.windowIdentifier)),
      warnings: warnings,
      metrics: ScanMetrics(
        durationMilliseconds: elapsedMilliseconds(since: startedAt),
        inspectedApplicationCount: inspectedApplicationCount,
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

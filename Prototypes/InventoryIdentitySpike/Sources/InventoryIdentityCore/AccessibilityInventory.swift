import AppKit
import ApplicationServices
import Foundation

public struct AccessibilityInventoryScanner {
  private let assessor: IdentityAssessor

  public init(assessor: IdentityAssessor = IdentityAssessor()) {
    self.assessor = assessor
  }

  public func scan(promptForPermission: Bool = false) -> InventorySnapshot {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let trusted = accessibilityIsTrusted(prompt: promptForPermission)
    let capturedAt = Date()

    guard trusted else {
      return InventorySnapshot(
        capturedAt: capturedAt,
        permission: .denied,
        items: [],
        warnings: [
          "Accessibility is not granted. No Source Items were inspected."
        ],
        metrics: ScanMetrics(
          durationMilliseconds: elapsedMilliseconds(since: startedAt),
          inspectedApplicationCount: 0,
          sourceItemCount: 0
        )
      )
    }

    let applications = NSWorkspace.shared.runningApplications
      .filter { $0.processIdentifier > 0 }
      .sorted { $0.processIdentifier < $1.processIdentifier }
    var rawItems: [RawSourceItemObservation] = []
    var warnings: [String] = []

    for application in applications {
      let result = observations(for: application)
      rawItems.append(contentsOf: result.items)
      if let warning = result.warning {
        warnings.append(warning)
      }
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
      items: classifiedItems,
      warnings: warnings,
      metrics: ScanMetrics(
        durationMilliseconds: elapsedMilliseconds(since: startedAt),
        inspectedApplicationCount: applications.count,
        sourceItemCount: classifiedItems.count
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
    for application: NSRunningApplication
  ) -> (items: [RawSourceItemObservation], warning: String?) {
    let processIdentifier = application.processIdentifier
    let applicationElement = AXUIElementCreateApplication(processIdentifier)

    guard
      let extrasMenuBar = axElement(
        attribute: kAXExtrasMenuBarAttribute as CFString,
        from: applicationElement
      )
    else {
      return ([], nil)
    }

    let menuItems = descendants(of: extrasMenuBar, maximumDepth: 5)
      .filter {
        string(attribute: kAXRoleAttribute as CFString, from: $0)
          == (kAXMenuBarItemRole as String)
      }

    let observations = menuItems.enumerated().map { index, element in
      observation(
        for: element,
        application: application,
        traversalIndex: index
      )
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
    traversalIndex: Int
  ) -> RawSourceItemObservation {
    let processIdentifier = application.processIdentifier
    var actionValues: CFArray?
    let actionError = AXUIElementCopyActionNames(element, &actionValues)
    let actions =
      actionError == .success
      ? (actionValues as? [String] ?? [])
      : []

    return RawSourceItemObservation(
      runtimeID: "\(processIdentifier):\(traversalIndex)",
      processIdentifier: processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      applicationName: application.localizedName,
      role: string(
        attribute: kAXRoleAttribute as CFString,
        from: element
      ) ?? "AXUnknown",
      subrole: string(
        attribute: kAXSubroleAttribute as CFString,
        from: element
      ),
      frame: frame(of: element),
      actions: actions.sorted(),
      metadata: LiveAccessibilityMetadata(
        identifierCandidate: string(
          attribute: kAXIdentifierAttribute as CFString,
          from: element
        ),
        title: string(
          attribute: kAXTitleAttribute as CFString,
          from: element
        ),
        label: string(
          attribute: kAXDescriptionAttribute as CFString,
          from: element
        ),
        help: string(
          attribute: kAXHelpAttribute as CFString,
          from: element
        ),
        roleDescription: string(
          attribute: kAXRoleDescriptionAttribute as CFString,
          from: element
        )
      ),
      observedOrder: traversalIndex
    )
  }

  private func descendants(
    of root: AXUIElement,
    maximumDepth: Int
  ) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]

    while let next = queue.first {
      queue.removeFirst()
      result.append(next.element)

      guard next.depth < maximumDepth else {
        continue
      }

      for child in axElements(
        attribute: kAXChildrenAttribute as CFString,
        from: next.element
      ) {
        queue.append((child, next.depth + 1))
      }
    }

    return result
  }

  private func frame(of element: AXUIElement) -> ItemFrame? {
    guard
      let positionValue = axValue(
        attribute: kAXPositionAttribute as CFString,
        from: element
      ),
      let sizeValue = axValue(
        attribute: kAXSizeAttribute as CFString,
        from: element
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
    from element: AXUIElement
  ) -> AXUIElement? {
    guard
      let value = attributeValue(attribute, from: element),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func axElements(
    attribute: CFString,
    from element: AXUIElement
  ) -> [AXUIElement] {
    guard
      let value = attributeValue(attribute, from: element),
      CFGetTypeID(value) == CFArrayGetTypeID()
    else {
      return []
    }
    return value as? [AXUIElement] ?? []
  }

  private func axValue(
    attribute: CFString,
    from element: AXUIElement
  ) -> AXValue? {
    guard
      let value = attributeValue(attribute, from: element),
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXValue.self)
  }

  private func string(
    attribute: CFString,
    from element: AXUIElement
  ) -> String? {
    attributeValue(attribute, from: element) as? String
  }

  private func attributeValue(
    _ attribute: CFString,
    from element: AXUIElement
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard error == .success else {
      return nil
    }
    return value
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

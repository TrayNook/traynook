import Foundation

public enum AdditionValidationStatus: String, Codable, Sendable {
  case detected
  case accessibilityDenied
  case markerTimedOut
  case additionTimedOut
}

public struct ValidationEnvironment: Codable, Equatable, Sendable {
  public let operatingSystem: String
  public let architecture: String

  public init(operatingSystem: String, architecture: String) {
    self.operatingSystem = operatingSystem
    self.architecture = architecture
  }

  public static var current: Self {
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "unknown"
    #endif

    return Self(
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture
    )
  }
}

/// Sanitized output for the live Gate A addition scenario. It deliberately
/// excludes the target bundle, Source Item inventory, Accessibility metadata,
/// geometry, process IDs, and provisional identity values.
public struct AdditionValidationReport: Codable, Equatable, Sendable {
  public let scenario: String
  public let status: AdditionValidationStatus
  public let environment: ValidationEnvironment
  public let intervalMilliseconds: Double
  public let timeoutSeconds: Double
  public let completedScanCount: Int
  public let markerToDetectionMilliseconds: Double?
  public let averageScanMilliseconds: Double
  public let maximumScanMilliseconds: Double
  public let detectedChangeKind: SnapshotChangeKind?

  public init(
    status: AdditionValidationStatus,
    environment: ValidationEnvironment,
    intervalMilliseconds: Double,
    timeoutSeconds: Double,
    completedScanCount: Int,
    markerToDetectionMilliseconds: Double?,
    averageScanMilliseconds: Double,
    maximumScanMilliseconds: Double,
    detectedChangeKind: SnapshotChangeKind?
  ) {
    scenario = "new-item-detection"
    self.status = status
    self.environment = environment
    self.intervalMilliseconds = intervalMilliseconds
    self.timeoutSeconds = timeoutSeconds
    self.completedScanCount = completedScanCount
    self.markerToDetectionMilliseconds = markerToDetectionMilliseconds
    self.averageScanMilliseconds = averageScanMilliseconds
    self.maximumScanMilliseconds = maximumScanMilliseconds
    self.detectedChangeKind = detectedChangeKind
  }
}

public struct AdditionChangeEvaluator: Sendable {
  public init() {}

  public func relevantAddition(
    in changes: [SnapshotChange],
    targetBundleIdentifier: String?
  ) -> SnapshotChange? {
    relevantAdditions(
      in: changes,
      targetBundleIdentifier: targetBundleIdentifier
    ).first
  }

  public func relevantAdditions(
    in changes: [SnapshotChange],
    targetBundleIdentifier: String?
  ) -> [SnapshotChange] {
    changes.filter { change in
      switch change.kind {
      case .created:
        guard
          targetMatches(
            change.identity?.bundleIdentifier,
            targetBundleIdentifier
          )
        else {
          return false
        }
        return true

      case .ambiguousInventoryChanged:
        guard
          targetMatches(
            change.runtimeGroup?.bundleIdentifier,
            targetBundleIdentifier
          ),
          let previousCount = change.previousCount,
          let currentCount = change.currentCount
        else {
          return false
        }
        return currentCount > previousCount

      case .removed, .processReplaced, .orderChanged,
        .runtimeMetadataChanged:
        return false
      }
    }
  }

  private func targetMatches(
    _ observedBundleIdentifier: String?,
    _ targetBundleIdentifier: String?
  ) -> Bool {
    guard let targetBundleIdentifier else {
      return true
    }
    return observedBundleIdentifier == targetBundleIdentifier
  }
}

public struct AdditionValidationRunner {
  private let scanner: AccessibilityInventoryScanner
  private let differ: SnapshotDiffer
  private let evaluator: AdditionChangeEvaluator

  public init(
    scanner: AccessibilityInventoryScanner = AccessibilityInventoryScanner(),
    differ: SnapshotDiffer = SnapshotDiffer(),
    evaluator: AdditionChangeEvaluator = AdditionChangeEvaluator()
  ) {
    self.scanner = scanner
    self.differ = differ
    self.evaluator = evaluator
  }

  public func run(
    intervalSeconds: Double,
    timeoutSeconds: Double,
    targetBundleIdentifier: String?,
    promptForPermission: Bool = false,
    markerUptimeNanoseconds: () -> UInt64?
  ) -> AdditionValidationReport {
    precondition(intervalSeconds > 0)
    precondition(timeoutSeconds > 0)

    let runStartedAt = DispatchTime.now().uptimeNanoseconds
    var previous = scanner.scan(promptForPermission: promptForPermission)
    var durations = [previous.metrics.durationMilliseconds]

    guard previous.permission == .granted else {
      return report(
        status: .accessibilityDenied,
        intervalSeconds: intervalSeconds,
        timeoutSeconds: timeoutSeconds,
        durations: durations
      )
    }

    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      let marker = markerUptimeNanoseconds()
      let deadlineOrigin = marker ?? runStartedAt
      if seconds(from: deadlineOrigin, to: now) >= timeoutSeconds {
        return report(
          status: marker == nil ? .markerTimedOut : .additionTimedOut,
          intervalSeconds: intervalSeconds,
          timeoutSeconds: timeoutSeconds,
          durations: durations
        )
      }

      Thread.sleep(forTimeInterval: intervalSeconds)
      let current = scanner.scan()
      durations.append(current.metrics.durationMilliseconds)

      guard current.permission == .granted else {
        return report(
          status: .accessibilityDenied,
          intervalSeconds: intervalSeconds,
          timeoutSeconds: timeoutSeconds,
          durations: durations
        )
      }

      let changes = differ.changes(
        from: previous.items,
        to: current.items
      )
      previous = current

      guard
        let marker = markerUptimeNanoseconds(),
        let addition = evaluator.relevantAddition(
          in: changes,
          targetBundleIdentifier: targetBundleIdentifier
        )
      else {
        continue
      }

      let detectedAt = DispatchTime.now().uptimeNanoseconds
      return report(
        status: .detected,
        intervalSeconds: intervalSeconds,
        timeoutSeconds: timeoutSeconds,
        durations: durations,
        markerToDetectionMilliseconds:
          milliseconds(from: marker, to: detectedAt),
        detectedChangeKind: addition.kind
      )
    }
  }

  private func report(
    status: AdditionValidationStatus,
    intervalSeconds: Double,
    timeoutSeconds: Double,
    durations: [Double],
    markerToDetectionMilliseconds: Double? = nil,
    detectedChangeKind: SnapshotChangeKind? = nil
  ) -> AdditionValidationReport {
    AdditionValidationReport(
      status: status,
      environment: .current,
      intervalMilliseconds: intervalSeconds * 1_000,
      timeoutSeconds: timeoutSeconds,
      completedScanCount: durations.count,
      markerToDetectionMilliseconds: markerToDetectionMilliseconds,
      averageScanMilliseconds: durations.reduce(0, +)
        / Double(durations.count),
      maximumScanMilliseconds: durations.max() ?? 0,
      detectedChangeKind: detectedChangeKind
    )
  }

  private func seconds(from start: UInt64, to end: UInt64) -> Double {
    Double(end - start) / 1_000_000_000
  }

  private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
    Double(end - start) / 1_000_000
  }
}

import Foundation

public enum AdditionValidationStatus: String, Codable, Sendable {
  case detected
  case accessibilityDenied
  case inventoryIncomplete
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
  public let completeScanCount: Int
  public let incompleteScanCount: Int
  public let cannotCompleteApplicationScanCount: Int
  public let messagingTimeoutMilliseconds: Double
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
    completeScanCount: Int? = nil,
    incompleteScanCount: Int = 0,
    cannotCompleteApplicationScanCount: Int = 0,
    messagingTimeoutMilliseconds: Double = 0,
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
    self.completeScanCount =
      completeScanCount ?? (completedScanCount - incompleteScanCount)
    self.incompleteScanCount = incompleteScanCount
    self.cannotCompleteApplicationScanCount =
      cannotCompleteApplicationScanCount
    self.messagingTimeoutMilliseconds = messagingTimeoutMilliseconds
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
  private let scanner: any InventoryScanning
  private let differ: SnapshotDiffer
  private let evaluator: AdditionChangeEvaluator
  private let uptimeNanoseconds: @Sendable () -> UInt64
  private let sleep: @Sendable (Double) -> Void

  public init(
    scanner: any InventoryScanning = AccessibilityInventoryScanner(),
    differ: SnapshotDiffer = SnapshotDiffer(),
    evaluator: AdditionChangeEvaluator = AdditionChangeEvaluator(),
    uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    },
    sleep: @escaping @Sendable (Double) -> Void = {
      Thread.sleep(forTimeInterval: $0)
    }
  ) {
    self.scanner = scanner
    self.differ = differ
    self.evaluator = evaluator
    self.uptimeNanoseconds = uptimeNanoseconds
    self.sleep = sleep
  }

  public func run(
    intervalSeconds: Double,
    timeoutSeconds: Double,
    targetBundleIdentifier: String?,
    promptForPermission: Bool = false,
    markerUptimeNanoseconds: () -> UInt64?,
    onArmed: () -> Void = {}
  ) -> AdditionValidationReport {
    precondition(intervalSeconds > 0)
    precondition(timeoutSeconds > 0)
    precondition(targetBundleIdentifier?.isEmpty == false)

    let initial = scanner.scan(promptForPermission: promptForPermission)
    var snapshots = [initial]

    guard initial.permission == .granted else {
      return report(
        status: .accessibilityDenied,
        intervalSeconds: intervalSeconds,
        timeoutSeconds: timeoutSeconds,
        snapshots: snapshots
      )
    }
    guard initial.completeness == .complete else {
      return report(
        status: .inventoryIncomplete,
        intervalSeconds: intervalSeconds,
        timeoutSeconds: timeoutSeconds,
        snapshots: snapshots
      )
    }
    var changeTracker = CompleteSnapshotChangeTracker()
    _ = changeTracker.changes(for: initial, using: differ)
    onArmed()
    let runStartedAt = uptimeNanoseconds()

    while true {
      let marker = markerUptimeNanoseconds()
      let now = uptimeNanoseconds()
      let deadlineOrigin = marker ?? runStartedAt
      if seconds(from: deadlineOrigin, to: now) >= timeoutSeconds {
        return report(
          status: marker == nil ? .markerTimedOut : .additionTimedOut,
          intervalSeconds: intervalSeconds,
          timeoutSeconds: timeoutSeconds,
          snapshots: snapshots
        )
      }

      sleep(intervalSeconds)
      let current = scanner.scan(promptForPermission: false)
      snapshots.append(current)

      guard current.permission == .granted else {
        return report(
          status: .accessibilityDenied,
          intervalSeconds: intervalSeconds,
          timeoutSeconds: timeoutSeconds,
          snapshots: snapshots
        )
      }
      guard current.completeness == .complete else {
        continue
      }

      let markerAfterScan = markerUptimeNanoseconds()
      let scanFinishedAt = uptimeNanoseconds()
      let deadlineOriginAfterScan = markerAfterScan ?? runStartedAt
      guard
        seconds(from: deadlineOriginAfterScan, to: scanFinishedAt)
          < timeoutSeconds
      else {
        return report(
          status:
            markerAfterScan == nil
            ? .markerTimedOut
            : .additionTimedOut,
          intervalSeconds: intervalSeconds,
          timeoutSeconds: timeoutSeconds,
          snapshots: snapshots
        )
      }

      let changes = changeTracker.changes(
        for: current,
        using: differ
      )

      guard
        let marker = markerUptimeNanoseconds(),
        let addition = evaluator.relevantAddition(
          in: changes,
          targetBundleIdentifier: targetBundleIdentifier
        )
      else {
        continue
      }

      let detectedAt = uptimeNanoseconds()
      return report(
        status: .detected,
        intervalSeconds: intervalSeconds,
        timeoutSeconds: timeoutSeconds,
        snapshots: snapshots,
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
    snapshots: [InventorySnapshot],
    markerToDetectionMilliseconds: Double? = nil,
    detectedChangeKind: SnapshotChangeKind? = nil
  ) -> AdditionValidationReport {
    let scanMetrics = snapshots.map(\.metrics)
    let durations = scanMetrics.map(\.durationMilliseconds)
    let incompleteScanCount = snapshots.filter {
      $0.completeness == .incomplete
    }.count
    return AdditionValidationReport(
      status: status,
      environment: .current,
      intervalMilliseconds: intervalSeconds * 1_000,
      timeoutSeconds: timeoutSeconds,
      completedScanCount: durations.count,
      completeScanCount: durations.count - incompleteScanCount,
      incompleteScanCount: incompleteScanCount,
      cannotCompleteApplicationScanCount: scanMetrics.reduce(0) {
        $0 + $1.cannotCompleteApplicationCount
      },
      messagingTimeoutMilliseconds:
        scanMetrics.first?.messagingTimeoutMilliseconds ?? 0,
      markerToDetectionMilliseconds: markerToDetectionMilliseconds,
      averageScanMilliseconds: durations.reduce(0, +)
        / Double(durations.count),
      maximumScanMilliseconds: durations.max() ?? 0,
      detectedChangeKind: detectedChangeKind
    )
  }

  private func seconds(from start: UInt64, to end: UInt64) -> Double {
    guard end >= start else {
      return 0
    }
    return Double(end - start) / 1_000_000_000
  }

  private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
    guard end >= start else {
      return 0
    }
    return Double(end - start) / 1_000_000
  }
}

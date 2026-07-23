import Foundation

public struct ItemFrame: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isUsable: Bool {
    x.isFinite
      && y.isFinite
      && width.isFinite
      && height.isFinite
      && width > 0
      && height > 0
  }
}

/// Runtime-only Accessibility text. TrayNook must never put these values in its
/// persistent identity store because titles and labels can contain user content.
public struct LiveAccessibilityMetadata: Codable, Equatable, Sendable {
  public let identifierCandidate: String?
  public let title: String?
  public let label: String?
  public let help: String?
  public let roleDescription: String?

  public init(
    identifierCandidate: String? = nil,
    title: String? = nil,
    label: String? = nil,
    help: String? = nil,
    roleDescription: String? = nil
  ) {
    self.identifierCandidate = identifierCandidate
    self.title = title
    self.label = label
    self.help = help
    self.roleDescription = roleDescription
  }
}

public struct RawSourceItemObservation: Codable, Equatable, Sendable {
  public let runtimeID: String
  public let processIdentifier: Int32
  public let bundleIdentifier: String?
  public let applicationName: String?
  public let role: String
  public let subrole: String?
  public let frame: ItemFrame?
  public let actions: [String]
  public let metadata: LiveAccessibilityMetadata
  public let observedOrder: Int

  public init(
    runtimeID: String,
    processIdentifier: Int32,
    bundleIdentifier: String?,
    applicationName: String?,
    role: String,
    subrole: String? = nil,
    frame: ItemFrame?,
    actions: [String],
    metadata: LiveAccessibilityMetadata,
    observedOrder: Int
  ) {
    self.runtimeID = runtimeID
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.applicationName = applicationName
    self.role = role
    self.subrole = subrole
    self.frame = frame
    self.actions = actions
    self.metadata = metadata
    self.observedOrder = observedOrder
  }
}

public struct ProvisionalIdentityKey: Codable, Equatable, Hashable, Sendable {
  public let bundleIdentifier: String
  public let discriminatorCandidate: String?

  public init(bundleIdentifier: String, discriminatorCandidate: String? = nil) {
    self.bundleIdentifier = bundleIdentifier
    self.discriminatorCandidate = discriminatorCandidate
  }

  public var diagnosticDescription: String {
    if let discriminatorCandidate {
      return "\(bundleIdentifier)#\(discriminatorCandidate)"
    }
    return bundleIdentifier
  }
}

public enum IdentityStatus: String, Codable, Sendable {
  case provisionalBundleIdentity
  case provisionalDiscriminator
  case ambiguous
}

public struct IdentityAssessment: Codable, Equatable, Sendable {
  public let status: IdentityStatus
  public let provisionalKey: ProvisionalIdentityKey?
  public let reason: String

  public init(
    status: IdentityStatus,
    provisionalKey: ProvisionalIdentityKey?,
    reason: String
  ) {
    self.status = status
    self.provisionalKey = provisionalKey
    self.reason = reason
  }
}

public enum ManageabilityStatus: String, Codable, Sendable {
  case candidate
  case requiresValidation
  case protected
}

public struct ManageabilityAssessment: Codable, Equatable, Sendable {
  public let status: ManageabilityStatus
  public let reason: String

  public init(status: ManageabilityStatus, reason: String) {
    self.status = status
    self.reason = reason
  }
}

public struct ClassifiedSourceItem: Codable, Equatable, Sendable {
  public let observation: RawSourceItemObservation
  public let identity: IdentityAssessment
  public let manageability: ManageabilityAssessment

  public init(
    observation: RawSourceItemObservation,
    identity: IdentityAssessment,
    manageability: ManageabilityAssessment
  ) {
    self.observation = observation
    self.identity = identity
    self.manageability = manageability
  }
}

public enum AccessibilityPermissionStatus: String, Codable, Sendable {
  case granted
  case denied
}

public enum InventoryScanCompleteness: String, Codable, Sendable {
  case complete
  case incomplete
}

public struct ScanMetrics: Codable, Equatable, Sendable {
  public let durationMilliseconds: Double
  public let inspectedApplicationCount: Int
  public let sourceItemCount: Int
  public let incompleteApplicationCount: Int
  public let cannotCompleteApplicationCount: Int
  public let maximumApplicationScanMilliseconds: Double
  public let messagingTimeoutMilliseconds: Double

  public init(
    durationMilliseconds: Double,
    inspectedApplicationCount: Int,
    sourceItemCount: Int,
    incompleteApplicationCount: Int = 0,
    cannotCompleteApplicationCount: Int = 0,
    maximumApplicationScanMilliseconds: Double = 0,
    messagingTimeoutMilliseconds: Double = 0
  ) {
    self.durationMilliseconds = durationMilliseconds
    self.inspectedApplicationCount = inspectedApplicationCount
    self.sourceItemCount = sourceItemCount
    self.incompleteApplicationCount = incompleteApplicationCount
    self.cannotCompleteApplicationCount =
      cannotCompleteApplicationCount
    self.maximumApplicationScanMilliseconds =
      maximumApplicationScanMilliseconds
    self.messagingTimeoutMilliseconds = messagingTimeoutMilliseconds
  }
}

public struct InventorySnapshot: Codable, Equatable, Sendable {
  public let capturedAt: Date
  public let permission: AccessibilityPermissionStatus
  public let completeness: InventoryScanCompleteness
  public let items: [ClassifiedSourceItem]
  public let warnings: [String]
  public let metrics: ScanMetrics

  public init(
    capturedAt: Date,
    permission: AccessibilityPermissionStatus,
    completeness: InventoryScanCompleteness = .complete,
    items: [ClassifiedSourceItem],
    warnings: [String],
    metrics: ScanMetrics
  ) {
    self.capturedAt = capturedAt
    self.permission = permission
    self.completeness = completeness
    self.items = items
    self.warnings = warnings
    self.metrics = metrics
  }
}

public enum SnapshotChangeKind: String, Codable, Sendable {
  case created
  case removed
  case processReplaced
  case orderChanged
  case runtimeMetadataChanged
  case ambiguousInventoryChanged
}

/// Runtime-only grouping for inventory changes that cannot be attributed to a
/// stable item identity. A bundle identifier is preferred; PID is only a
/// fallback for processes that do not expose one.
public struct RuntimeInventoryGroupKey: Codable, Equatable, Hashable, Sendable {
  public let bundleIdentifier: String?
  public let processIdentifierFallback: Int32?

  public init(
    bundleIdentifier: String?,
    processIdentifierFallback: Int32?
  ) {
    precondition(
      bundleIdentifier != nil || processIdentifierFallback != nil,
      "A runtime inventory group needs a bundle identifier or PID."
    )
    self.bundleIdentifier = bundleIdentifier
    self.processIdentifierFallback = processIdentifierFallback
  }

  public var diagnosticDescription: String {
    bundleIdentifier
      ?? processIdentifierFallback.map { "unattributed process \($0)" }
      ?? "unattributed process"
  }
}

public struct SnapshotChange: Codable, Equatable, Sendable {
  public let kind: SnapshotChangeKind
  public let identity: ProvisionalIdentityKey?
  public let runtimeGroup: RuntimeInventoryGroupKey?
  public let previousRuntimeID: String?
  public let currentRuntimeID: String?
  public let previousCount: Int?
  public let currentCount: Int?

  public init(
    kind: SnapshotChangeKind,
    identity: ProvisionalIdentityKey? = nil,
    runtimeGroup: RuntimeInventoryGroupKey? = nil,
    previousRuntimeID: String?,
    currentRuntimeID: String?,
    previousCount: Int? = nil,
    currentCount: Int? = nil
  ) {
    precondition(
      identity != nil || runtimeGroup != nil,
      "A snapshot change needs an identity or runtime group."
    )
    self.kind = kind
    self.identity = identity
    self.runtimeGroup = runtimeGroup
    self.previousRuntimeID = previousRuntimeID
    self.currentRuntimeID = currentRuntimeID
    self.previousCount = previousCount
    self.currentCount = currentCount
  }
}

public struct WatchSample: Codable, Equatable, Sendable {
  public let snapshot: InventorySnapshot
  public let changes: [SnapshotChange]

  public init(snapshot: InventorySnapshot, changes: [SnapshotChange]) {
    self.snapshot = snapshot
    self.changes = changes
  }
}

public struct WatchMetrics: Codable, Equatable, Sendable {
  public let sampleCount: Int
  public let completeSampleCount: Int
  public let incompleteSampleCount: Int
  public let intervalSeconds: Double
  public let averageScanMilliseconds: Double
  public let maximumScanMilliseconds: Double

  public init(
    sampleCount: Int,
    completeSampleCount: Int,
    incompleteSampleCount: Int,
    intervalSeconds: Double,
    averageScanMilliseconds: Double,
    maximumScanMilliseconds: Double
  ) {
    self.sampleCount = sampleCount
    self.completeSampleCount = completeSampleCount
    self.incompleteSampleCount = incompleteSampleCount
    self.intervalSeconds = intervalSeconds
    self.averageScanMilliseconds = averageScanMilliseconds
    self.maximumScanMilliseconds = maximumScanMilliseconds
  }
}

public struct WatchReport: Codable, Equatable, Sendable {
  public let samples: [WatchSample]
  public let metrics: WatchMetrics

  public init(samples: [WatchSample], metrics: WatchMetrics) {
    self.samples = samples
    self.metrics = metrics
  }
}

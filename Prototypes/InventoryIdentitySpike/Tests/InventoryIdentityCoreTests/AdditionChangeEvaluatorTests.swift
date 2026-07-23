import Foundation
import Testing

@testable import InventoryIdentityCore

@Suite("Gate A live addition evaluator")
struct AdditionChangeEvaluatorTests {
  private let evaluator = AdditionChangeEvaluator()

  @Test("Matches a created provisional identity by target bundle")
  func matchesCreatedIdentity() {
    let change = SnapshotChange(
      kind: .created,
      identity: ProvisionalIdentityKey(
        bundleIdentifier: "example.target"
      ),
      previousRuntimeID: nil,
      currentRuntimeID: "100:0"
    )

    #expect(
      evaluator.relevantAddition(
        in: [change],
        targetBundleIdentifier: "example.target"
      ) == change
    )
    #expect(
      evaluator.relevantAddition(
        in: [change],
        targetBundleIdentifier: "example.other"
      ) == nil
    )
  }

  @Test("Returns every matching addition so mutation cannot guess")
  func returnsMultipleMatchingAdditions() {
    let changes = [
      SnapshotChange(
        kind: .created,
        identity: ProvisionalIdentityKey(
          bundleIdentifier: "example.target",
          discriminatorCandidate: "first"
        ),
        previousRuntimeID: nil,
        currentRuntimeID: "100:0"
      ),
      SnapshotChange(
        kind: .created,
        identity: ProvisionalIdentityKey(
          bundleIdentifier: "example.target",
          discriminatorCandidate: "second"
        ),
        previousRuntimeID: nil,
        currentRuntimeID: "100:1"
      ),
    ]

    #expect(
      evaluator.relevantAdditions(
        in: changes,
        targetBundleIdentifier: "example.target"
      ).count == 2
    )
  }

  @Test("Treats only an increasing Ambiguous group count as an addition")
  func matchesAmbiguousCountIncrease() {
    let group = RuntimeInventoryGroupKey(
      bundleIdentifier: "example.target",
      processIdentifierFallback: nil
    )
    let increase = SnapshotChange(
      kind: .ambiguousInventoryChanged,
      runtimeGroup: group,
      previousRuntimeID: nil,
      currentRuntimeID: nil,
      previousCount: 1,
      currentCount: 2
    )
    let replacement = SnapshotChange(
      kind: .ambiguousInventoryChanged,
      runtimeGroup: group,
      previousRuntimeID: nil,
      currentRuntimeID: nil,
      previousCount: 2,
      currentCount: 2
    )

    #expect(
      evaluator.relevantAddition(
        in: [replacement, increase],
        targetBundleIdentifier: "example.target"
      ) == increase
    )
  }

  @Test("Sanitized report contains no target or inventory fields")
  func reportEncodingIsSanitized() throws {
    let report = AdditionValidationReport(
      status: .detected,
      environment: ValidationEnvironment(
        operatingSystem: "macOS test",
        architecture: "arm64"
      ),
      intervalMilliseconds: 250,
      timeoutSeconds: 60,
      completedScanCount: 3,
      completeScanCount: 2,
      incompleteScanCount: 1,
      cannotCompleteApplicationScanCount: 1,
      messagingTimeoutMilliseconds: 200,
      markerToDetectionMilliseconds: 200,
      averageScanMilliseconds: 1,
      maximumScanMilliseconds: 2,
      detectedChangeKind: .created
    )

    let encoded = String(
      decoding: try JSONEncoder().encode(report),
      as: UTF8.self
    )

    #expect(!encoded.contains("bundleIdentifier"))
    #expect(!encoded.contains("items"))
    #expect(!encoded.contains("metadata"))
    #expect(!encoded.contains("geometry"))
    #expect(!encoded.contains("processIdentifier"))
    #expect(!encoded.contains("target"))
    #expect(!encoded.contains("title"))
    #expect(!encoded.contains("label"))
    #expect(!encoded.contains("runtimeID"))
    #expect(!encoded.contains("identity"))
    #expect(encoded.contains("incompleteScanCount"))
    #expect(encoded.contains("cannotCompleteApplicationScanCount"))
    #expect(encoded.contains("messagingTimeoutMilliseconds"))
  }
}

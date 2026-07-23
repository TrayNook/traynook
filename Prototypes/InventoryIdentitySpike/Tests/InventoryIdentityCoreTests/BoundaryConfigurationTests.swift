import Testing

@testable import InventoryIdentityCore

@Suite("Disposable boundary configuration")
struct BoundaryConfigurationTests {
  @Test("Boundary defaults to a collapsed-safe explicit expansion width")
  func usesDefaultWidth() throws {
    let configuration = try BoundaryConfiguration(arguments: ["spike"])

    #expect(
      configuration.expandedWidth
        == BoundaryConfiguration.defaultExpandedWidth
    )
  }

  @Test("Boundary accepts an in-range width")
  func acceptsWidth() throws {
    let configuration = try BoundaryConfiguration(
      arguments: ["spike", "--expanded-width", "650"]
    )

    #expect(configuration.expandedWidth == 650)
  }

  @Test("Live correction requires an explicit target")
  func correctionRequiresTarget() {
    #expect(throws: BoundaryConfigurationError.self) {
      try BoundaryConfiguration(
        targetBundleIdentifier: nil,
        executeCorrection: true
      )
    }
  }

  @Test("Live correction rejects Apple system bundle identifiers")
  func correctionRejectsSystemTarget() {
    #expect(throws: BoundaryConfigurationError.self) {
      try BoundaryConfiguration(
        targetBundleIdentifier: "com.apple.controlcenter",
        executeCorrection: true
      )
    }
  }

  @Test("Correction is dry-run unless explicitly enabled")
  func correctionDefaultsToDryRun() throws {
    let configuration = try BoundaryConfiguration(
      arguments: [
        "spike",
        "--target-bundle-id",
        "example.target",
      ]
    )

    #expect(configuration.targetBundleIdentifier == "example.target")
    #expect(configuration.executeCorrection == false)
    #expect(
      configuration.pollingInterval
        == BoundaryConfiguration.defaultPollingInterval
    )
  }

  @Test(
    "Boundary rejects widths that could be accidental or effectively unbounded",
    arguments: [0.0, 79.0, 2_001.0]
  )
  func rejectsUnsafeWidth(width: Double) {
    #expect(throws: BoundaryConfigurationError.self) {
      try BoundaryConfiguration(expandedWidth: width)
    }
  }
}

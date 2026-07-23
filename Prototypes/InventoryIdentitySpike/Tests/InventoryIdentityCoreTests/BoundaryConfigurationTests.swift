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

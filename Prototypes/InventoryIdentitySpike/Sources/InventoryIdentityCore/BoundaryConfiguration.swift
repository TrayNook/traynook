import Foundation

public struct BoundaryConfiguration: Equatable, Sendable {
  public static let defaultExpandedWidth = 400.0
  public static let allowedExpandedWidth = 80.0...2_000.0

  public let expandedWidth: Double

  public init(expandedWidth: Double = defaultExpandedWidth) throws {
    guard Self.allowedExpandedWidth.contains(expandedWidth) else {
      throw BoundaryConfigurationError(
        "Expanded width must be between "
          + "\(Int(Self.allowedExpandedWidth.lowerBound)) and "
          + "\(Int(Self.allowedExpandedWidth.upperBound)) points."
      )
    }
    self.expandedWidth = expandedWidth
  }

  public init(arguments: [String]) throws {
    var arguments = Array(arguments.dropFirst())
    var expandedWidth = Self.defaultExpandedWidth

    while !arguments.isEmpty {
      let option = arguments.removeFirst()
      switch option {
      case "--expanded-width":
        guard
          let rawValue = arguments.first,
          let value = Double(rawValue)
        else {
          throw BoundaryConfigurationError(
            "--expanded-width requires a numeric value."
          )
        }
        arguments.removeFirst()
        expandedWidth = value

      default:
        throw BoundaryConfigurationError("Unknown option: \(option)")
      }
    }

    try self.init(expandedWidth: expandedWidth)
  }
}

public struct BoundaryConfigurationError: Error, Equatable,
  CustomStringConvertible
{
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

import Foundation

public struct BoundaryConfiguration: Equatable, Sendable {
  public static let defaultExpandedWidth = 400.0
  public static let allowedExpandedWidth = 80.0...2_000.0
  public static let defaultPollingInterval = 0.25
  public static let allowedPollingInterval = 0.1...5.0

  public let expandedWidth: Double
  public let targetBundleIdentifier: String?
  public let executeCorrection: Bool
  public let pollingInterval: Double

  public init(
    expandedWidth: Double = defaultExpandedWidth,
    targetBundleIdentifier: String? = nil,
    executeCorrection: Bool = false,
    pollingInterval: Double = defaultPollingInterval
  ) throws {
    guard Self.allowedExpandedWidth.contains(expandedWidth) else {
      throw BoundaryConfigurationError(
        "Expanded width must be between "
          + "\(Int(Self.allowedExpandedWidth.lowerBound)) and "
          + "\(Int(Self.allowedExpandedWidth.upperBound)) points."
      )
    }
    guard Self.allowedPollingInterval.contains(pollingInterval) else {
      throw BoundaryConfigurationError(
        "Polling interval must be between "
          + "\(Self.allowedPollingInterval.lowerBound) and "
          + "\(Self.allowedPollingInterval.upperBound) seconds."
      )
    }
    let targetBundleIdentifier = targetBundleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard targetBundleIdentifier?.isEmpty != true else {
      throw BoundaryConfigurationError(
        "--target-bundle-id cannot be empty."
      )
    }
    guard !executeCorrection || targetBundleIdentifier != nil else {
      throw BoundaryConfigurationError(
        "--execute-correction requires --target-bundle-id."
      )
    }
    guard
      !executeCorrection
        || targetBundleIdentifier?.hasPrefix("com.apple.") != true
    else {
      throw BoundaryConfigurationError(
        "Live correction rejects Apple system bundle identifiers."
      )
    }
    self.expandedWidth = expandedWidth
    self.targetBundleIdentifier = targetBundleIdentifier
    self.executeCorrection = executeCorrection
    self.pollingInterval = pollingInterval
  }

  public init(arguments: [String]) throws {
    var arguments = Array(arguments.dropFirst())
    var expandedWidth = Self.defaultExpandedWidth
    var targetBundleIdentifier: String?
    var executeCorrection = false
    var pollingInterval = Self.defaultPollingInterval

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

      case "--target-bundle-id":
        guard let value = arguments.first else {
          throw BoundaryConfigurationError(
            "--target-bundle-id requires a value."
          )
        }
        arguments.removeFirst()
        targetBundleIdentifier = value

      case "--execute-correction":
        executeCorrection = true

      case "--poll-interval":
        guard
          let rawValue = arguments.first,
          let value = Double(rawValue)
        else {
          throw BoundaryConfigurationError(
            "--poll-interval requires a numeric value."
          )
        }
        arguments.removeFirst()
        pollingInterval = value

      default:
        throw BoundaryConfigurationError("Unknown option: \(option)")
      }
    }

    try self.init(
      expandedWidth: expandedWidth,
      targetBundleIdentifier: targetBundleIdentifier,
      executeCorrection: executeCorrection,
      pollingInterval: pollingInterval
    )
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

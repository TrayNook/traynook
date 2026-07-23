import Foundation
import InventoryIdentityCore

private enum Command {
  case scan
  case watch
  case help
}

private struct Options {
  var command: Command = .scan
  var formatJSON = false
  var promptForPermission = false
  var sampleCount = 5
  var intervalSeconds = 1.0

  init(arguments: [String]) throws {
    var arguments = Array(arguments.dropFirst())

    if let first = arguments.first, !first.hasPrefix("-") {
      arguments.removeFirst()
      switch first {
      case "scan":
        command = .scan
      case "watch":
        command = .watch
      case "help":
        command = .help
      default:
        throw OptionError("Unknown command: \(first)")
      }
    }

    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      switch argument {
      case "--json":
        formatJSON = true
      case "--prompt":
        promptForPermission = true
      case "--samples":
        sampleCount = try Self.consumeInteger(
          option: argument,
          arguments: &arguments
        )
        guard sampleCount > 0 else {
          throw OptionError("--samples must be greater than zero.")
        }
      case "--interval":
        intervalSeconds = try Self.consumeDouble(
          option: argument,
          arguments: &arguments
        )
        guard intervalSeconds >= 0 else {
          throw OptionError("--interval cannot be negative.")
        }
      case "--help", "-h":
        command = .help
      default:
        throw OptionError("Unknown option: \(argument)")
      }
    }
  }

  private static func consumeInteger(
    option: String,
    arguments: inout [String]
  ) throws -> Int {
    guard let rawValue = arguments.first, let value = Int(rawValue) else {
      throw OptionError("\(option) requires an integer value.")
    }
    arguments.removeFirst()
    return value
  }

  private static func consumeDouble(
    option: String,
    arguments: inout [String]
  ) throws -> Double {
    guard let rawValue = arguments.first, let value = Double(rawValue) else {
      throw OptionError("\(option) requires a numeric value.")
    }
    arguments.removeFirst()
    return value
  }
}

private struct OptionError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

@main
private enum InventoryIdentitySpike {
  static func main() {
    do {
      let options = try Options(arguments: CommandLine.arguments)

      switch options.command {
      case .scan:
        let snapshot = AccessibilityInventoryScanner().scan(
          promptForPermission: options.promptForPermission
        )
        try output(snapshot, asJSON: options.formatJSON)
        if snapshot.permission == .denied {
          Foundation.exit(EXIT_FAILURE)
        }

      case .watch:
        let report = InventoryMonitor().watch(
          sampleCount: options.sampleCount,
          intervalSeconds: options.intervalSeconds,
          promptForPermission: options.promptForPermission
        )
        try output(report, asJSON: options.formatJSON)
        if report.samples.last?.snapshot.permission == .denied {
          Foundation.exit(EXIT_FAILURE)
        }

      case .help:
        printUsage()
      }
    } catch {
      FileHandle.standardError.write(
        Data("error: \(error)\n\n".utf8)
      )
      printUsage()
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func output(
    _ snapshot: InventorySnapshot,
    asJSON: Bool
  ) throws {
    if asJSON {
      print(try json(snapshot))
      return
    }

    print("Accessibility: \(snapshot.permission.rawValue)")
    print(
      "Inspected \(snapshot.metrics.inspectedApplicationCount) applications; "
        + "found \(snapshot.metrics.sourceItemCount) Source Items in "
        + String(format: "%.2f ms.", snapshot.metrics.durationMilliseconds)
    )

    for warning in snapshot.warnings {
      print("Warning: \(warning)")
    }

    for item in snapshot.items {
      let observation = item.observation
      let app =
        observation.applicationName
        ?? observation.bundleIdentifier
        ?? "Unknown application"
      let frame =
        observation.frame.map {
          "x=\(Int($0.x)) y=\(Int($0.y)) w=\(Int($0.width)) h=\(Int($0.height))"
        } ?? "no frame"
      let identity =
        item.identity.provisionalKey?.diagnosticDescription
        ?? "ambiguous"

      print(
        "[\(observation.observedOrder)] \(app) — \(frame)"
          + " — identity: \(identity) [\(item.identity.status.rawValue)]"
          + " — capability: \(item.manageability.status.rawValue)"
      )
    }
  }

  private static func output(
    _ report: WatchReport,
    asJSON: Bool
  ) throws {
    if asJSON {
      print(try json(report))
      return
    }

    for (index, sample) in report.samples.enumerated() {
      let metrics = sample.snapshot.metrics
      print(
        "Sample \(index + 1): \(metrics.sourceItemCount) items, "
          + String(format: "%.2f ms", metrics.durationMilliseconds)
      )
      for change in sample.changes {
        let subject =
          change.identity?.diagnosticDescription
          ?? change.runtimeGroup?.diagnosticDescription
          ?? "unknown inventory group"
        let countChange =
          if let previousCount = change.previousCount,
            let currentCount = change.currentCount
          {
            " (\(previousCount) → \(currentCount) items)"
          } else {
            ""
          }
        print(
          "  \(change.kind.rawValue): "
            + subject
            + countChange
        )
      }
    }

    print(
      "Average scan: "
        + String(format: "%.2f ms", report.metrics.averageScanMilliseconds)
        + "; maximum: "
        + String(format: "%.2f ms", report.metrics.maximumScanMilliseconds)
    )
  }

  private static func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private static func printUsage() {
    print(
      """
      TrayNook Gate A inventory and identity spike

      Usage:
        traynook-inventory-spike scan [--json] [--prompt]
        traynook-inventory-spike watch [--samples N] [--interval SECONDS] [--json] [--prompt]

      --prompt asks macOS to show the Accessibility permission prompt.
      Without it, the spike only reads the current permission state.
      The command writes no inventory, titles, identifiers, or pixels to disk.
      """
    )
  }
}

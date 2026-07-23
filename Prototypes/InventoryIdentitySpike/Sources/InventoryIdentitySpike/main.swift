import Darwin
import Foundation
import InventoryIdentityCore

private enum Command {
  case scan
  case watch
  case validateAddition
  case help
}

private struct Options {
  var command: Command = .scan
  var formatJSON = false
  var promptForPermission = false
  var sampleCount = 5
  var intervalSeconds = 1.0
  var timeoutSeconds = 60.0
  var messagingTimeoutSeconds =
    AccessibilityInventoryTuning.defaultMessagingTimeoutSeconds
  var targetBundleIdentifier: String?

  init(arguments: [String]) throws {
    var arguments = Array(arguments.dropFirst())

    if let first = arguments.first, !first.hasPrefix("-") {
      arguments.removeFirst()
      switch first {
      case "scan":
        command = .scan
      case "watch":
        command = .watch
      case "validate-addition":
        command = .validateAddition
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
      case "--timeout":
        timeoutSeconds = try Self.consumeDouble(
          option: argument,
          arguments: &arguments
        )
        guard timeoutSeconds > 0 else {
          throw OptionError("--timeout must be greater than zero.")
        }
      case "--ax-timeout":
        messagingTimeoutSeconds = try Self.consumeDouble(
          option: argument,
          arguments: &arguments
        )
        let minimum =
          AccessibilityInventoryTuning.minimumMessagingTimeoutSeconds
        let maximum =
          AccessibilityInventoryTuning.maximumMessagingTimeoutSeconds
        guard
          messagingTimeoutSeconds >= minimum,
          messagingTimeoutSeconds <= maximum
        else {
          throw OptionError(
            "--ax-timeout must be from "
              + "\(minimum) through \(maximum) seconds."
          )
        }
      case "--bundle-id":
        targetBundleIdentifier = try Self.consumeString(
          option: argument,
          arguments: &arguments
        ).trimmingCharacters(in: .whitespacesAndNewlines)
      case "--help", "-h":
        command = .help
      default:
        throw OptionError("Unknown option: \(argument)")
      }
    }

    if case .validateAddition = command {
      guard
        let targetBundleIdentifier,
        !targetBundleIdentifier.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else {
        throw OptionError(
          "validate-addition requires --bundle-id for an explicitly "
            + "selected target."
        )
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

  private static func consumeString(
    option: String,
    arguments: inout [String]
  ) throws -> String {
    guard let value = arguments.first, !value.isEmpty else {
      throw OptionError("\(option) requires a value.")
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

private final class SignalMarker: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64?

  func mark() {
    lock.lock()
    defer { lock.unlock() }
    guard value == nil else {
      return
    }
    value = DispatchTime.now().uptimeNanoseconds
  }

  func read() -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    value = nil
  }
}

@main
private enum InventoryIdentitySpike {
  static func main() {
    do {
      let options = try Options(arguments: CommandLine.arguments)
      let scanner = AccessibilityInventoryScanner(
        messagingTimeoutSeconds: options.messagingTimeoutSeconds
      )

      switch options.command {
      case .scan:
        let snapshot = scanner.scan(
          promptForPermission: options.promptForPermission
        )
        try output(snapshot, asJSON: options.formatJSON)
        if snapshot.permission == .denied
          || snapshot.completeness == .incomplete
        {
          Foundation.exit(EXIT_FAILURE)
        }

      case .watch:
        let report = InventoryMonitor(scanner: scanner).watch(
          sampleCount: options.sampleCount,
          intervalSeconds: options.intervalSeconds,
          promptForPermission: options.promptForPermission
        )
        try output(report, asJSON: options.formatJSON)
        if report.samples.contains(where: {
          $0.snapshot.permission == .denied
            || $0.snapshot.completeness == .incomplete
        }) {
          Foundation.exit(EXIT_FAILURE)
        }

      case .validateAddition:
        guard options.intervalSeconds > 0 else {
          throw OptionError(
            "--interval must be greater than zero for validate-addition."
          )
        }
        let marker = SignalMarker()
        Darwin.signal(SIGUSR1, SIG_IGN)
        var signalSource: DispatchSourceSignal?
        defer { signalSource?.cancel() }

        let report = AdditionValidationRunner(scanner: scanner).run(
          intervalSeconds: options.intervalSeconds,
          timeoutSeconds: options.timeoutSeconds,
          targetBundleIdentifier: options.targetBundleIdentifier,
          promptForPermission: options.promptForPermission,
          markerUptimeNanoseconds: marker.read,
          onArmed: {
            marker.reset()
            let armedSignalSource = DispatchSource.makeSignalSource(
              signal: SIGUSR1,
              queue: DispatchQueue.global(qos: .userInitiated)
            )
            armedSignalSource.setEventHandler {
              marker.mark()
            }
            armedSignalSource.resume()
            signalSource = armedSignalSource
            writeToStandardError(
              """
              Complete baseline acquired. Validation armed.
              Immediately before creating the Source Item, run:
                kill -USR1 \(ProcessInfo.processInfo.processIdentifier)
              Waiting up to \(String(format: "%.1f", options.timeoutSeconds)) seconds for the marker,
              then the same duration for a matching addition.

              """
            )
          }
        )
        try output(report, asJSON: options.formatJSON)
        if report.status != .detected {
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
    print(
      "Inventory: \(snapshot.completeness.rawValue); "
        + "\(snapshot.metrics.incompleteApplicationCount) incomplete "
        + "applications, "
        + "\(snapshot.metrics.cannotCompleteApplicationCount) could not "
        + "complete; "
        + "slowest application "
        + String(
          format: "%.2f ms; per-message timeout %.0f ms.",
          snapshot.metrics.maximumApplicationScanMilliseconds,
          snapshot.metrics.messagingTimeoutMilliseconds
        )
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
    _ report: AdditionValidationReport,
    asJSON: Bool
  ) throws {
    if asJSON {
      print(try json(report))
      return
    }

    print("Scenario: \(report.scenario)")
    print("Result: \(report.status.rawValue)")
    print(
      "Environment: \(report.environment.operatingSystem), "
        + report.environment.architecture
    )
    print(
      "Polling: \(Int(report.intervalMilliseconds)) ms; "
        + "\(report.completedScanCount) completed scans"
    )
    print(
      "Complete scans: \(report.completeScanCount); incomplete: "
        + "\(report.incompleteScanCount); application-scans affected by "
        + "cannotComplete: \(report.cannotCompleteApplicationScanCount); "
        + String(
          format: "per-message timeout: %.0f ms",
          report.messagingTimeoutMilliseconds
        )
    )
    print(
      "Average scan: "
        + String(format: "%.2f ms", report.averageScanMilliseconds)
        + "; maximum: "
        + String(format: "%.2f ms", report.maximumScanMilliseconds)
    )
    if let latency = report.markerToDetectionMilliseconds {
      print(
        "Marker-to-detection upper bound: "
          + String(format: "%.2f ms", latency)
      )
    }
    if let changeKind = report.detectedChangeKind {
      print("Detected change: \(changeKind.rawValue)")
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
          + ", \(sample.snapshot.completeness.rawValue)"
          + ", \(metrics.incompleteApplicationCount) incomplete applications"
          + ", \(metrics.cannotCompleteApplicationCount) applications affected "
          + "by cannotComplete"
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
    print(
      "Complete samples: \(report.metrics.completeSampleCount); incomplete: "
        + "\(report.metrics.incompleteSampleCount)"
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
        traynook-inventory-spike scan [--json] [--prompt] [--ax-timeout SECONDS]
        traynook-inventory-spike watch [--samples N] [--interval SECONDS]
          [--json] [--prompt] [--ax-timeout SECONDS]
        traynook-inventory-spike validate-addition --bundle-id ID
          [--interval SECONDS] [--timeout SECONDS] [--json] [--prompt]
          [--ax-timeout SECONDS]

      --prompt asks macOS to show the Accessibility permission prompt.
      --ax-timeout bounds each synchronous Accessibility message; accepted
      range is 0.01 through 2.0 seconds and the default is 0.2 seconds.
      Calls that cannot complete make the scan incomplete; incomplete scans
      never drive change detection.
      Without --prompt, the spike only reads the current permission state.
      The command writes no inventory, titles, identifiers, or pixels to disk.
      """
    )
  }

  private static func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
  }
}

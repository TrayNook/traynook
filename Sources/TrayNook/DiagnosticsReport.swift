import Foundation

struct DiagnosticsReport: Equatable {
  enum Reason: String {
    case userReveal, environmentChange, inventoryUnavailable, geometryUnavailable, identityReview, operationFailure
  }

  struct Event: Equatable {
    let reason: Reason
    let timestamp: Date
    var failure: String? = nil
    var affectedBundles: [String] = []
  }

  struct Repair: Equatable {
    let bundleIdentifier: String?
    let attempts: Int
    let notBefore: Date
  }

  var version = "development"
  var build = "0"
  var macOS = "unknown"
  var permissionGranted = false
  var scanComplete = false
  var recoveryRequired = false
  var concealed = false
  var screenRecordingGranted = false
  var lastReveal: Event?
  var reapplyNotBefore: Date?
  var recoveringLayout = false
  var busy = false
  var scanning = false
  var nativeBusy = false
  var incompleteScans = 0
  var unsafeScans = 0
  var hasPendingActivation = false
  var pendingActivationBundle: String?
  var panelWatch = false
  var dropdownShown = false
  var pendingPlacementCount = 0
  var automaticPlacementCount = 0
  var pendingPlacementBundles: [String] = []
  var automaticPlacementBundles: [String] = []
  var hiddenSourceRepairs: [Repair] = []

  var text: String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func timestamp(_ date: Date?) -> String { date.map(formatter.string(from:)) ?? "none" }
    func bundles(_ values: [String]) -> String {
      let sorted = Set(values.filter { !$0.isEmpty }).sorted()
      return sorted.isEmpty ? "none" : sorted.joined(separator: ", ")
    }
    let repairs = hiddenSourceRepairs.map { repair in
      "  \(repair.bundleIdentifier ?? "unknown"): attempts=\(repair.attempts)/3, exhausted=\(repair.attempts >= 3), notBefore=\(timestamp(repair.notBefore == .distantPast ? nil : repair.notBefore))"
    }.sorted()
    return """
    TrayNook \(version) (\(build))
    macOS \(macOS)
    Accessibility: \(permissionGranted)
    Inventory complete: \(scanComplete)
    Layout recovery: \(recoveryRequired)
    Native section concealed: \(concealed)
    Private APIs: none
    Screen Recording: \(screenRecordingGranted)
    Proxy imagery: \(screenRecordingGranted ? "captured menu-bar items" : "app icons")
    Last reveal/recovery reason: \(lastReveal?.reason.rawValue ?? "none")
    Last reveal/recovery at: \(timestamp(lastReveal?.timestamp))
    Last failure: \(lastReveal?.failure ?? "none")
    Affected sources: \(bundles(lastReveal?.affectedBundles ?? []))
    reapplyNotBefore: \(timestamp(reapplyNotBefore))
    recoveringLayout: \(recoveringLayout)
    busy: \(busy)
    scanning: \(scanning)
    nativeBusy: \(nativeBusy)
    incompleteScans: \(incompleteScans)
    unsafeScans: \(unsafeScans)
    hasPendingActivation: \(hasPendingActivation)
    Pending return source: \(hasPendingActivation ? pendingActivationBundle ?? "unknown" : "none")
    panelWatch: \(panelWatch)
    dropdownShown: \(dropdownShown)
    pendingPlacementKeys: \(pendingPlacementCount)
    automaticPlacementKeys: \(automaticPlacementCount)
    Pending placement sources: \(bundles(pendingPlacementBundles))
    Automatic placement sources: \(bundles(automaticPlacementBundles))
    Hidden source repairs: \(repairs.isEmpty ? "none" : "\n" + repairs.joined(separator: "\n"))
    Affected-app bundle identifiers only; no full app inventory, item labels, window titles, or images.
    """
  }
}

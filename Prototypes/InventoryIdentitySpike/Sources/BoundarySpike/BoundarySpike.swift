import AppKit
import CoreGraphics
import InventoryIdentityCore

private struct BoundaryEnvironment: Equatable {
  let displayIdentifier: UInt32
  let safeMenuBarFrame: ItemFrame
  let boundaryFrame: ItemFrame
  let launcherFrame: ItemFrame

  var generation: BoundaryGeneration {
    BoundaryGeneration(
      displayIdentifier: displayIdentifier,
      safeMenuBarFrame: safeMenuBarFrame
    )
  }

  var armState: BoundaryArmState {
    BoundaryArmState(
      generation: generation,
      boundaryFrame: boundaryFrame,
      launcherFrame: launcherFrame
    )
  }
}

private struct BoundaryGeneration: Equatable {
  let displayIdentifier: UInt32
  let safeMenuBarFrame: ItemFrame
}

private struct BoundaryArmState: Equatable {
  let generation: BoundaryGeneration
  let boundaryFrame: ItemFrame
  let launcherFrame: ItemFrame
}

private struct PreparationSnapshot: Equatable {
  let processIdentifier: Int32
  let targetFrame: ItemFrame
  let normalizedOrder: [ProvisionalIdentityKey]
  let boundaryGeneration: BoundaryGeneration
  let boundaryFrame: ItemFrame
}

private struct ReconciliationSnapshot: Equatable {
  let processIdentifier: Int32
  let targetFrame: ItemFrame
  let normalizedOrder: [ProvisionalIdentityKey]
  let boundaryGeneration: BoundaryGeneration
  let boundaryFrame: ItemFrame
}

private enum ReconciliationPhase {
  case collapsed
  case reexpanded
}

@MainActor
private final class BoundaryAppDelegate: NSObject, NSApplicationDelegate,
  NSMenuDelegate
{
  private let configuration: BoundaryConfiguration
  private let expandedWidth: CGFloat
  private let statusBar = NSStatusBar.system
  private let scanner = AccessibilityInventoryScanner()
  private let differ = SnapshotDiffer()
  private let additionEvaluator = AdditionChangeEvaluator()
  private let correctionPlanner = SafeDefaultCorrectionPlanner()
  private let eventPoster = QuartzCommandDragPoster()
  private var launcher: NSStatusItem?
  private var boundary: NSStatusItem?
  private var toggleItems: [NSMenuItem] = []
  private var correctionItems: [NSMenuItem] = []
  private var isExpanded = false
  private var correctionTimer: Timer?
  private var scheduledOneShotTimers: [Timer] = []
  private var armDeadlineUptimeNanoseconds: UInt64?
  private var armedBoundaryState: BoundaryArmState?
  private var previousItems: [ClassifiedSourceItem]?
  private var pendingIdentity: ProvisionalIdentityKey?
  private var pendingProcessIdentifier: Int32?
  private var preMutationOrder: [ProvisionalIdentityKey] = []
  private var lastPreparationSnapshot: PreparationSnapshot?
  private var stablePreparationCount = 0
  private var preparationSampleCount = 0
  private var expectedBoundaryGeneration: BoundaryGeneration?
  private var reconciliationPhase: ReconciliationPhase = .collapsed
  private var lastReconciliationSnapshot: ReconciliationSnapshot?
  private var stableReconciliationCount = 0
  private var reconciliationSampleCount = 0
  private var observersInstalled = false

  init(configuration: BoundaryConfiguration) {
    self.configuration = configuration
    expandedWidth = configuration.expandedWidth
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installStatusItems()
    installEnvironmentObservers()
  }

  func applicationWillTerminate(_ notification: Notification) {
    removeStatusItems()
  }

  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    removeStatusItems()
    return .terminateNow
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    refreshToggleItems()
  }

  private func installEnvironmentObservers() {
    guard !observersInstalled else {
      return
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(environmentWillChange),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(environmentWillChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    observersInstalled = true
  }

  private func removeEnvironmentObservers() {
    guard observersInstalled else {
      return
    }
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
    observersInstalled = false
  }

  @objc private func environmentWillChange(_ notification: Notification) {
    if correctionTimer != nil || pendingIdentity != nil {
      failVisible("environment_changed")
    } else {
      setBoundaryExpanded(false)
    }
  }

  private func installStatusItems() {
    let boundary = statusBar.statusItem(
      withLength: NSStatusItem.squareLength
    )
    boundary.button?.title = "│"
    boundary.button?.toolTip = "TrayNook prototype boundary"
    boundary.button?.setAccessibilityLabel(
      "TrayNook prototype boundary"
    )
    boundary.menu = makeMenu()
    self.boundary = boundary

    let launcher = statusBar.statusItem(
      withLength: NSStatusItem.squareLength
    )
    if let image = NSImage(
      systemSymbolName: "tray.full",
      accessibilityDescription: "TrayNook boundary prototype"
    ) {
      image.isTemplate = true
      launcher.button?.image = image
    } else {
      launcher.button?.title = "TN"
    }
    launcher.button?.toolTip = "TrayNook boundary prototype"
    launcher.button?.setAccessibilityLabel(
      "TrayNook boundary prototype"
    )
    launcher.menu = makeMenu()
    self.launcher = launcher
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    let toggle = NSMenuItem(
      title: "Expand Boundary",
      action: #selector(toggleBoundary),
      keyEquivalent: ""
    )
    toggle.target = self
    menu.addItem(toggle)
    toggleItems.append(toggle)

    if configuration.targetBundleIdentifier != nil {
      let correction = NSMenuItem(
        title: "Arm Safe-Default Dry Run",
        action: #selector(armCorrection),
        keyEquivalent: ""
      )
      correction.target = self
      menu.addItem(correction)
      correctionItems.append(correction)
    }

    menu.addItem(.separator())

    let quit = NSMenuItem(
      title: "Quit Boundary Prototype",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quit.target = self
    menu.addItem(quit)
    return menu
  }

  @objc private func toggleBoundary() {
    guard boundary != nil else {
      return
    }

    if correctionTimer != nil || pendingIdentity != nil {
      failVisible("user_preempted")
      return
    }

    guard isExpanded || launcherIsOnVerifiedSafeSide else {
      NSSound.beep()
      return
    }

    setBoundaryExpanded(!isExpanded)
  }

  private var launcherIsOnVerifiedSafeSide: Bool {
    guard
      let boundaryWindow = boundary?.button?.window,
      let launcherWindow = launcher?.button?.window,
      let boundaryScreen = boundaryWindow.screen,
      let launcherScreen = launcherWindow.screen,
      boundaryScreen === launcherScreen
    else {
      return false
    }

    let boundaryFrame = boundaryWindow.frame
    let launcherFrame = launcherWindow.frame
    guard
      !boundaryFrame.isEmpty,
      !boundaryFrame.isNull,
      boundaryFrame.minX.isFinite,
      boundaryFrame.maxX.isFinite,
      !launcherFrame.isEmpty,
      !launcherFrame.isNull,
      launcherFrame.minX.isFinite,
      launcherFrame.maxX.isFinite
    else {
      return false
    }
    return launcherFrame.minX >= boundaryFrame.maxX
  }

  private func refreshToggleItems() {
    let canExpand = launcherIsOnVerifiedSafeSide
    for toggleItem in toggleItems {
      if isExpanded {
        toggleItem.title = "Collapse Boundary"
        toggleItem.isEnabled = true
      } else if canExpand {
        toggleItem.title = "Expand Boundary"
        toggleItem.isEnabled = true
      } else {
        toggleItem.title = "Move Launcher Right of Boundary First"
        toggleItem.isEnabled = false
      }
    }

    let correctionIsArmed =
      correctionTimer != nil
      || pendingIdentity != nil
    for correctionItem in correctionItems {
      if correctionIsArmed {
        correctionItem.title = "Cancel Safe-Default Correction"
        correctionItem.isEnabled = true
      } else {
        correctionItem.title =
          configuration.executeCorrection
          ? "Arm One Live Safe-Default Correction"
          : "Arm Safe-Default Dry Run"
        correctionItem.isEnabled =
          isExpanded && launcherIsOnVerifiedSafeSide
      }
    }
  }

  private func setBoundaryExpanded(_ expanded: Bool) {
    guard let boundary else {
      return
    }
    guard !expanded || launcherIsOnVerifiedSafeSide else {
      NSSound.beep()
      return
    }

    isExpanded = expanded
    boundary.length =
      expanded ? expandedWidth : NSStatusItem.squareLength
    refreshToggleItems()

    if expanded {
      Task { @MainActor [weak self] in
        await Task.yield()
        self?.verifyLauncherRemainedVisible()
      }
    }
  }

  private func verifyLauncherRemainedVisible() {
    guard isExpanded else {
      return
    }
    guard let environment = boundaryEnvironment(),
      expandedEnvironmentIsSafe(environment)
    else {
      if pendingIdentity != nil {
        failVisible("launcher_not_safe_after_expansion")
      } else {
        boundary?.length = NSStatusItem.squareLength
        isExpanded = false
        refreshToggleItems()
        NSSound.beep()
      }
      return
    }
  }

  private func expandedEnvironmentIsSafe(
    _ environment: BoundaryEnvironment
  ) -> Bool {
    isExpanded
      && abs((boundary?.length ?? 0) - expandedWidth) < 0.5
      && environment.safeMenuBarFrame.contains(
        environment.boundaryFrame
      )
      && environment.safeMenuBarFrame.contains(
        environment.launcherFrame
      )
      && environment.launcherFrame.minX
        >= environment.boundaryFrame.maxX
  }

  private func isUsable(_ frame: CGRect) -> Bool {
    !frame.isEmpty
      && !frame.isNull
      && frame.minX.isFinite
      && frame.maxX.isFinite
      && frame.minY.isFinite
      && frame.maxY.isFinite
  }

  @objc private func armCorrection() {
    if correctionTimer != nil || pendingIdentity != nil {
      failVisible("user_cancelled")
      return
    }

    guard
      isExpanded,
      let targetBundleIdentifier =
        configuration.targetBundleIdentifier,
      let environment = boundaryEnvironment()
    else {
      NSSound.beep()
      return
    }

    let baseline = scanner.scan()
    guard baseline.permission == .granted else {
      writeDiagnostic("correction_not_armed:accessibility_denied")
      NSSound.beep()
      return
    }

    previousItems = baseline.items
    let now = DispatchTime.now().uptimeNanoseconds
    armDeadlineUptimeNanoseconds =
      now
      + UInt64(
        SafeDefaultCorrectionTuning.armTimeoutSeconds
          * 1_000_000_000
      )
    armedBoundaryState = environment.armState
    let timer = Timer(
      timeInterval: configuration.pollingInterval,
      target: self,
      selector: #selector(pollForTargetAddition),
      userInfo: targetBundleIdentifier,
      repeats: true
    )
    RunLoop.main.add(timer, forMode: .common)
    correctionTimer = timer
    refreshToggleItems()
    writeDiagnostic(
      configuration.executeCorrection
        ? "correction_armed:live"
        : "correction_armed:dry_run"
    )
  }

  @objc private func pollForTargetAddition(_ timer: Timer) {
    guard
      let targetBundleIdentifier = timer.userInfo as? String,
      let previousItems,
      let armDeadlineUptimeNanoseconds,
      let armedBoundaryState
    else {
      failVisible("invalid_monitor_state")
      return
    }
    guard
      DispatchTime.now().uptimeNanoseconds
        < armDeadlineUptimeNanoseconds
    else {
      failVisible("arm_expired")
      return
    }
    guard
      boundaryEnvironment()?.armState == armedBoundaryState
    else {
      failVisible("environment_changed_while_armed")
      return
    }

    let current = scanner.scan()
    guard current.permission == .granted else {
      failVisible("accessibility_lost")
      return
    }

    let changes = differ.changes(
      from: previousItems,
      to: current.items
    )
    self.previousItems = current.items
    let additions = additionEvaluator.relevantAdditions(
      in: changes,
      targetBundleIdentifier: targetBundleIdentifier
    )
    guard !additions.isEmpty else {
      return
    }

    correctionTimer?.invalidate()
    correctionTimer = nil

    guard configuration.executeCorrection else {
      writeDiagnostic(
        additions.count != 1 || additions[0].identity == nil
          ? "dry_run_detected:ambiguous_not_mutable"
          : "dry_run_detected:unique_candidate"
      )
      resetCorrectionState()
      return
    }

    guard
      additions.count == 1,
      additions[0].kind == .created,
      let identity = additions[0].identity
    else {
      failVisible("multiple_or_ambiguous_targets")
      return
    }

    pendingIdentity = identity
    setBoundaryExpanded(false)
    lastPreparationSnapshot = nil
    stablePreparationCount = 0
    preparationSampleCount = 0
    scheduleOnce(
      #selector(preparePendingCorrection),
      after:
        SafeDefaultCorrectionTuning.reconciliationIntervalSeconds
    )
  }

  @objc private func preparePendingCorrection() {
    guard let pendingIdentity else {
      failVisible("missing_pending_identity")
      return
    }
    guard operationDeadlineIsValid else {
      failVisible("operation_expired")
      return
    }

    let rebound = scanner.scan()
    guard rebound.permission == .granted else {
      failVisible("accessibility_lost")
      return
    }
    guard
      let environment = boundaryEnvironment()
    else {
      failVisible("environment_geometry_unavailable")
      return
    }

    let matches = rebound.items.filter {
      $0.identity.provisionalKey == pendingIdentity
    }
    guard matches.count == 1, let target = matches.first,
      let targetFrame = target.observation.frame
    else {
      failVisible("target_not_unique")
      return
    }

    preparationSampleCount += 1
    let preparation = PreparationSnapshot(
      processIdentifier: target.observation.processIdentifier,
      targetFrame: targetFrame,
      normalizedOrder: normalizedOrder(
        rebound.items,
        excluding: nil
      ),
      boundaryGeneration: environment.generation,
      boundaryFrame: environment.boundaryFrame
    )
    if preparation == lastPreparationSnapshot {
      stablePreparationCount += 1
    } else {
      lastPreparationSnapshot = preparation
      stablePreparationCount = 1
    }

    guard
      stablePreparationCount
        >= SafeDefaultCorrectionTuning.requiredStableSnapshots
    else {
      guard
        preparationSampleCount
          < SafeDefaultCorrectionTuning.maximumReconciliationSamples
      else {
        failVisible("preparation_timed_out")
        return
      }
      scheduleOnce(
        #selector(preparePendingCorrection),
        after:
          SafeDefaultCorrectionTuning.reconciliationIntervalSeconds
      )
      return
    }

    do {
      let disposition = try correctionPlanner.plan(
        target: pendingIdentity,
        in: rebound.items,
        boundaryFrame: environment.boundaryFrame,
        launcherFrame: environment.launcherFrame,
        safeMenuBarFrame: environment.safeMenuBarFrame
      )

      pendingProcessIdentifier =
        target.observation.processIdentifier
      preMutationOrder = normalizedOrder(
        rebound.items,
        excluding: pendingIdentity
      )
      expectedBoundaryGeneration = environment.generation

      if case .move(let plan) = disposition {
        guard operationDeadlineIsValid else {
          failVisible("operation_expired")
          return
        }
        guard eventPoster.physicalInputIsIdle() else {
          failVisible("physical_input_active")
          return
        }
        try eventPoster.post(plan)
      }

      beginReconciliation()
    } catch {
      failVisible("movement_plan_or_event_failed")
    }
  }

  private func beginReconciliation() {
    reconciliationPhase = .collapsed
    lastReconciliationSnapshot = nil
    stableReconciliationCount = 0
    reconciliationSampleCount = 0
    scheduleOnce(
      #selector(reconcilePendingCorrection),
      after:
        SafeDefaultCorrectionTuning.reconciliationIntervalSeconds
    )
  }

  @objc private func reconcilePendingCorrection() {
    guard operationDeadlineIsValid else {
      failVisible("operation_expired")
      return
    }
    guard
      let pendingIdentity,
      let pendingProcessIdentifier,
      let expectedBoundaryGeneration
    else {
      failVisible("missing_reconciliation_state")
      return
    }

    reconciliationSampleCount += 1
    let snapshot = scanner.scan()
    guard snapshot.permission == .granted else {
      failVisible("accessibility_lost")
      return
    }

    let matches = snapshot.items.filter {
      $0.identity.provisionalKey == pendingIdentity
    }
    guard matches.count == 1, let target = matches.first else {
      failVisible("target_vanished_or_ambiguous")
      return
    }
    guard
      target.observation.processIdentifier
        == pendingProcessIdentifier
    else {
      failVisible("source_process_replaced")
      return
    }
    guard
      let targetFrame = target.observation.frame,
      let environment = boundaryEnvironment(),
      environment.generation == expectedBoundaryGeneration,
      environment.safeMenuBarFrame.contains(
        environment.boundaryFrame
      ),
      environment.safeMenuBarFrame.contains(
        environment.launcherFrame
      ),
      environment.safeMenuBarFrame.contains(targetFrame),
      targetFrame.midX >= environment.boundaryFrame.maxX,
      launcherIsOnVerifiedSafeSide
    else {
      continueOrFailReconciliation()
      return
    }
    guard
      reconciliationPhase != .reexpanded
        || expandedEnvironmentIsSafe(environment)
    else {
      failVisible("boundary_reexpansion_failed")
      return
    }
    guard
      reconciliationPhase != .collapsed
        || (!isExpanded
          && abs(
            (boundary?.length ?? 0)
              - NSStatusItem.squareLength
          ) < 0.5)
    else {
      failVisible("boundary_changed_during_movement")
      return
    }

    let collateralOrder = normalizedOrder(
      snapshot.items,
      excluding: pendingIdentity
    )
    guard collateralOrder == preMutationOrder else {
      failVisible("unexpected_item_moved")
      return
    }

    let reconciliation = ReconciliationSnapshot(
      processIdentifier: target.observation.processIdentifier,
      targetFrame: targetFrame,
      normalizedOrder: normalizedOrder(
        snapshot.items,
        excluding: nil
      ),
      boundaryGeneration: environment.generation,
      boundaryFrame: environment.boundaryFrame
    )
    if reconciliation == lastReconciliationSnapshot {
      stableReconciliationCount += 1
    } else {
      lastReconciliationSnapshot = reconciliation
      stableReconciliationCount = 1
    }

    guard
      stableReconciliationCount
        >= SafeDefaultCorrectionTuning.requiredStableSnapshots
    else {
      continueOrFailReconciliation()
      return
    }

    switch reconciliationPhase {
    case .collapsed:
      setBoundaryExpanded(true)
      guard isExpanded else {
        failVisible("boundary_reexpansion_failed")
        return
      }
      reconciliationPhase = .reexpanded
      lastReconciliationSnapshot = nil
      stableReconciliationCount = 0
      reconciliationSampleCount = 0
      scheduleOnce(
        #selector(reconcilePendingCorrection),
        after: SafeDefaultCorrectionTuning.menuBarReflowSeconds
      )

    case .reexpanded:
      writeDiagnostic("correction_succeeded")
      resetCorrectionState()
    }
  }

  private func continueOrFailReconciliation() {
    guard
      reconciliationSampleCount
        < SafeDefaultCorrectionTuning.maximumReconciliationSamples
    else {
      failVisible("reconciliation_timed_out")
      return
    }
    scheduleOnce(
      #selector(reconcilePendingCorrection),
      after:
        SafeDefaultCorrectionTuning.reconciliationIntervalSeconds
    )
  }

  private func normalizedOrder(
    _ items: [ClassifiedSourceItem],
    excluding excludedIdentity: ProvisionalIdentityKey?
  ) -> [ProvisionalIdentityKey] {
    items.compactMap {
      guard
        let identity = $0.identity.provisionalKey,
        identity != excludedIdentity
      else {
        return nil
      }
      return identity
    }
  }

  private func boundaryEnvironment() -> BoundaryEnvironment? {
    guard
      let boundaryWindow = boundary?.button?.window,
      let launcherWindow = launcher?.button?.window,
      let screen = boundaryWindow.screen,
      launcherWindow.screen === screen,
      isUsable(boundaryWindow.frame),
      isUsable(launcherWindow.frame),
      let screenNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber
    else {
      return nil
    }

    let displayIdentifier = screenNumber.uint32Value
    let displayBounds = CGDisplayBounds(displayIdentifier)
    let fallbackMenuBarFrame = CGRect(
      x: screen.frame.minX,
      y: screen.frame.maxY - statusBar.thickness,
      width: screen.frame.width,
      height: statusBar.thickness
    )
    let safeAppKitFrame =
      screen.auxiliaryTopRightArea ?? fallbackMenuBarFrame
    guard
      let boundaryFrame = quartzFrame(
        boundaryWindow.frame,
        screen: screen,
        displayBounds: displayBounds
      ),
      let launcherFrame = quartzFrame(
        launcherWindow.frame,
        screen: screen,
        displayBounds: displayBounds
      ),
      let rawSafeFrame = quartzFrame(
        safeAppKitFrame,
        screen: screen,
        displayBounds: displayBounds
      )
    else {
      return nil
    }
    let safeFrame = ItemFrame(
      x: rawSafeFrame.x - 1,
      y: rawSafeFrame.y - 1,
      width: rawSafeFrame.width + 2,
      height: rawSafeFrame.height + 2
    )

    return BoundaryEnvironment(
      displayIdentifier: displayIdentifier,
      safeMenuBarFrame: safeFrame,
      boundaryFrame: boundaryFrame,
      launcherFrame: launcherFrame
    )
  }

  private func quartzFrame(
    _ appKitFrame: CGRect,
    screen: NSScreen,
    displayBounds: CGRect
  ) -> ItemFrame? {
    guard isUsable(appKitFrame) else {
      return nil
    }
    // AppKit window frames use a bottom-left screen origin. Accessibility and
    // CGEvent pointer positions use the display's Quartz top-left origin.
    let frame = ItemFrame(
      x: displayBounds.minX + (appKitFrame.minX - screen.frame.minX),
      y: displayBounds.minY + (screen.frame.maxY - appKitFrame.maxY),
      width: appKitFrame.width,
      height: appKitFrame.height
    )
    return frame.isUsable ? frame : nil
  }

  private func scheduleOnce(
    _ selector: Selector,
    after interval: TimeInterval
  ) {
    let timer = Timer(
      timeInterval: interval,
      target: self,
      selector: selector,
      userInfo: nil,
      repeats: false
    )
    RunLoop.main.add(timer, forMode: .common)
    scheduledOneShotTimers.append(timer)
  }

  private var operationDeadlineIsValid: Bool {
    guard let armDeadlineUptimeNanoseconds else {
      return false
    }
    return DispatchTime.now().uptimeNanoseconds
      < armDeadlineUptimeNanoseconds
  }

  private func failVisible(_ failureCode: String) {
    setBoundaryExpanded(false)
    writeDiagnostic("correction_failed:\(failureCode)")
    resetCorrectionState()
    NSSound.beep()
  }

  private func resetCorrectionState() {
    correctionTimer?.invalidate()
    correctionTimer = nil
    for timer in scheduledOneShotTimers {
      timer.invalidate()
    }
    scheduledOneShotTimers.removeAll()
    armDeadlineUptimeNanoseconds = nil
    armedBoundaryState = nil
    previousItems = nil
    pendingIdentity = nil
    pendingProcessIdentifier = nil
    preMutationOrder = []
    lastPreparationSnapshot = nil
    stablePreparationCount = 0
    preparationSampleCount = 0
    expectedBoundaryGeneration = nil
    reconciliationPhase = .collapsed
    lastReconciliationSnapshot = nil
    stableReconciliationCount = 0
    reconciliationSampleCount = 0
    refreshToggleItems()
  }

  private func writeDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
  }

  @objc private func quit() {
    removeStatusItems()
    NSApplication.shared.terminate(nil)
  }

  private func removeStatusItems() {
    removeEnvironmentObservers()
    resetCorrectionState()
    if let boundary {
      boundary.length = NSStatusItem.squareLength
      statusBar.removeStatusItem(boundary)
      self.boundary = nil
    }
    if let launcher {
      statusBar.removeStatusItem(launcher)
      self.launcher = nil
    }
    isExpanded = false
    toggleItems.removeAll()
    correctionItems.removeAll()
  }
}

@main
private enum BoundarySpike {
  @MainActor
  static func main() {
    if CommandLine.arguments.dropFirst().contains("--help") {
      printUsage()
      return
    }

    do {
      let configuration = try BoundaryConfiguration(
        arguments: CommandLine.arguments
      )
      let application = NSApplication.shared
      let delegate = BoundaryAppDelegate(configuration: configuration)
      application.setActivationPolicy(.accessory)
      application.delegate = delegate
      application.run()
      withExtendedLifetime(delegate) {}
    } catch {
      FileHandle.standardError.write(
        Data("error: \(error)\n\n".utf8)
      )
      printUsage()
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func printUsage() {
    print(
      """
      TrayNook disposable menu-bar boundary spike

      Usage:
        traynook-boundary-spike [--expanded-width POINTS]
          [--target-bundle-id ID] [--poll-interval SECONDS]
          [--execute-correction]

      The boundary starts collapsed. Command-drag the Launcher to the right of
      the visible separator, place the separator at the test boundary, then
      expand explicitly from either prototype item's menu. Normal Quit removes
      both status items.

      A target bundle enables a one-shot dry run. --execute-correction enables
      one live public-Quartz Command-drag only after the user explicitly arms it.
      """
    )
  }
}

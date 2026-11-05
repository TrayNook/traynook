import AppKit
import InventoryIdentityCore
import Testing

@testable import TrayNook

@Suite("Concealed inventory monitoring")
@MainActor
struct AppModelInventoryTests {
  private let known: Set<String> = ["example.timer", "example.known", "example.bar"]
  private let hidden: Set<String> = ["example.timer", "example.known"]

  private func reveals(_ changes: [AppModel.KeyedChange], visible: Set<String> = []) -> Bool {
    AppModel.inventoryRequiresReveal(changes, known: known, hidden: hidden, verifiedVisible: visible)
  }

  @Test("An unchanged multi-item system app does not reopen the hidden section")
  func stableSystemItemsRemainConcealed() {
    let inventory = IdentityAssessor().classify([
      item(),
      item(bundle: "com.apple.controlcenter", pid: 20, index: 0, identifier: "clock", window: 1),
      item(bundle: "com.apple.controlcenter", pid: 20, index: 1, identifier: "wifi", window: 2),
    ])
    #expect(!reveals(AppModel.keyedChanges(from: inventory, to: inventory)))
  }

  @Test("Dynamic titles, geometry, and ordering do not change source identity")
  func metadataChangesRemainConcealed() {
    let before = IdentityAssessor().classify([item(identifier: "primary", window: 1)])
    let after = IdentityAssessor().classify([
      item(index: 2, identifier: "primary", title: "updated", x: -300, window: 1),
    ])
    #expect(!reveals(AppModel.keyedChanges(from: before, to: after)))
  }

  @Test("A restarted or relaunched hidden source rebinds its process instead of revealing")
  func hiddenSourcesRebind() {
    let assessor = IdentityAssessor()
    let original = assessor.classify([item(identifier: "primary")])
    let restartChanges = AppModel.keyedChanges(from: original, to: assessor.classify([item(pid: 30, identifier: "primary")]))
    #expect(!reveals(restartChanges))
    #expect(restartChanges.contains { AppModel.rebindsProcess($0, hidden: hidden) })

    let relaunchChanges = AppModel.keyedChanges(from: [], to: assessor.classify([item(bundle: "example.known", pid: 31)]))
    #expect(!reveals(relaunchChanges))
    #expect(relaunchChanges.contains { AppModel.rebindsProcess($0, hidden: hidden) })
    #expect(!relaunchChanges.contains { AppModel.rebindsProcess($0, hidden: []) })

    #expect(!reveals(AppModel.keyedChanges(from: original, to: [])))
  }

  @Test("A Menu Bar source that restarts or relaunches is never trusted as hidden")
  func menuBarSourcesAreNotTrusted() {
    let assessor = IdentityAssessor()
    let before = assessor.classify([item(bundle: "example.bar", pid: 50)])
    let restarted = AppModel.keyedChanges(from: before, to: assessor.classify([item(bundle: "example.bar", pid: 51)]))
    #expect(!restarted.contains { AppModel.rebindsProcess($0, hidden: hidden) })
    #expect(reveals(restarted))
    #expect(!AppModel.inventoryRequiresReview(restarted))
    #expect(!reveals(restarted, visible: ["example.bar"]))

    let relaunched = AppModel.keyedChanges(from: [], to: assessor.classify([item(bundle: "example.bar", pid: 52)]))
    #expect(!relaunched.contains { AppModel.rebindsProcess($0, hidden: hidden) })
    #expect(reveals(relaunched))
    #expect(!AppModel.inventoryRequiresReview(relaunched))
    #expect(!reveals(relaunched, visible: ["example.bar"]))
  }

  @Test("An unknown bundle or an ambiguous group change requests a reveal")
  func realInventoryChangesReveal() {
    let assessor = IdentityAssessor()
    let original = assessor.classify([item(identifier: "primary")])
    let newSource = AppModel.keyedChanges(from: original,
      to: assessor.classify([item(identifier: "primary"), item(bundle: "example.new", pid: 30)]))
    #expect(reveals(newSource))
    #expect(!AppModel.inventoryRequiresReview(newSource))
    let ambiguous = AppModel.keyedChanges(
      from: assessor.classify([item(index: 0), item(index: 1)]),
      to: assessor.classify([item(index: 0), item(index: 1), item(index: 2)]))
    #expect(reveals(ambiguous))
    #expect(AppModel.inventoryRequiresReview(ambiguous))
  }

  @Test("A new stable source already verified visible does not reopen hidden items")
  func visibleNewSourceKeepsConcealment() {
    let assessor = IdentityAssessor()
    let changes = AppModel.keyedChanges(from: assessor.classify([item()]),
      to: assessor.classify([item(), item(bundle: "example.new", pid: 30)]))
    #expect(!reveals(changes, visible: ["example.new"]))
    #expect(reveals(changes))
  }

  @Test("Slow discovery needs a nonempty unchanged native baseline with no unsafe geometry")
  func slowDiscoveryRequiresUnchangedNativeSources() {
    let hidden = StatusWindowState(processIdentifier: 10, windowIdentifier: 1,
      frame: ItemFrame(x: -100, y: 0, width: 24, height: 37), isOnscreen: false)
    let visible = StatusWindowState(processIdentifier: 20, windowIdentifier: 2,
      frame: ItemFrame(x: 1300, y: 0, width: 24, height: 37), isOnscreen: true)
    let baseline = [hidden, visible]
    #expect(AppModel.canRetainConcealment(lastVerified: baseline, current: baseline, unsafeScans: 0))
    for current: [StatusWindowState]? in [nil, [], [hidden], baseline + [visible],
      [hidden, StatusWindowState(processIdentifier: 21, windowIdentifier: visible.windowIdentifier,
        frame: visible.frame, isOnscreen: true)],
      [StatusWindowState(processIdentifier: 10, windowIdentifier: 1,
        frame: ItemFrame(x: -200, y: 0, width: 24, height: 37), isOnscreen: false), visible],
      [StatusWindowState(processIdentifier: 10, windowIdentifier: 1,
        frame: hidden.frame, isOnscreen: true), visible]] {
      #expect(!AppModel.canRetainConcealment(lastVerified: baseline, current: current, unsafeScans: 0))
    }
    #expect(!AppModel.canRetainConcealment(lastVerified: [], current: [], unsafeScans: 0))
    #expect(!AppModel.canRetainConcealment(lastVerified: nil, current: baseline, unsafeScans: 0))
    #expect(!AppModel.canRetainConcealment(lastVerified: baseline, current: baseline, unsafeScans: 1))
  }

  @Test("Only visible lifecycle returns of saved hidden identities request individual repair")
  func returnedHiddenSourcesNeedPlacementRepair() {
    let assessor = IdentityAssessor()
    let original = assessor.classify([item(identifier: "primary", window: 10)])
    let returned = assessor.classify([item(pid: 30, identifier: "primary", x: 1300, window: 20)])
    let restart = AppModel.keyedChanges(from: original, to: returned)
    #expect(AppModel.hiddenSourceRepairKeys(restart, hidden: hidden,
      verifiedVisible: ["example.timer"]) == ["example.timer"])
    #expect(AppModel.hiddenSourceRepairKeys(restart, hidden: hidden, verifiedVisible: []) == [])
    #expect(AppModel.hiddenSourceRepairKeys(restart, hidden: [],
      verifiedVisible: ["example.timer"]) == [])

    let reappeared = AppModel.keyedChanges(from: [], to: assessor.classify([item(bundle: "example.known", pid: 31)]))
    #expect(AppModel.hiddenSourceRepairKeys(reappeared, hidden: hidden,
      verifiedVisible: ["example.known"]) == ["example.known"])
    let drag = AppModel.keyedChanges(from: returned,
      to: assessor.classify([item(pid: 30, identifier: "primary", x: 1400, window: 20)]))
    #expect(AppModel.hiddenSourceRepairKeys(drag, hidden: hidden,
      verifiedVisible: ["example.timer"]) == [])
    let recreated = AppModel.keyedChanges(from: original,
      to: assessor.classify([item(identifier: "primary", x: 1300, window: 21)]))
    #expect(AppModel.hiddenSourceRepairKeys(recreated, hidden: hidden,
      verifiedVisible: ["example.timer"]) == ["example.timer"])
  }

  @Test("Individual lifecycle repair requires an onscreen bound native window")
  func repairRequiresPositiveNativeVisibility() throws {
    func source(visible: Bool?, window: UInt32?) throws -> ClassifiedSourceItem {
      try #require(IdentityAssessor().classify([RawSourceItemObservation(runtimeID: "10:0",
        processIdentifier: 10, bundleIdentifier: "example.timer", applicationName: "Fixture",
        role: "AXMenuBarItem", frame: ItemFrame(x: 1300, y: 0, width: 24, height: 24),
        actions: ["AXPress"], metadata: LiveAccessibilityMetadata(), observedOrder: 0,
        isOnscreen: visible, statusWindowIdentifier: window)]).first)
    }
    let inspection = NativeMenuBarController.Inspection(setupMessage: nil,
      items: ["10:0": .init(behindBoundary: false, isClipped: false, isVerifiedVisible: true)])
    for visibility: Bool? in [nil, false, true] {
      for window: UInt32? in [nil, 20] {
        let keys = AppModel.verifiedVisibleSourceKeys([try source(visible: visibility, window: window)],
          inspection: inspection)
        #expect(keys == (visibility == true && window != nil ? ["example.timer"] : []))
      }
    }
  }

  @Test("Returned-source repair is paced, bounded, and bound to the observed native identity")
  func repairAttemptsAreBounded() throws {
    let assessor = IdentityAssessor()
    let source = try #require(assessor.classify([item(window: 10)]).first)
    var repair = AppModel.HiddenSourceRepair(source: source)
    let now = Date(timeIntervalSince1970: 100)
    let first = repair.takeAttempt(now: now)
    let early = repair.takeAttempt(now: now.addingTimeInterval(2.9))
    let second = repair.takeAttempt(now: now.addingTimeInterval(3))
    let third = repair.takeAttempt(now: now.addingTimeInterval(6))
    let exhausted = repair.takeAttempt(now: now.addingTimeInterval(60))
    #expect(first)
    #expect(!early)
    #expect(second)
    #expect(third)
    #expect(!exhausted)
    #expect(repair.attempts == 3)
    #expect(repair.matches(source))
    #expect(!repair.matches(try #require(assessor.classify([item(pid: 20, window: 10)]).first)))
    #expect(!repair.matches(try #require(assessor.classify([item(window: 11)]).first)))
    var exhaustedRepair: AppModel.HiddenSourceRepair? = repair
    let automatic = AppModel.takePlacementAttempt(automatic: true, repair: &exhaustedRepair, source: source,
      now: now.addingTimeInterval(60))
    let manual = AppModel.takePlacementAttempt(automatic: false, repair: &exhaustedRepair, source: source,
      now: now.addingTimeInterval(60))
    #expect(!automatic)
    #expect(manual, "Explicit Retry is independent of the automatic repair budget.")
    #expect(exhaustedRepair?.attempts == 3)
  }

  @Test("A refused returned source cannot consume a later source's repair budget or block its move")
  func returnedSourceFailuresAreIsolated() async throws {
    let assessor = IdentityAssessor()
    let refusing = try #require(assessor.classify([item(bundle: "example.refusing", window: 10)]).first)
    let working = try #require(assessor.classify([item(bundle: "example.working", pid: 20, window: 20)]).first)
    let sources = ["example.refusing": refusing, "example.working": working]
    var repairs = sources.mapValues { AppModel.HiddenSourceRepair(source: $0) }
    let now = Date(timeIntervalSince1970: 100)
    let queued = sources.keys.filter { repairs[$0]?.canAttempt(now: now) == true }
    #expect(queued.count == 2)
    #expect(repairs.values.allSatisfy { $0.attempts == 0 }, "Queueing is not a native move attempt.")
    let placements = [SavedItem(id: "example.refusing", placement: .dropdown),
      SavedItem(id: "example.working", placement: .alwaysHidden)]
    var calls: [String] = []
    var validations = 0
    let warnings = try await AppModel.applyIndividualPlacementsWithFallback(placements, move: { saved in
      let source = try #require(sources[saved.id])
      let dispatched = AppModel.takePlacementAttempt(automatic: true, repair: &repairs[saved.id],
        source: source, now: now)
      guard dispatched else { return false }
      calls.append(saved.id)
      if saved.id == "example.refusing" { throw AppError.message("App refused movement") }
      return true
    }, refresh: { validations += 1 }, verifyConcealed: {}, reorder: {})
    #expect(calls == placements.map(\.id))
    #expect(repairs["example.refusing"]?.attempts == 1)
    #expect(repairs["example.working"]?.attempts == 1)
    #expect(validations > 0)
    #expect(warnings == ["App refused movement"])
  }

  @Test("Temporary input and inventory failures defer automatic repairs without exhausting refusals",
    arguments: [NativeMenuActionError.inputNotIdle, .inputInterrupted, .placementInterrupted, .inventoryUnavailable])
  func transientRepairsRemainEligible(_ error: NativeMenuActionError) throws {
    let source = try #require(IdentityAssessor().classify([item(window: 10)]).first)
    var repair: AppModel.HiddenSourceRepair? = AppModel.HiddenSourceRepair(source: source)
    let now = Date(timeIntervalSince1970: 100)
    for attempt in 0..<5 {
      let dispatched = AppModel.takePlacementAttempt(automatic: true, repair: &repair, source: source,
        now: now.addingTimeInterval(Double(attempt * 3)))
      #expect(dispatched)
      let deferred = AppModel.deferAutomaticPlacementFailure(error, repair: &repair)
      #expect(deferred)
      #expect(repair?.attempts == 0)
      #expect(repair?.canAttempt(now: now.addingTimeInterval(Double(attempt * 3) + 1)) == false,
        "A transient refund must retain the three-second pause.")
    }
    let healthy = AppModel.takePlacementAttempt(automatic: true, repair: &repair, source: source,
      now: now.addingTimeInterval(15))
    #expect(healthy)
    let refused = AppModel.deferAutomaticPlacementFailure(AppError.message("App refused movement"), repair: &repair)
    #expect(!refused)
    #expect(repair?.attempts == 1)
  }

  @Test("Ambiguous identity blocks recovery even alongside a returning Menu Bar source")
  func ambiguityWinsOverRecoverableChanges() {
    let assessor = IdentityAssessor()
    let returning = AppModel.keyedChanges(from: [],
      to: assessor.classify([item(bundle: "example.bar", pid: 50)]))
    let ambiguous = AppModel.keyedChanges(
      from: assessor.classify([item(index: 0), item(index: 1)]),
      to: assessor.classify([item(index: 0), item(index: 1), item(index: 2)]))

    for changes in [returning + ambiguous, ambiguous + returning] {
      #expect(reveals(changes))
      #expect(AppModel.inventoryRequiresReview(changes))
    }
  }

  @Test("Ranked siblings reveal whenever their set or windows change")
  func rankedSiblingsRevealOnShift() {
    let assessor = IdentityAssessor()
    let pair = assessor.classify([
      item(bundle: "example.pair", pid: 40, index: 0, window: 10),
      item(bundle: "example.pair", pid: 40, index: 1, window: 11),
    ])
    let pairKeys: Set<String> = ["example.pair#w0", "example.pair#w1"]
    let appearing = AppModel.keyedChanges(from: [], to: pair)
    #expect(Set(appearing.compactMap(\.key)) == pairKeys)
    #expect(AppModel.inventoryRequiresReveal(appearing, known: pairKeys, hidden: [], verifiedVisible: pairKeys) == false)
    #expect(AppModel.inventoryRequiresReveal(appearing, known: ["example.pair#w0"], hidden: [], verifiedVisible: pairKeys))
    #expect(appearing.allSatisfy { AppModel.rebindsProcess($0, hidden: pairKeys) })

    // One sibling goes away: the survivor would silently take rank 0.
    let survivor = assessor.classify([item(bundle: "example.pair", pid: 40, index: 1, window: 11)])
    let removal = AppModel.keyedChanges(from: pair, to: survivor)
    #expect(AppModel.inventoryRequiresReveal(removal, known: pairKeys.union(["example.pair"]), hidden: pairKeys, verifiedVisible: []))
    #expect(AppModel.inventoryRequiresReview(removal))

    // A sibling is recreated with a newer window: ranks swap with no created/removed change.
    let recreated = assessor.classify([
      item(bundle: "example.pair", pid: 40, index: 0, window: 12),
      item(bundle: "example.pair", pid: 40, index: 1, window: 11),
    ])
    let swap = AppModel.keyedChanges(from: pair, to: recreated)
    #expect(swap.contains { $0.windowReplaced })
    #expect(AppModel.inventoryRequiresReveal(swap, known: pairKeys, hidden: pairKeys, verifiedVisible: []))
    #expect(AppModel.inventoryRequiresReview(swap))
    #expect(!swap.contains { AppModel.rebindsProcess($0, hidden: pairKeys) })

    // From one item to two: the plain key disappears and two unknown keys appear.
    let single = assessor.classify([item(bundle: "example.pair", pid: 40, index: 0, window: 10)])
    let growth = AppModel.keyedChanges(from: single, to: pair)
    #expect(AppModel.inventoryRequiresReveal(growth, known: ["example.pair"], hidden: ["example.pair"], verifiedVisible: []))
  }

  @Test("An identifier-keyed sibling leaving reveals, since the survivor is re-keyed")
  func identifierSiblingRemovalReveals() {
    let assessor = IdentityAssessor()
    let pair = assessor.classify([
      item(bundle: "example.pair", pid: 40, index: 0, identifier: "foo", window: 10),
      item(bundle: "example.pair", pid: 40, index: 1, identifier: "bar", window: 11),
    ])
    let keys: Set<String> = ["example.pair#ax:foo", "example.pair#ax:bar"]
    let survivor = assessor.classify([item(bundle: "example.pair", pid: 40, index: 0, identifier: "foo", window: 10)])
    #expect(survivor[0].identity.persistentKey == "example.pair")
    let removal = AppModel.keyedChanges(from: pair, to: survivor)
    #expect(AppModel.inventoryRequiresReveal(removal, known: keys, hidden: keys, verifiedVisible: []))
    #expect(AppModel.inventoryRequiresReview(removal))

    // A transient system sibling (Control Centre's camera indicator) leaving a
    // larger group changes no other key and must not reopen the section.
    let trio = assessor.classify([
      item(bundle: "com.apple.controlcenter", pid: 41, index: 0, identifier: "clock", window: 20),
      item(bundle: "com.apple.controlcenter", pid: 41, index: 1, identifier: "wifi", window: 21),
      item(bundle: "com.apple.controlcenter", pid: 41, index: 2, identifier: "audiovideo", window: 22),
    ])
    let duo = assessor.classify([
      item(bundle: "com.apple.controlcenter", pid: 41, index: 0, identifier: "clock", window: 20),
      item(bundle: "com.apple.controlcenter", pid: 41, index: 1, identifier: "wifi", window: 21),
    ])
    let systemKeys = Set(trio.compactMap(\.identity.persistentKey))
    #expect(!AppModel.inventoryRequiresReveal(AppModel.keyedChanges(from: trio, to: duo), known: systemKeys, hidden: [], verifiedVisible: []))
    #expect(!AppModel.inventoryRequiresReveal(AppModel.keyedChanges(from: duo, to: trio), known: systemKeys, hidden: [], verifiedVisible: systemKeys))
    // Even unknown and not yet verified visible: a system item cannot be hidden by us.
    #expect(!AppModel.inventoryRequiresReveal(AppModel.keyedChanges(from: duo, to: trio), known: [], hidden: [], verifiedVisible: []))
  }

  @Test("Replacing a ranked window without changing its rank still requires review")
  func rankedWindowReplacementWithoutMetadataChangesReveals() {
    let assessor = IdentityAssessor()
    let before = assessor.classify([
      item(bundle: "example.pair", pid: 40, index: 0, window: 10),
      item(bundle: "example.pair", pid: 40, index: 1, window: 11),
    ])
    let after = assessor.classify([
      item(bundle: "example.pair", pid: 40, index: 0, window: 10),
      item(bundle: "example.pair", pid: 40, index: 1, window: 12),
    ])
    let keys: Set<String> = ["example.pair#w0", "example.pair#w1"]
    let changes = AppModel.keyedChanges(from: before, to: after)

    #expect(changes.count == 1)
    #expect(changes.first?.key == "example.pair#w1")
    #expect(changes.first?.windowReplaced == true)
    #expect(AppModel.inventoryRequiresReview(changes))
    #expect(AppModel.inventoryRequiresReveal(changes, known: keys, hidden: keys, verifiedVisible: []))
    #expect(!changes.contains { AppModel.rebindsProcess($0, hidden: keys) })
  }

  @Test("Runtime-only status windows never trigger a reveal by themselves")
  func unverifiedWindowsAreIgnored() {
    let assessor = IdentityAssessor()
    let before = assessor.classify([item(window: 1)])
    let panel = RawSourceItemObservation(runtimeID: "10:window:7", processIdentifier: 10,
      bundleIdentifier: "example.timer", applicationName: "Fixture", role: "UnverifiedStatusWindow",
      frame: ItemFrame(x: 1300, y: 0, width: 200, height: 24), actions: [],
      metadata: LiveAccessibilityMetadata(), observedOrder: 1, statusWindowIdentifier: 7)
    let changes = AppModel.keyedChanges(from: before, to: assessor.classify([item(window: 1), panel]))
    #expect(changes.contains { $0.change.kind == .created && $0.key == nil })
    #expect(!reveals(changes))
  }

  @Test("Saved keys reduce to their bundle identifier")
  func bundleOfKey() {
    #expect(AppModel.bundle(ofKey: "a.b") == "a.b")
    #expect(AppModel.bundle(ofKey: "a.b#w1") == "a.b")
    #expect(AppModel.bundle(ofKey: "a.b#ax:x#y") == "a.b")
    #expect(AppModel.bundle(ofKey: "#x") == "")
  }

  @Test("Live lookup follows inventory mutations and excludes duplicate or ambiguous identities",
    .enabled(if: ProcessInfo.processInfo.environment["TRAYNOOK_APPKIT_TESTS"] == "1"))
  func liveLookupTracksInventory() throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let defaults = UserDefaults.standard
    let preferenceKeys = ["TrayNookLauncher", "TrayNook.HiddenBoundary"].flatMap { name in
      ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
       "NSStatusItem VisibleCC \(name)"]
    }
    let previous = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
      defaults.object(forKey: key).map { (key, $0) }
    })
    let launcher = NSStatusBar.system.statusItem(withLength: 0)
    launcher.isVisible = false
    let native = NativeMenuBarController(launcher: launcher)
    defer {
      native.remove()
      NativeMenuBarController.removePreservingPosition(launcher)
      for key in preferenceKeys {
        if let value = previous[key] { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
      defaults.synchronize()
    }
    let model = AppModel(native: native, store: nil)
    let assessor = IdentityAssessor()
    let original = try #require(assessor.classify([item(window: 1)]).first)
    let replacement = try #require(assessor.classify([item(pid: 20, window: 2)]).first)
    let key = try #require(original.identity.persistentKey)
    #expect(replacement.identity.persistentKey == key)

    model.items = [original]
    #expect(model.liveItem(key) == original)
    #expect(model.liveItem("example.unknown") == nil)
    model.items.append(replacement)
    #expect(model.liveItem(key) == nil)
    model.items.append(original)
    #expect(model.liveItem(key) == nil)
    model.items.removeLast()
    #expect(model.liveItem(key) == nil)
    model.items.removeLast()
    #expect(model.liveItem(key) == original)
    model.items[0] = replacement
    #expect(model.liveItem(key) == replacement)
    #expect(model.liveItem(key)?.observation.processIdentifier == 20)

    let ambiguous = assessor.classify([
      item(bundle: "example.ambiguous", pid: 30),
      item(bundle: "example.ambiguous", pid: 30, index: 1),
    ])
    #expect(ambiguous.allSatisfy { $0.identity.persistentKey == nil })
    model.items.append(contentsOf: ambiguous)
    #expect(model.liveItem("example.ambiguous") == nil)
    #expect(model.liveItem(key) == replacement)
    model.items.removeAll()
    #expect(model.liveItem(key) == nil)
  }

  private func item(bundle: String = "example.timer", pid: Int32 = 10,
    index: Int = 0, identifier: String? = nil, title: String = "ready", x: Double = 1100,
    window: UInt32? = nil
  ) -> RawSourceItemObservation {
    RawSourceItemObservation(runtimeID: "\(pid):\(index)", processIdentifier: pid,
      bundleIdentifier: bundle, applicationName: "Fixture", role: "AXMenuBarItem",
      frame: ItemFrame(x: x, y: 0, width: 24, height: 24), actions: ["AXPress"],
      metadata: LiveAccessibilityMetadata(identifierCandidate: identifier, title: title),
      observedOrder: index, statusWindowIdentifier: window)
  }
}

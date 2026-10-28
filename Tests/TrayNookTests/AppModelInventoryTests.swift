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
    #expect(!reveals(restarted, visible: ["example.bar"]))

    let relaunched = AppModel.keyedChanges(from: [], to: assessor.classify([item(bundle: "example.bar", pid: 52)]))
    #expect(!relaunched.contains { AppModel.rebindsProcess($0, hidden: hidden) })
    #expect(reveals(relaunched))
    #expect(!reveals(relaunched, visible: ["example.bar"]))
  }

  @Test("An unknown bundle or an ambiguous group change requests a reveal")
  func realInventoryChangesReveal() {
    let assessor = IdentityAssessor()
    let original = assessor.classify([item(identifier: "primary")])
    #expect(reveals(AppModel.keyedChanges(from: original,
      to: assessor.classify([item(identifier: "primary"), item(bundle: "example.new", pid: 30)]))))
    #expect(reveals(AppModel.keyedChanges(
      from: assessor.classify([item(index: 0), item(index: 1)]),
      to: assessor.classify([item(index: 0), item(index: 1), item(index: 2)]))))
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

    // A sibling is recreated with a newer window: ranks swap with no created/removed change.
    let recreated = assessor.classify([
      item(bundle: "example.pair", pid: 40, index: 0, window: 12),
      item(bundle: "example.pair", pid: 40, index: 1, window: 11),
    ])
    let swap = AppModel.keyedChanges(from: pair, to: recreated)
    #expect(swap.contains { $0.windowReplaced })
    #expect(AppModel.inventoryRequiresReveal(swap, known: pairKeys, hidden: pairKeys, verifiedVisible: []))
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

import AppKit
import SwiftUI
import InventoryIdentityCore

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var updates = UpdateController()
  @State private var confirmReset = false
  @AppStorage("dropdownGlyphs") private var showGlyphs = false
  @State private var showItemDetails = true

  var body: some View {
    VStack(spacing: 0) {
      Picker(L("Settings"), selection: $model.selectedTab) {
        Label(L("Layout"), systemImage: "rectangle.3.group").tag(0)
        Label(L("Permissions"), systemImage: "hand.raised").tag(1)
        Label(L("General"), systemImage: "gearshape").tag(2)
      }
      .pickerStyle(.segmented).labelsHidden().frame(width: 360).padding(.top, 18)
      Group {
        switch model.selectedTab {
        case 1: permissions
        case 2: general
        default: layout
        }
      }.padding(16).frame(maxHeight: .infinity)
      if model.recoveryRequired {
        HStack {
          Label(L("Layout recovery is required. Reset the saved layout to resume editing."), systemImage: "exclamationmark.triangle")
          Spacer()
          Button(L("Reset Layout…")) { confirmReset = true }.disabled(model.busy)
        }.padding(12).background(.quaternary)
      }
      if let message = model.message {
        HStack(alignment: .top) {
          Image(systemName: "info.circle")
          Text(message).font(.callout).textSelection(.enabled)
          Spacer(minLength: 0)
        }.padding(12).background(.quaternary)
      }
      HStack {
        Button(L("Reveal All Items")) { model.reveal() }
          .help(L("Reveal every item and cancel any action in progress"))
        Spacer()
        if model.busy || model.scanning { ProgressView().controlSize(.small) }
        Button(L("Refresh")) { model.refresh(invalidateIcons: true) }.disabled(model.busy || model.scanning)
        Button(L("Quit TrayNook")) { NSApp.terminate(nil) }
      }.padding(14)
    }
    .frame(minWidth: 760, minHeight: 590)
    .background(Color(nsColor: .windowBackgroundColor))
    .alert(L("Reset saved layout?"), isPresented: $confirmReset) {
      Button(L("Cancel"), role: .cancel) {}
      Button(L("Reset Layout"), role: .destructive) { model.resetLayout() }
    } message: {
      Text(L("This deletes saved placements and order. All items will be revealed. Privacy permissions, Launch at Login, update settings, and downloaded updates are unchanged."))
    }
  }

  private var layout: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Choose where each app appears. Changes apply automatically."))
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let setup = model.nativeSetupMessage {
        Label(setup, systemImage: "arrow.left.and.right").font(.callout)
      }
      HStack {
        Button(model.concealed ? L("Show Items") : L("Hide Items")) { model.toggleConcealment() }
          .disabled(!model.concealed && !model.canEdit)
        Button(L("Apply Saved Layout")) { model.applySavedLayout() }.disabled(!model.canEdit)
        Spacer()
        Button(L("Restore All to Menu Bar")) { model.restoreAll() }
          .disabled(model.busy || model.recoveryRequired)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          LayoutPreviewView(model: model)
          DisclosureGroup(L("Item details"), isExpanded: $showItemDetails) {
            ItemDetailsView(model: model).padding(.top, 8)
          }
          if model.layout.items.isEmpty {
            Text(L("Grant Accessibility, then refresh to discover your menu-bar items."))
              .foregroundStyle(.secondary).padding(.vertical, 12)
          }
          HStack {
            Button(L("Reset Layout…")) { confirmReset = true }.disabled(model.busy)
            Text(L("Removes saved placements and order.")).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Text(L("Opening an item brings only that item into view. It returns when its menu closes. Other hidden items stay hidden."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.padding(12)
  }

  private var permissions: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Text(L("TrayNook needs Accessibility to identify menu-bar items, apply your chosen placements, and open items from the dropdown. Until permission is granted, it leaves your menu bar visible."))
              .fixedSize(horizontal: false, vertical: true)
            HStack {
              if !model.permissionGranted { Button(L("Grant Accessibility…")) { model.requestAccessibility() } }
              Button(L("Open System Settings…")) { model.openAccessibilitySettings() }
            }
            if !model.permissionGranted {
              Text(L("Add this whole app in Privacy & Security → Accessibility. After rebuilding an ad-hoc development app, you may need to remove the old entry and grant the new build. Then click Refresh."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
          permissionHeading(L("Accessibility"), granted: model.permissionGranted)
        }
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Text(L("Optional. Screen Recording enables menu-bar glyphs in the dropdown. Choose your preferred icons in General. Captured pixels stay in memory for this session only and are never saved."))
              .fixedSize(horizontal: false, vertical: true)
            HStack {
              if !model.screenRecordingGranted { Button(L("Grant Screen Recording…")) { model.requestScreenRecording() } }
              Button(L("Open System Settings…")) { model.openScreenRecordingSettings() }
            }
            if !model.screenRecordingGranted {
              Text(L("macOS applies Screen Recording after TrayNook is quit and reopened."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
          permissionHeading(L("Screen Recording"), granted: model.screenRecordingGranted)
        }
      }.padding(12)
    }
  }

  private func permissionHeading(_ title: String, granted: Bool) -> some View {
    HStack {
      Label(title, systemImage: granted ? "checkmark.shield" : "hand.raised").font(.headline)
      Spacer()
      Text(granted ? L("Granted") : L("Not granted")).foregroundStyle(.secondary)
    }
  }

  private var general: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        GroupBox(L("Startup")) {
          Toggle(L("Launch at Login"), isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        UpdateSettingsView(updates: updates)
        GroupBox(L("Dropdown appearance")) {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(L("Show menu-bar glyphs instead of app icons in the dropdown"), isOn: $showGlyphs)
              .disabled(!model.screenRecordingGranted)
            Text(L("App icons are used by default. Menu-bar glyphs show each item's appearance as last seen while it was visible."))
              .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.screenRecordingGranted {
              HStack {
                Text(L("Menu-bar glyphs require Screen Recording.")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Review Permissions")) { model.selectedTab = 1 }
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        GroupBox(L("Diagnostics")) {
          VStack(alignment: .leading, spacing: 10) {
            Text(L("Copies compatibility and recovery details, including affected-app bundle identifiers. No full app inventory, item labels, window titles, or images. Nothing is uploaded automatically."))
              .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L("Copy Diagnostics")) { model.copyDiagnostics() }
            Link(L("Report a Problem…"), destination: URL(string: "https://github.com/TrayNook/traynook/issues/new")!)
            Text(L("Opens GitHub in your browser. Review any diagnostics before pasting them into a public issue."))
              .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        GroupBox(L("About TrayNook")) {
          VStack(alignment: .leading, spacing: 12) {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
            Text("TrayNook \(version) (\(build))")
              .font(.headline)
            Text("© 2026 Suren Khorenyan · MIT License").font(.caption).foregroundStyle(.secondary)
            Text(L("TrayNook stores your layout, preferences, and verified update downloads locally. Update checks and downloads contact GitHub. No app inventory, item labels, or images are sent. TrayNook includes no analytics."))
              .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L("To uninstall, turn off Launch at Login, quit TrayNook, and move the app to Trash. Quitting stops TrayNook from hiding menu-bar items. You can remove its Accessibility entry in System Settings."))
              .font(.callout).fixedSize(horizontal: false, vertical: true)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
      }.padding(12)
    }
  }
}

/// Local drag updates leave settings-wide native geometry and the preview untouched.
private struct ItemDetailsView: View {
  @ObservedObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showLocked = false
  @StateObject private var reorder = DetailReorderSession()
  @State private var rowHeights: [String: CGFloat] = [:]
  private let rowSpacing: CGFloat = 8

  /// Rows the user can reorder in a section: locked items are folded away.
  private func laneItems(_ zone: Placement) -> [SavedItem] {
    let items = model.layout.items.filter { saved in
      saved.placement == zone && !(model.liveItem(saved.id).map { !model.isManageable($0) } ?? false)
    }
    guard reorder.zone == zone, let order = reorder.order else { return items }
    let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    return order.compactMap { byKey[$0] }
  }

  private func reorderHandle(for key: String, in zone: Placement) -> some View {
    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
      .frame(width: 22, height: 26).contentShape(Rectangle())
      .allowsHitTesting(model.canEdit)
      .help(L("Drag to reorder"))
      .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
        .onChanged { value in dragChanged(key, in: zone, translation: value.translation.height) }
        .onEnded { _ in dragEnded() })
      .accessibilityHidden(true)
  }

  private func dragChanged(_ key: String, in zone: Placement, translation: CGFloat) {
    guard model.canEdit else { reorder.cancel(); return }
    if reorder.key == nil {
      guard reorder.begin(key, layout: model.layout, lane: laneItems(zone), rowHeights: rowHeights,
        rowSpacing: rowSpacing, commit: { model.setOrder($0, undoable: true) }) else { return }
    }
    guard reorder.key == key else { return }
    withAnimation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.85)) { reorder.update(translation: translation) }
  }

  private func dragEnded() {
    withAnimation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.85)) {
      if model.canEdit { reorder.finish(currentLayout: model.layout) }
      else { reorder.cancel() }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Placement.allCases) { zone in
        let savedItems = model.layout.items.filter { $0.placement == zone }
        let shown = laneItems(zone)
        let locked = savedItems.filter { saved in !shown.contains { $0.id == saved.id } }
        VStack(alignment: .leading, spacing: rowSpacing) {
          HStack {
            Text(zone.title).font(.headline)
            Text("\(savedItems.count)").foregroundStyle(.secondary)
            Spacer()
            if zone == .menuBar { Label(L("TrayNook stays here"), systemImage: "tray.full").font(.caption).foregroundStyle(.secondary) }
          }
          if savedItems.isEmpty {
            Text(L("No items here yet")).foregroundStyle(.secondary).padding(.vertical, 8)
          }
          // Rows slide apart live while one is dragged by its handle.
          ForEach(shown) { item in
            itemRow(item, handle: AnyView(reorderHandle(for: item.id, in: zone)))
              .modifier(DetailReorderRow(pointer: reorder.pointer, dragged: reorder.key == item.id))
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[item.id] = $0 }
          }
          // Locked items carry no decision; one row stands for all of them.
          if !locked.isEmpty {
            DisclosureGroup(isExpanded: $showLocked) {
              ForEach(locked) { item in itemRow(item) }
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "lock").frame(width: 26)
                Text(L("System items")).lineLimit(1)
                Text("\(locked.count)").foregroundStyle(.secondary)
                Spacer()
                Text(L("Protected — kept visible")).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      }
    }
    .onChange(of: model.layout) { _ in reorder.cancel() }
    .onChange(of: model.canEdit) { editable in if !editable { reorder.cancel() } }
    .onDisappear { reorder.cancel() }
  }

  private func itemRow(_ saved: SavedItem, handle: AnyView = AnyView(EmptyView())) -> some View {
    HStack(spacing: 10) {
      ItemDetailsContent(model: model, saved: saved).equatable()
      handle
    }
    .disabled(!model.canEditPlacement(saved.id))
    .padding(.vertical, 3)
  }
}

/// Local reordering reuses row content; model publications still refresh native status.
private struct ItemDetailsContent: View, @preconcurrency Equatable {
  @ObservedObject var model: AppModel
  let saved: SavedItem

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.saved == rhs.saved && lhs.model === rhs.model
  }

  var body: some View {
    let live = model.liveItem(saved.id)
    let canChoosePlacement = model.canChoosePlacement(saved.id)
    return HStack(spacing: 10) {
      Image(nsImage: model.icon(for: saved.id)).resizable().frame(width: 26, height: 26).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.name(for: saved.id)).lineLimit(1)
        Text(model.status(for: saved)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if live == nil {
        Button(L("Forget")) { model.forget(saved.id) }.disabled(model.busy)
      }
      if canChoosePlacement {
        if live != nil, model.pendingPlacementKeys.contains(saved.id) {
          ProgressView().controlSize(.small)
        } else if let live, !model.busy && model.observedBoundarySide(of: live) != (saved.placement != .menuBar) {
          Button(L("Retry")) { model.retryPlacement(saved.id) }
        }
        Picker(L("Placement"), selection: Binding(get: { saved.placement }, set: { model.setPlacement(saved.id, $0) })) {
          ForEach(Placement.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().frame(width: 145).accessibilityLabel(L("Placement") + ": " + model.name(for: saved.id))
      } else if live != nil {
        Image(systemName: "lock").accessibilityLabel(L("Protected — kept visible"))
      }
    }
  }
}

struct DropdownView: View {
  @ObservedObject var model: AppModel
  let maximumWidth: CGFloat
  var focusesSettings = false
  var onDismiss: () -> Void = {}
  static func columnCount(rowCapacity: Int, controlCount: Int, maximumWidth: CGFloat) -> Int {
    max(1, min(rowCapacity, controlCount, Int((maximumWidth - 24) / 44)))
  }
  static func contentWidth(columns: Int, hasFooter: Bool) -> CGFloat {
    max(hasFooter ? 180 : 0, CGFloat(columns * 44 + 20))
  }
  private var columns: Int {
    Self.columnCount(rowCapacity: model.layout.rowCapacity,
      controlCount: model.dropdownItems.count + 1, maximumWidth: maximumWidth)
  }
  private var gridHeight: CGFloat {
    let rows = (model.dropdownItems.count + 1 + columns - 1) / columns
    return CGFloat(rows * 34 + (rows - 1) * 8 + 4)
  }
  private var showsEmptyGuidance: Bool {
    model.canEdit && !model.layout.items.contains { $0.placement == .dropdown }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        DropdownIcons(model: model, columns: columns, focusesSettings: focusesSettings)
      }.frame(height: min(300, gridHeight))
      if showsEmptyGuidance {
        Text(L("Add items to Dropdown in Settings.")).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(width: Self.contentWidth(columns: columns, hasFooter: showsEmptyGuidance))
    .onExitCommand(perform: onDismiss)
  }
}

struct DropdownIcons: View {
  @ObservedObject var model: AppModel
  @AppStorage("dropdownGlyphs") private var showGlyphs = false
  @FocusState private var settingsFocused: Bool
  @AccessibilityFocusState private var settingsAccessibilityFocused: Bool
  let columns: Int
  var interactive = true
  var focusesSettings = false

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: columns), alignment: .center, spacing: 8) {
      if interactive {
        Button { model.showSettings?() } label: {
          Image(systemName: "gearshape").font(.system(size: 21)).frame(width: 34, height: 34)
        }.help(L("Open Settings")).accessibilityLabel(L("Open Settings"))
          .focused($settingsFocused)
          .accessibilityFocused($settingsAccessibilityFocused)
          .task {
            guard focusesSettings else { return }
            settingsFocused = true
            settingsAccessibilityFocused = true
          }
      } else {
        Image(systemName: "gearshape").font(.system(size: 21)).frame(width: 34, height: 34)
          .accessibilityLabel(L("Settings preview"))
      }
      ForEach(model.dropdownItems, id: \.observation.runtimeID) { item in
        let bundle = item.identity.persistentKey ?? ""
        if interactive {
          Button { model.activate(item) } label: {
            proxy(item, bundle: bundle)
          }
          .disabled(!model.canEdit || !model.isManageable(item))
          .help(model.proxyImages[bundle] != nil && item.observation.isOnscreen != true
            ? model.name(for: bundle) + " — " + L("as last seen in the menu bar") : model.name(for: bundle))
          .accessibilityLabel(model.name(for: bundle))
          .contextMenu {
            Button(L("Open Secondary Menu")) { model.activate(item, secondary: true) }
              .disabled(!model.canEdit || !model.isManageable(item))
          }
        } else {
          Image(nsImage: model.icon(for: bundle)).resizable().frame(width: 26, height: 26).padding(4)
            .opacity(model.isManageable(item) ? 1 : 0.4)
            .help(model.name(for: bundle))
            .accessibilityLabel(model.name(for: bundle) + " — " + L("Dropdown preview"))
        }
      }
    }.buttonStyle(.borderless).padding(2)
    .task(id: interactive) {
      guard interactive else { return }
      while !Task.isCancelled {
        model.refreshProxyImages()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// The app icon by default: large and recognizable. The item's last onscreen
  /// menu-bar pixels (Screen Recording) only when the user prefers them.
  @ViewBuilder private func proxy(_ item: ClassifiedSourceItem, bundle: String) -> some View {
    if showGlyphs, let captured = model.proxyImages[bundle] {
      // ponytail: fixed 34pt cell; wide text items scale down. Variable-width
      // cells if that reads badly on real bars.
      // Template glyphs take the label color like in the menu bar; colored
      // icons keep their pixels. No backdrop either way.
      Image(nsImage: captured.image)
        .renderingMode(captured.isMonochrome ? .template : .original)
        .resizable().aspectRatio(contentMode: .fit)
        .foregroundStyle(Color.primary)
        .frame(maxWidth: 30, maxHeight: 22)
        .frame(width: 34, height: 34)
    } else {
      Image(nsImage: model.icon(for: bundle)).resizable().frame(width: 26, height: 26).padding(4)
    }
  }
}

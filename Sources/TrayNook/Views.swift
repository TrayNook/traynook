import AppKit
import SwiftUI
import InventoryIdentityCore

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var confirmReset = false
  @State private var showLocked = false

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
        Button(L("Refresh")) { model.refresh() }.disabled(model.busy || model.scanning)
        Button(L("Quit TrayNook")) { NSApp.terminate(nil) }
      }.padding(14)
    }
    .frame(minWidth: 760, minHeight: 590)
    .background(Color(nsColor: .windowBackgroundColor))
    .alert(L("Reset saved layout?"), isPresented: $confirmReset) {
      Button(L("Cancel"), role: .cancel) {}
      Button(L("Reset Layout"), role: .destructive) { model.resetLayout() }
    } message: {
      Text(L("This deletes saved placements and order. All items will be revealed. Privacy permissions and Launch at Login are unchanged."))
    }
  }

  private var layout: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Choose where each app appears. Changes apply automatically."))
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let setup = model.native.setupMessage {
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
          ForEach(Placement.allCases) { zone in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(zone.title).font(.headline)
                Text("\(model.layout.items.filter { $0.placement == zone }.count)").foregroundStyle(.secondary)
                Spacer()
                if zone == .menuBar { Label(L("TrayNook stays here"), systemImage: "tray.full").font(.caption).foregroundStyle(.secondary) }
              }
              let savedItems = model.layout.items.filter { $0.placement == zone }
              // Locked items carry no decision; one row stands for all of them.
              let locked = savedItems.filter { saved in model.liveItem(saved.id).map { !model.isManageable($0) } ?? false }
              if savedItems.isEmpty {
                Text(L("No items here yet")).foregroundStyle(.secondary).padding(.vertical, 8)
              }
              ForEach(savedItems.filter { saved in !locked.contains { $0.id == saved.id } }) { item in itemRow(item) }
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
            .dropDestination(for: String.self) { bundles, _ in
              guard bundles.count == 1, let bundle = bundles.first, model.canEdit,
                let item = model.liveItem(bundle), model.isManageable(item) else { return false }
              model.setPlacement(bundle, zone)
              return true
            }
          }
          if model.layout.items.isEmpty {
            Text(L("Grant Accessibility, then refresh to discover your menu-bar items."))
              .foregroundStyle(.secondary).padding(.vertical, 12)
          }
        }
      }
      Text(L("Opening an item brings only that item into view. It returns when its menu closes. Other hidden items stay hidden."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.padding(12)
  }

  private func itemRow(_ saved: SavedItem) -> some View {
    HStack(spacing: 10) {
      Image(nsImage: model.icon(for: saved.id)).resizable().frame(width: 26, height: 26).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.name(for: saved.id)).lineLimit(1)
        Text(model.status(for: saved)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let live = model.liveItem(saved.id), model.isManageable(live) {
        if saved.placement == .dropdown {
          let ordered = model.layout.items.filter { $0.placement == .dropdown }
          Button { model.reorder(saved.id, delta: -1) } label: { Image(systemName: "arrow.up") }
            .help(L("Move earlier in dropdown order")).accessibilityLabel(L("Move earlier in dropdown order"))
            .disabled(ordered.first?.id == saved.id)
          Button { model.reorder(saved.id, delta: 1) } label: { Image(systemName: "arrow.down") }
            .help(L("Move later in dropdown order")).accessibilityLabel(L("Move later in dropdown order"))
            .disabled(ordered.last?.id == saved.id)
        }
        Picker(L("Placement"), selection: Binding(get: { saved.placement }, set: { model.setPlacement(saved.id, $0) })) {
          ForEach(Placement.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().frame(width: 145).accessibilityLabel(L("Placement") + ": " + model.name(for: saved.id))
        if model.native.isBehindBoundary(live) != (saved.placement != .menuBar) {
          Button(L("Retry")) { model.setPlacement(saved.id, saved.placement) }
        }
      } else if model.liveItem(saved.id) == nil {
        Button(L("Forget")) { model.forget(saved.id) }
      } else {
        Image(systemName: "lock").accessibilityLabel(L("Protected — kept visible"))
      }
    }
    .disabled(!model.canEdit)
    .padding(.vertical, 3)
    .draggable(saved.id)
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label(L("Accessibility"), systemImage: model.permissionGranted ? "checkmark.shield" : "hand.raised")
        .font(.title3.bold())
      Text(L("TrayNook needs Accessibility to identify menu-bar items, apply your chosen placements, and open items from the dropdown. Until permission is granted, it leaves your menu bar visible."))
        .fixedSize(horizontal: false, vertical: true)
      Text(model.permissionGranted ? L("Granted") : L("Not granted")).font(.headline)
      HStack {
        if !model.permissionGranted { Button(L("Grant Accessibility…")) { model.requestAccessibility() } }
        Button(L("Open System Settings…")) { model.openAccessibilitySettings() }
      }
      if !model.permissionGranted {
        Text(L("Add this whole app in Privacy & Security → Accessibility. After rebuilding an ad-hoc development app, you may need to remove the old entry and grant the new build. Then click Refresh."))
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      Label(L("Screen Recording"), systemImage: model.screenRecordingGranted ? "checkmark.shield" : "rectangle.dashed.badge.record")
        .font(.title3.bold())
      Text(L("Optional. With Screen Recording, the dropdown shows each item's real menu-bar icon as last seen while it was visible. Without it, TrayNook shows application icons. Captured pixels stay in memory for this session only and are never saved."))
        .fixedSize(horizontal: false, vertical: true)
      Text(model.screenRecordingGranted ? L("Granted") : L("Not granted")).font(.headline)
      HStack {
        if !model.screenRecordingGranted { Button(L("Grant Screen Recording…")) { model.requestScreenRecording() } }
        Button(L("Open System Settings…")) { model.openScreenRecordingSettings() }
      }
      if !model.screenRecordingGranted {
        Text(L("macOS applies Screen Recording after TrayNook is quit and reopened."))
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }.padding(20)
  }

  private var general: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Toggle(L("Launch at Login"), isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
        LayoutPreviewView(model: model)
        Divider()
        HStack {
          Button(L("Copy Diagnostics")) { model.copyDiagnostics() }
          Button(L("Reset Layout…")) { confirmReset = true }.disabled(model.busy)
        }
        Text(L("TrayNook stores bundle identities, sibling discriminators, placements, order, and row capacity locally. It makes no network requests and includes no analytics or updater."))
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Divider()
        Text(L("To uninstall, turn off Launch at Login, quit TrayNook, and move the app to Trash. Quit removes TrayNook’s separator and reveals items. You can remove its Accessibility entry in System Settings."))
          .font(.callout).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Text("TrayNook 1.0.0 · Local MVP preview\n© 2026 Suren Khorenyan · MIT License")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }
  }
}

struct DropdownView: View {
  @ObservedObject var model: AppModel
  let maximumWidth: CGFloat
  static func columnCount(rowCapacity: Int, controlCount: Int, maximumWidth: CGFloat) -> Int {
    max(1, min(rowCapacity, controlCount, Int((maximumWidth - 24) / 44)))
  }
  private var columns: Int {
    Self.columnCount(rowCapacity: model.layout.rowCapacity,
      controlCount: model.dropdownItems.count + 1, maximumWidth: maximumWidth)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        DropdownIcons(model: model, columns: columns)
      }.frame(height: min(300, CGFloat((model.dropdownItems.count + 1 + columns - 1) / columns) * 44))
      if model.dropdownItems.isEmpty {
        Text(L("Add items to Dropdown in Settings.")).font(.caption).foregroundStyle(.secondary)
      }
      if model.busy {
        ProgressView().controlSize(.small)
      } else if let message = model.message {
        Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
      }
      if !model.concealed && !model.busy {
        Button(L("Hide Items")) { model.applySavedLayout() }.disabled(!model.canEdit)
      }
    }
    .padding(12)
    .frame(width: max(180, CGFloat(columns * 44 + 20)))
  }
}

struct DropdownIcons: View {
  @ObservedObject var model: AppModel
  let columns: Int
  var interactive = true

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: columns), alignment: .leading, spacing: 8) {
      if interactive {
        Button { model.showSettings?() } label: {
          Image(systemName: "gearshape").font(.system(size: 21)).frame(width: 34, height: 34)
        }.help(L("Open Settings")).accessibilityLabel(L("Open Settings"))
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

  /// The item's last onscreen menu-bar pixels when Screen Recording allows it,
  /// on a backdrop matching the menu bar the glyph was drawn for; otherwise
  /// the app icon.
  @ViewBuilder private func proxy(_ item: ClassifiedSourceItem, bundle: String) -> some View {
    if let captured = model.proxyImages[bundle] {
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

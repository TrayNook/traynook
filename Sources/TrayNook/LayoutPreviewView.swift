import AppKit
import SwiftUI

/// A schematic of saved homes, using the same icons and grid as the dropdown.
struct LayoutPreviewView: View {
  @ObservedObject var model: AppModel
  @State private var availableWidth: CGFloat = 650

  private var columns: Int {
    DropdownView.columnCount(rowCapacity: model.layout.rowCapacity,
      controlCount: model.dropdownItems.count + 1,
      maximumWidth: min(700, availableWidth - 88))
  }

  func items(in placement: Placement) -> [SavedItem] {
    model.layout.items.filter { saved in
      let observed = model.items.filter { $0.observation.bundleIdentifier == saved.id }
      guard !observed.isEmpty else { return false }
      let protected = observed.count > 1 || observed.contains { !model.isManageable($0) }
      switch placement {
      case .menuBar: return saved.placement == .menuBar || protected
      case .dropdown: return saved.placement == .dropdown && observed.count == 1
      case .alwaysHidden: return saved.placement == .alwaysHidden && !protected
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L("Saved layout preview")).font(.headline)
        Spacer()
        Stepper(value: Binding(get: { model.layout.rowCapacity }, set: { model.setRowCapacity($0) }), in: 1...30) {
          Text(L("Controls per dropdown row") + ": \(model.layout.rowCapacity)").font(.caption)
        }
        .fixedSize().disabled(model.recoveryRequired || model.busy)
        .help(L("The settings button occupies the first slot. Rows wrap earlier on narrow displays."))
      }
      if !model.permissionGranted || !model.scanComplete {
        Text(L("Waiting for a fresh inventory")).font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        Text(L("Menu Bar")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(items(in: .menuBar)) { item in previewIcon(item, size: 20) }
          }.frame(maxWidth: .infinity, alignment: .trailing).padding(.vertical, 3)
        }
        .frame(width: min(CGFloat(max(0, items(in: .menuBar).count * 32 - 12)), max(0, availableWidth - 152)))
        .scrollIndicators(.hidden)
        Divider().frame(height: 20)
        Image(systemName: "tray.full").font(.system(size: 20))
          .frame(width: 32, height: 30)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
          .accessibilityLabel(L("TrayNook launcher preview"))
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35)))

      // ponytail: preview wraps to its available width, like the real popover;
      // exact native status images/spacing need capture and are outside this MVP.
      GeometryReader { geometry in
        HStack(alignment: .top) {
          Text(L("Dropdown")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.top, 17)
          Spacer(minLength: 12)
          VStack(alignment: .trailing, spacing: 0) {
            Image(systemName: "arrowtriangle.up.fill").font(.system(size: 10))
              .foregroundStyle(.quaternary).padding(.trailing, 23)
              .accessibilityHidden(true)
            ScrollView {
              DropdownIcons(model: model, columns: columns, interactive: false)
                .padding(10)
            }
            .frame(width: max(180, CGFloat(columns * 44 + 20)))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35)))
          }
        }
        .onAppear { availableWidth = geometry.size.width }
        .onChange(of: geometry.size.width) { _, width in availableWidth = width }
      }
      .frame(height: dropdownHeight)

      HStack(spacing: 10) {
        Label(L("Always Hidden"), systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
          .help(L("Kept out of the menu bar and dropdown until you choose Show Items."))
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            ForEach(items(in: .alwaysHidden)) { item in previewIcon(item, size: 18) }
            if items(in: .alwaysHidden).isEmpty {
              Text(L("No items")).font(.caption).foregroundStyle(.tertiary)
            }
          }
        }.scrollIndicators(.hidden)
      }
      Text(L("Application icons; menu-bar order and spacing may differ."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("layout-preview")
  }

  private var dropdownHeight: CGFloat {
    let rows = (model.dropdownItems.count + 1 + columns - 1) / columns
    return min(176, CGFloat(rows * 44 + 28))
  }

  private func previewIcon(_ item: SavedItem, size: CGFloat) -> some View {
    let count = model.items.filter { $0.observation.bundleIdentifier == item.id }.count
    let protected = model.liveItem(item.id).map { !model.isManageable($0) } ?? true
    return Image(nsImage: model.icon(for: item.id)).resizable().frame(width: size, height: size)
      .overlay(alignment: .bottomTrailing) {
        if protected {
          Image(systemName: "lock.fill").font(.system(size: 8))
            .padding(2).background(.background, in: Circle()).offset(x: 5, y: 3)
        }
      }
      .help(model.name(for: item.id) + " — " + model.status(for: item)
        + (count > 1 ? " (\(count))" : ""))
      .accessibilityLabel(model.name(for: item.id) + " — "
        + (protected ? Placement.menuBar.title : item.placement.title) + " — " + L("Preview"))
  }
}

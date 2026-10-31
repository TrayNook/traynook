import AppKit
import SwiftUI

/// A schematic of saved homes; dragging edits a local draft until the drop.
struct LayoutPreviewView: View {
  @ObservedObject var model: AppModel
  @StateObject private var drag = PreviewDragSession()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection
  @State private var availableWidth: CGFloat = 650
  @State private var iconFrames: [String: CGRect] = [:]
  @State private var zoneFrames: [Placement: CGRect] = [:]

  private var layout: SavedLayout { drag.draft ?? model.layout }
  private var columns: Int {
    DropdownView.columnCount(rowCapacity: layout.rowCapacity,
      controlCount: max(items(in: .dropdown).count, model.dropdownItems.count) + 1,
      maximumWidth: min(700, availableWidth - 88))
  }

  func items(in placement: Placement) -> [SavedItem] {
    layout.items.filter { saved in
      guard let live = model.liveItem(saved.id) else { return false }
      let protected = !model.isManageable(live)
      switch placement {
      case .menuBar: return saved.placement == .menuBar || protected
      case .dropdown: return saved.placement == .dropdown && !protected
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
        .fixedSize().disabled(model.recoveryRequired || model.busy || drag.key != nil)
        .help(L("The settings button occupies the first slot. Rows wrap earlier on narrow displays."))
      }
      if !model.permissionGranted || !model.scanComplete {
        Text(L("Waiting for a fresh inventory")).font(.caption).foregroundStyle(.secondary)
      }
      menuBar
      dropdown
      alwaysHidden
      Text(L("Drag icons to reorder or move between zones. Escape cancels."))
        .font(.caption).foregroundStyle(.secondary)
      Text(L("Application icons; menu-bar order and spacing may differ."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .background(PreviewDragSurface(session: drag))
    .coordinateSpace(name: "preview-drag")
    .overlay(alignment: .topLeading) {
      if let image = drag.image, drag.key != nil {
        PreviewFloatingIcon(pointer: drag.pointer, image: image)
      }
    }
    .accessibilityIdentifier("layout-preview")
    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: drag.draft)
    .onPreferenceChange(PreviewIconFrames.self) { iconFrames = $0 }
    .onPreferenceChange(PreviewZoneFrames.self) { zoneFrames = $0 }
    .onChange(of: model.layout) { _, _ in drag.cancel() }
    .onChange(of: model.canEdit) { _, editable in if !editable { drag.cancel() } }
    .onDisappear { drag.cancel() }
  }

  private var menuBar: some View {
    HStack(spacing: 12) {
      Text(L("Menu Bar")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      Spacer(minLength: 0)
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          ForEach(items(in: .menuBar)) { item in previewIcon(item, in: .menuBar, size: 20, cell: 32) }
        }.frame(maxWidth: .infinity, alignment: .trailing).padding(.vertical, 3)
      }
      .frame(width: min(CGFloat(items(in: .menuBar).count * 36), max(0, availableWidth - 152)))
      .scrollIndicators(.hidden)
      Divider().frame(height: 20)
      Image(systemName: "tray.full").font(.system(size: 20))
        .frame(width: 32, height: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel(L("TrayNook launcher preview"))
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .modifier(PreviewDropZone(placement: .menuBar, drag: drag))
  }

  private var dropdown: some View {
    GeometryReader { geometry in
      HStack(alignment: .top) {
        Text(L("Dropdown")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
          .padding(.top, 17)
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 0) {
          Image(systemName: "arrowtriangle.up.fill").font(.system(size: 10))
            .foregroundStyle(.quaternary).padding(.trailing, 23).accessibilityHidden(true)
          ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: columns),
              alignment: .center, spacing: 8) {
              Image(systemName: "gearshape").font(.system(size: 21)).frame(width: 36, height: 36)
                .accessibilityLabel(L("Settings preview"))
              ForEach(items(in: .dropdown)) { item in
                previewIcon(item, in: .dropdown, size: 26, cell: 36)
              }
            }.padding(12)
          }
          .frame(width: DropdownView.contentWidth(columns: columns, hasFooter: false))
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
          .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35)))
        }
      }
      .modifier(PreviewDropZone(placement: .dropdown, drag: drag, outlineAtRest: false))
      .onAppear { availableWidth = geometry.size.width }
      .onChange(of: geometry.size.width) { _, width in availableWidth = width }
    }
    .frame(height: dropdownHeight)
  }

  private var alwaysHidden: some View {
    HStack(spacing: 10) {
      Label(L("Always Hidden"), systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
        .help(L("Kept out of the menu bar and dropdown until you choose Show Items."))
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          ForEach(items(in: .alwaysHidden)) { item in previewIcon(item, in: .alwaysHidden, size: 18, cell: 30) }
          if items(in: .alwaysHidden).isEmpty {
            Text(L("No items")).font(.caption).foregroundStyle(.tertiary)
          }
        }
      }.scrollIndicators(.hidden)
    }
    .frame(minHeight: 36)
    .padding(.horizontal, 4)
    .modifier(PreviewDropZone(placement: .alwaysHidden, drag: drag, outlineAtRest: false))
  }

  private var dropdownHeight: CGFloat {
    let rows = (max(items(in: .dropdown).count, model.dropdownItems.count) + 1 + columns - 1) / columns
    return min(176, CGFloat(rows * 44 + 28))
  }

  private func insertionKey(at point: CGPoint, in placement: Placement) -> String? {
    let candidates = items(in: placement).filter { $0.id != drag.key && $0.placement == placement }
      .compactMap { item in iconFrames[item.id].map { (key: item.id, frame: $0) } }
    return PreviewDropTarget.insertionKey(at: point, items: candidates, rightToLeft: layoutDirection == .rightToLeft)
  }

  private func previewIcon(_ item: SavedItem, in placement: Placement, size: CGFloat, cell: CGFloat) -> some View {
    let protected = model.liveItem(item.id).map { !model.isManageable($0) } ?? true
    let image = model.icon(for: item.id)
    return Image(nsImage: image).resizable().frame(width: size, height: size)
      .overlay(alignment: .bottomTrailing) {
        if protected {
          Image(systemName: "lock.fill").font(.system(size: 8))
            .padding(2).background(.background, in: Circle()).offset(x: 5, y: 3)
        }
      }
      .frame(width: cell, height: 36)
      .opacity(drag.key == item.id ? 0 : 1)
      .background {
        if drag.key == item.id {
          RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
      }
      .background(GeometryReader { geometry in
        Color.clear.preference(key: PreviewIconFrames.self,
          value: [item.id: geometry.frame(in: .named("preview-drag"))])
      })
      .overlay {
        if !protected && model.canEdit {
          PreviewDragSource { down, event in
            guard model.canEdit, let original = model.liveItem(item.id), let frame = iconFrames[item.id] else { return }
            guard drag.begin(item.id, layout: model.layout, commit: { key, zone, anchor in
              guard let current = model.liveItem(key),
                NativeMenuBarController.preservesSourceIdentity(original: original, current: current) else { return false }
              return model.commitPreviewMove(key, to: zone, before: anchor)
            }) else { return }
            _ = drag.track(from: down, event: event, image: image, cell: frame) { point in
              if let zone = Placement.allCases.first(where: { zoneFrames[$0]?.contains(point) == true }) {
                drag.move(to: zone, before: insertionKey(at: point, in: zone))
              } else if let zone = drag.hoveredZone { drag.leave(zone) }
            }
          }
        }
      }
      .help(model.name(for: item.id) + " — " + (protected ? L("Protected — kept visible") : item.placement.title)
        + (protected ? "" : " — " + L("Drag to reorder or move")))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.name(for: item.id) + " — "
        + (protected ? Placement.menuBar.title : item.placement.title) + " — " + L("Preview"))
  }
}

private struct PreviewIconFrames: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct PreviewZoneFrames: PreferenceKey {
  static let defaultValue: [Placement: CGRect] = [:]
  static func reduce(value: inout [Placement: CGRect], nextValue: () -> [Placement: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct PreviewDropZone: ViewModifier {
  let placement: Placement
  @ObservedObject var drag: PreviewDragSession
  var outlineAtRest = true

  func body(content: Content) -> some View {
    content
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
        drag.key != nil && drag.hoveredZone == placement ? Color.accentColor
          : (outlineAtRest ? Color(nsColor: .separatorColor).opacity(0.35) : .clear),
        lineWidth: drag.key != nil && drag.hoveredZone == placement ? 2 : 1).allowsHitTesting(false))
      .background(GeometryReader { geometry in
        Color.clear.preference(key: PreviewZoneFrames.self,
          value: [placement: geometry.frame(in: .named("preview-drag"))])
      })
  }
}

import HasalaDesign
import HasalaModels
import SwiftUI

struct WidgetCanvasActions {
  var opens: (HomeCanvasItem) -> Bool = { _ in false }
  var open: (HomeCanvasItem) -> Void = { _ in }
  var setEditing: (Bool) -> Void = { _ in }
  var add: () -> Void = {}
  var remove: (HomeCanvasItem) -> Void = { _ in }
  var move: (HomeCanvasItem, Int) -> Void = { _, _ in }
  var moveBy: (HomeCanvasItem, Int) -> Void = { _, _ in }
  var configure: (HomeCanvasItem) -> Void = { _ in }
}

/// Canvas · Your widgets (Paper 14PE-0; edit mode "Home · Edit widgets (edit mode)"): "Your
/// widgets" 22/28 bold with "Edit", then the widgets in the person's order, 12 apart. Mediums
/// take a full row; smalls pair two to a row and a pair shares one height; a lone small keeps
/// its width. At the accessibility text sizes the canvas is one column. The dashed "Add widget"
/// tile ends it.
///
/// In edit mode nothing jiggles: each widget wears an ink minus disc at its top-left corner
/// and a white grip on its top edge. A long press lifts a widget and dropping it on another
/// takes that place, with a light tap on lift and a selection tick at each move; VoiceOver
/// offers "Move up", "Move down" and "Remove" instead. Outside edit mode a long press offers "Edit Home".
struct WidgetCanvas: View {
  var title = "Your widgets"
  let items: [HomeCanvasItem]
  let hidden: Bool
  let editable: Bool
  let editing: Bool
  var actions = WidgetCanvasActions()

  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dragging: String?
  @State private var lifts = 0
  @State private var passes = 0
  @State private var drops = 0

  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
  }

  private var rows: [[HomeCanvasItem]] {
    typeSize.isAccessibilitySize ? items.map { [$0] } : items.canvasRows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if editing {
        Text("Drag a widget to move it. Tap − to take it off Home.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .padding(.top, -4)
          .padding(.bottom, 18)
          .hTransition(.fade)
          .accessibilityIdentifier("home.editHint")
      }
      if items.isEmpty, editable {
        emptyNote
      }
      ForEach(rows, id: \.first?.id) { row in
        HStack(spacing: HSpacing.widgetGutter) {
          ForEach(row) { item in cell(item) }
          if row.count == 1, row[0].size == .small, !typeSize.isAccessibilitySize {
            Color.clear.frame(maxWidth: .infinity)
          }
        }
        // Small widgets fill the row's height (at least 175 pt), so a pair stays even.
        .fixedSize(horizontal: false, vertical: true)
      }
      if editable {
        AddWidgetTile { actions.add() }
          .accessibilityIdentifier("home.addWidget")
          .padding(.top, 12)
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
    .animation(motion.animation(.fade), value: editing)
    .hHaptic(.impactLight, trigger: lifts)
    .hHaptic(.selection, trigger: passes)
    .hHaptic(.impactLight, trigger: drops)
    .onChange(of: editing) { _, now in if !now { dragging = nil } }
  }

  /// "Your widgets" with "Edit" or "Done" 17/24 in the link blue, on one baseline.
  private var header: some View {
    ReflowingRow(alignment: .firstTextBaseline) {
      Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
    } trailing: {
      if editable, editing || !items.isEmpty {
        Button { actions.setEditing(!editing) } label: {
          Text(editing ? "Done" : "Edit")
            .hType(editing ? .textButton.weight(.semibold) : .textButton)
            .foregroundStyle(HColor.textLink)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10)
        .accessibilityLabel(editing ? "Done editing widgets" : "Edit widgets")
        .accessibilityIdentifier(editing ? "home.doneWidgets" : "home.editWidgets")
      }
    }
  }

  private var emptyNote: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Home is just the month for now").hType(.headline).foregroundStyle(HColor.textPrimary)
      Text("Add a widget to keep a bill, a goal or a category in view. Anything you add stays on this iPhone.")
        .hType(.subheadline).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("home.widgetsEmpty")
  }

  @ViewBuilder private func cell(_ item: HomeCanvasItem) -> some View {
    let shape = RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)
    Group {
      if editing {
        editingCell(item)
      } else if actions.opens(item) {
        Button { actions.open(item) } label: { HomeCanvasItemView(item, hidden: hidden) }
          .buttonStyle(HPressStyle(in: shape))
          .accessibilityIdentifier("widget.\(item.id)")
          .contextMenu { menu(item) }
      } else {
        HomeCanvasItemView(item, hidden: hidden)
          .contentShape(.contextMenuPreview, shape)
          .contextMenu { menu(item) }
          .accessibilityIdentifier("widget.\(item.id)")
      }
    }
  }

  @ViewBuilder private func menu(_ item: HomeCanvasItem) -> some View {
    if editable {
      Button { actions.setEditing(true) } label: { Label("Edit Home", systemImage: "square.grid.2x2") }
      if item.kind.configurable {
        Button { actions.configure(item) } label: { Label(changeLabel(item), systemImage: "slider.horizontal.3") }
      }
      Button(role: .destructive) { actions.remove(item) } label: { Label("Remove", systemImage: "minus.circle") }
    }
  }

  private func changeLabel(_ item: HomeCanvasItem) -> String {
    switch item.kind.configKind {
    case .category?: "Change category"
    case .project?: "Change project"
    case .goal?: "Change goal"
    case nil: "Change"
    }
  }

  private func editingCell(_ item: HomeCanvasItem) -> some View {
    let index = items.firstIndex { $0.id == item.id } ?? 0
    return Group {
      if item.kind.configurable {
        Button { actions.configure(item) } label: { HomeCanvasItemView(item, hidden: hidden) }
          .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)))
          .accessibilityHint(changeLabel(item))
      } else {
        HomeCanvasItemView(item, hidden: hidden)
      }
    }
    .accessibilityIdentifier("widget.\(item.id)")
    .accessibilityAction(named: "Move up") { if index > 0 { actions.moveBy(item, -1) } }
    .accessibilityAction(named: "Move down") { if index < items.count - 1 { actions.moveBy(item, 1) } }
    .accessibilityAction(named: "Remove") { actions.remove(item) }
    .overlay(alignment: .topLeading) { removeButton(item).offset(x: -16, y: -16) }
    .overlay(alignment: .top) { grip.offset(y: -22) }
    .onDrag {
      dragging = item.id
      lifts += 1
      return NSItemProvider(object: item.id as NSString)
    } preview: {
      HomeCanvasItemView(item, hidden: hidden)
        .frame(width: item.size == .small ? HContainer.widgetUnit : HContainer.widgetWide)
    }
    .onDrop(of: [.text], delegate: CanvasDropDelegate(target: item.id, items: items.map(\.id), dragging: $dragging) { id, to in
      guard let moved = items.first(where: { $0.id == id }) else { return }
      withHMotion(.thumbSlide, motion) { actions.move(moved, to) }
      passes += 1
    } dropped: { drops += 1 })
  }

  private func removeButton(_ item: HomeCanvasItem) -> some View {
    Button { actions.remove(item) } label: {
      Circle().fill(HColor.ink900).frame(width: 28, height: 28)
        .overlay { Capsule().fill(HColor.white).frame(width: 10, height: 2.4) }
        .hElevation(.nearFar)
        .frame(width: HSpacing.targetMinimum, height: HSpacing.targetMinimum)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove \(item.title)")
    .accessibilityIdentifier("widget.\(item.id).remove")
    .hTransition(.fade)
  }

  private var grip: some View {
    Capsule().fill(HColor.white).frame(width: 40, height: 22)
      .overlay {
        VStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { _ in
            Capsule().fill(HColor.iconSecondary).frame(width: 14, height: 1.8)
          }
        }
      }
      .hElevation(.nearFar)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .hTransition(.fade)
  }
}

struct CanvasDropDelegate: DropDelegate {
  let target: String
  let items: [String]
  @Binding var dragging: String?
  let move: (String, Int) -> Void
  let dropped: () -> Void

  func dropEntered(info: DropInfo) {
    guard let id = dragging, id != target, let to = items.firstIndex(of: target) else { return }
    move(id, to)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

  func performDrop(info: DropInfo) -> Bool {
    guard dragging != nil else { return false }
    dragging = nil
    dropped()
    return true
  }
}

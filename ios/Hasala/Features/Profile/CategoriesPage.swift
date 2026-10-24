import HasalaDesign
import HasalaModels
import SwiftUI

@MainActor
@Observable
final class CategoriesViewModel {
  private let app: AppModel
  @ObservationIgnored private var memo = Memo<Int, CategoriesSnapshot>()

  init(app: AppModel) { self.app = app }

  var snapshot: CategoriesSnapshot { memo.value(for: app.store.revision) { CategoriesEngine.snapshot(app.store.state) } }

  func open(_ id: CategoryID?) { app.router.profile.append(.categoryEditor(id)) }

  func restore(_ id: CategoryID) {
    let before = app.store.state
    if let why = app.refusal(applying: .restoreCategory(id)) {
      app.say(why, icon: .info)
    } else if let line = CategoriesEngine.toast(.restoreCategory(id), before: before) {
      app.say(line)
    }
  }
}

struct CategoriesList: View {
  @Bindable var app: AppModel
  @State private var model: CategoriesViewModel
  @State private var showArchived = false

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: CategoriesViewModel(app: app))
  }

  var body: some View {
    let snap = model.snapshot
    VStack(alignment: .leading, spacing: 16) {
      Text(snap.capLine)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("categories.capLine")
      HListCard { addRow(snap) }
      ForEach(snap.sections) { section in
        VStack(alignment: .leading, spacing: 8) {
          OverlineHeader(section.title)
          HListCard {
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
              if index > 0 { HDivider(inset: .disc68) }
              Button { model.open(row.id) } label: {
                HListRow(
                  leading: .disc(row.hue, row.glyph.icon), title: row.name, supporting: row.supporting.map { .text($0) },
                  trailing: row.hidden ? .status(StatusPill("Hidden", tone: .accent, showsDot: false)) : .chevron)
              }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("category.\(row.id)")
            }
          }
        }
      }
      if !snap.archived.isEmpty { archived(snap) }
    }
  }

  @ViewBuilder private func addRow(_ snap: CategoriesSnapshot) -> some View {
    if snap.canAdd {
      Button { model.open(nil) } label: {
        HListRow(leading: .icon22(.add, color: HColor.listRowAction), title: "Add category", trailing: .chevron,
                 titleColor: HColor.listRowAction)
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier("categories.add")
    } else {
      Button {} label: {
        HListRow(leading: .icon22(.add, color: HColor.textSecondary), title: "Add category",
                 supporting: .wrapping(CategoryLimits.addAtCap), titleColor: HColor.textSecondary)
      }
      .buttonStyle(.plain)
      .disabled(true)
      .accessibilityIdentifier("categories.add")
    }
  }

  private func archived(_ snap: CategoriesSnapshot) -> some View {
    HListCard {
      Button { withAnimation(.easeOut(duration: 0.2)) { showArchived.toggle() } } label: {
        HListRow(title: "Archived (\(snap.archived.count))", trailing: .value(showArchived ? "Hide" : "Show"))
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier("categories.archived")
      if showArchived {
        ForEach(snap.archived) { row in
          HDivider(inset: .disc68)
          Button { model.restore(row.id) } label: {
            HListRow(
              leading: .disc(row.hue, row.glyph.icon), title: row.name, supporting: row.supporting.map { .text($0) },
              trailing: .value("Restore"))
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityIdentifier("category.\(row.id)")
        }
      }
    }
  }
}

@MainActor
@Observable
final class CategoryEditorModel {
  private let app: AppModel
  let id: CategoryID?
  var name: String {
    didSet { if isNew, !glyphPicked { glyph = CategoryIconGuess.glyph(for: name) } }
  }
  var glyph: Glyph
  private(set) var glyphPicked = false
  var parent: CategoryID?
  var refusal: String?
  var confirmArchive = false

  init(app: AppModel, category id: CategoryID?) {
    self.app = app
    self.id = id
    let c = id.flatMap { app.store.state.category($0) }
    name = c?.name ?? ""
    glyph = c?.glyph ?? .tag
    parent = c?.parent
  }

  var category: HasalaModels.Category? { id.flatMap { app.store.state.category($0) } }
  var isNew: Bool { id == nil }
  var exists: Bool { isNew || category != nil }
  var isBuiltin: Bool { category?.builtin ?? false }
  var canHide: Bool { isBuiltin && !CategoryLimits.isSystem(id ?? "") }
  var isHidden: Bool { category?.archived ?? false }
  var parentOptional: Bool { !isNew && !isBuiltin && category?.parent == nil }
  var parentLabel: String { parentName ?? (parentOptional ? "None" : "Choose a category") }
  var hidden: Bool { app.amountsHidden }
  var countsAs: [CountsAsOption] {
    CategoriesEngine.countsAsOptions(app.store.state, keeping: [parent, category?.parent])
  }
  var parentName: String? { CategoriesEngine.countsAsTitle(parent, in: app.store.state) }
  var moveTargets: [CategorySectionModel] { id.map { CategoriesEngine.moveTargets(app.store.state, from: $0) } ?? [] }

  var hue: Hue {
    if let p = parent, let c = app.store.state.category(p) { return c.hue }
    return category?.hue ?? .other
  }

  var parentNote: String? {
    guard !isBuiltin, let p = parent, let to = app.store.state.category(p) else { return nil }
    let section = CategoriesEngine.section(to.bucket)
    guard let c = category else { return "Its spending counts in \(section)." }
    if c.parent == p { return nil }
    return CategoriesEngine.section(c.bucket) == section
      ? "Past spending stays in \(section)." : "Past spending moves to \(section)."
  }

  var impact: CategoryImpact? {
    id.flatMap { CategoriesEngine.impact(app.store.state, $0, month: app.store.month) }
  }

  var archiveTitle: String {
    let n = category?.name ?? ""
    return isBuiltin ? "Hide \u{201C}\(n)\u{201D}?" : "Archive \u{201C}\(n)\u{201D}?"
  }

  var impactMessage: String { impact?.lines(hidden: hidden).joined(separator: "\n") ?? "" }

  var draft: CategoryDraft { CategoryDraft(name: name, glyph: glyph, parent: isBuiltin ? nil : parent) }

  func pick(_ g: Glyph) {
    glyph = g
    glyphPicked = true
  }

  func save() {
    if isNew, parent == nil {
      refusal = CategoryLimits.parentNotAllowed
      return
    }
    let edit: LedgerEdit = id.map { .editCategory($0, draft) } ?? .addCategory(draft)
    let before = app.store.state
    if let why = app.refusal(applying: edit) {
      refusal = why
      return
    }
    refusal = nil
    if let line = CategoriesEngine.toast(edit, before: before) { app.say(line) }
    close()
  }

  func requestArchive() {
    if let why = archiveBlock {
      refusal = why
      return
    }
    refusal = nil
    confirmArchive = true
  }

  var archiveBlock: String? {
    guard let c = category else { return nil }
    return CategoriesEngine.archiveRefusal(c, moveTo: nil, in: app.store.state)
  }

  func archive(moveTo: CategoryID? = nil) {
    guard let id else { return }
    let edit = LedgerEdit.archiveCategory(id, moveTo: moveTo)
    let before = app.store.state
    if let why = app.refusal(applying: edit) {
      refusal = why
      return
    }
    if let line = CategoriesEngine.toast(edit, before: before) { app.say(line) }
    if moveTo != nil || !isBuiltin {
      app.router.profile.removeAll { $0 == .categoryMove(id) || $0 == .categoryEditor(id) }
    }
  }

  func setHidden(_ on: Bool) {
    guard let id else { return }
    if on {
      requestArchive()
      return
    }
    let before = app.store.state
    if let why = app.refusal(applying: .restoreCategory(id)) {
      refusal = why
    } else if let line = CategoriesEngine.toast(.restoreCategory(id), before: before) {
      app.say(line)
    }
  }

  func chooseMoveTarget() {
    guard let id else { return }
    app.router.profile.append(.categoryMove(id))
  }

  func close() {
    if app.router.profile.last == .categoryEditor(id) { app.router.profile.removeLast() }
  }
}

struct CategoryEditorPage: View {
  @Bindable var app: AppModel
  @State private var model: CategoryEditorModel
  @FocusState private var nameFocused: Bool

  init(app: AppModel, category: CategoryID?) {
    self.app = app
    _model = State(initialValue: CategoryEditorModel(app: app, category: category))
  }

  var body: some View {
    ScrollView {
      if model.exists { form } else { gone }
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle(model.isNew ? "New category" : "Edit category")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { nameFocused = false }
      }
    }
    .confirmationDialog(model.archiveTitle, isPresented: $model.confirmArchive, titleVisibility: .visible) {
      Button(model.isBuiltin ? "Hide" : "Archive", role: .destructive) { model.archive() }
        .accessibilityIdentifier("categoryEditor.archiveConfirm")
      if !model.isBuiltin, !model.moveTargets.isEmpty {
        Button("Archive and move to\u{2026}") { model.chooseMoveTarget() }
          .accessibilityIdentifier("categoryEditor.archiveMove")
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(model.impactMessage)
    }
  }

  private var gone: some View {
    Text(CategoryLimits.unknown)
      .hType(.body)
      .foregroundStyle(HColor.textSecondary)
      .padding(HSpacing.insetPage)
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 20) {
      CategoryNameIconForm(
        name: $model.name, glyph: Binding(get: { model.glyph }, set: { model.pick($0) }), hue: model.hue,
        nameFocus: $nameFocused
      ) {
        if !model.isBuiltin { parentField }
      }
      if model.canHide {
        Toggle(isOn: Binding(get: { model.isHidden }, set: { model.setHidden($0) })) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Hide").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            Text("Hidden categories leave the lists you pick from. Their transactions keep them.")
              .hType(.footnote).foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 8)
        }
        .tint(HColor.controlSwitchTrackOn)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
        .accessibilityIdentifier("categoryEditor.hide")
      }
      if let why = model.refusal {
        Text(why).hType(.footnote).foregroundStyle(HColor.statusErrorForeground)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("categoryEditor.refusal")
      }
      Button(model.isNew ? "Add category" : "Save") { model.save() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("categoryEditor.save")
      if !model.isNew, !model.isBuiltin, model.category?.archived == false {
        Button("Archive category") { model.requestArchive() }
          .buttonStyle(.pill(.destructiveQuiet, fill: true))
          .accessibilityIdentifier("categoryEditor.archive")
      }
    }
    .padding(HSpacing.insetPage)
  }

  private var parentField: some View {
    CategoryFormField("Counts as") {
      VStack(alignment: .leading, spacing: 6) {
        Menu {
          if model.parentOptional {
            Button("None") { model.parent = nil }
              .accessibilityIdentifier("categoryEditor.parent.none")
          }
          ForEach(model.countsAs) { option in
            Button { model.parent = option.parent } label: {
              if option.parent == model.parent {
                Label(option.title, systemImage: "checkmark")
              } else {
                Text(option.title)
              }
            }
            .accessibilityIdentifier("categoryEditor.parent.\(option.id)")
          }
        } label: {
          HListRow(title: model.parentLabel, trailing: .chevron)
            .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Counts as")
        .accessibilityValue(model.parentOptional ? model.parentLabel : (model.parentName ?? "Not chosen"))
        .accessibilityIdentifier("categoryEditor.parent")
        if let note = model.parentNote {
          Text(note).hType(.footnote).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("categoryEditor.parentNote")
        }
      }
    }
  }
}

struct CategoryMovePage: View {
  @Bindable var app: AppModel
  @State private var model: CategoryEditorModel

  init(app: AppModel, category: CategoryID) {
    self.app = app
    _model = State(initialValue: CategoryEditorModel(app: app, category: category))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(intro)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
        if let why = model.refusal {
          Text(why).hType(.footnote).foregroundStyle(HColor.statusErrorForeground)
            .accessibilityIdentifier("categoryMove.refusal")
        }
        ForEach(model.moveTargets) { group in
          VStack(alignment: .leading, spacing: 8) {
            OverlineHeader(group.title)
            HListCard {
              ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { HDivider(inset: .disc68) }
                Button { model.archive(moveTo: row.id) } label: {
                  HListRow(
                    leading: .disc(row.hue, row.glyph.icon), title: row.name,
                    supporting: row.supporting.map { .text($0) })
                }
                .buttonStyle(HRowPressStyle())
                .accessibilityIdentifier("categoryMove.\(row.id)")
              }
            }
          }
        }
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Move to")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var intro: String {
    let name = model.category?.name ?? ""
    let n = model.id.map { CategoriesEngine.movableCount(app.store.state, $0) } ?? 0
    let rows = n == 1 ? "Its 1 transaction moves" : "Its \(n) transactions move"
    return "\(rows) to the category you choose, then \(name) is archived."
  }
}

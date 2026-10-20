import HasalaDesign
import HasalaModels
import SwiftUI

@MainActor
@Observable
final class ProjectEditorModel {
  private let app: AppModel
  let project: ProjectID?
  var name: String
  var budgetText: String
  var glyph: Glyph
  var hasStart: Bool
  var start: Date
  var hasEnd: Bool
  var end: Date
  var countInPlan: Bool
  var refusal: String?
  private let decimalSeparator: String

  init(app: AppModel, project: ProjectID?, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") {
    self.app = app
    self.project = project
    self.decimalSeparator = decimalSeparator
    let d = project.flatMap { app.store.state.project($0)?.draft } ?? ProjectDraft(name: "")
    let today = ProjectDates.date(app.store.now.date)
    name = d.name
    budgetText = d.budget.map { MoneyFormat.draft($0.minor) } ?? ""
    glyph = d.glyph
    hasStart = d.starts != nil
    start = d.starts.map(ProjectDates.date) ?? today
    hasEnd = d.ends != nil
    end = d.ends.map(ProjectDates.date) ?? today
    countInPlan = d.countInPlan
  }

  var isNew: Bool { project == nil }
  var exists: Bool { project.map { app.store.state.project($0) != nil } ?? true }

  var draft: ProjectDraft? {
    let trimmed = budgetText.trimmingCharacters(in: .whitespaces)
    var budget: Money?
    if !trimmed.isEmpty {
      guard let minor = MoneyFormat.parseMinor(trimmed, decimalSeparator: decimalSeparator) else { return nil }
      budget = .aed(minor)
    }
    return ProjectDraft(
      name: name, glyph: glyph, budget: budget, starts: hasStart ? ProjectDates.local(start) : nil,
      ends: hasEnd ? ProjectDates.local(end) : nil, countInPlan: countInPlan)
  }

  func save() {
    guard let d = draft else {
      refusal = "Enter the money set aside as an amount, like 8,000"
      return
    }
    if let why = d.refusal {
      refusal = why
      return
    }
    refusal = nil
    let id = project ?? app.store.newProjectID()
    guard app.perform(.saveProject(id, d)) else { return }
    app.say(isNew ? "\(d.name.trimmingCharacters(in: .whitespacesAndNewlines)) created" : "Project saved", icon: nil)
    app.projectSaved(id, created: isNew)
  }

  func cancel() {
    if app.projectsInProfile, app.router.profile.last == .editProject(project) {
      app.router.profile.removeLast()
    } else {
      app.router.sheet = nil
    }
  }
}

enum ProjectDates {
  static let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 4 * 3600) ?? .current
    return c
  }()

  static func date(_ d: LocalDate) -> Date {
    calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12)) ?? Date()
  }

  static func local(_ d: Date) -> LocalDate {
    let c = calendar.dateComponents([.year, .month, .day], from: d)
    return LocalDate(c.year ?? 1970, c.month ?? 1, c.day ?? 1)
  }
}

struct ProjectEditorSheet: View {
  @Bindable var app: AppModel
  let project: ProjectID?

  var body: some View {
    NavigationStack {
      ProjectEditorView(app: app, project: project, inSheet: true)
    }
    .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    .planLargeSheet()
  }
}

struct ProjectEditorView: View {
  @Bindable var app: AppModel
  let inSheet: Bool
  @State private var model: ProjectEditorModel
  @FocusState private var focused: Field?

  enum Field { case name, budget }

  init(app: AppModel, project: ProjectID?, inSheet: Bool = false) {
    self.app = app
    self.inSheet = inSheet
    _model = State(initialValue: ProjectEditorModel(app: app, project: project))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        field("Name") {
          TextField("Kitchen refresh", text: $model.name)
            .hType(.body)
            .foregroundStyle(HColor.fieldText)
            .textInputAutocapitalization(.words)
            .focused($focused, equals: .name)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
            .accessibilityLabel("Name")
            .accessibilityIdentifier("projectEditor.name")
        }
        field("Budget") {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Text("AED").hType(.body.weight(.semibold)).foregroundStyle(HColor.textSecondary)
                .accessibilityHidden(true)
              TextField("No budget", text: $model.budgetText)
                .hType(.body.weight(.semibold))
                .foregroundStyle(HColor.fieldText)
                .keyboardType(.decimalPad)
                .focused($focused, equals: .budget)
                .accessibilityLabel("Money set aside, in dirhams")
                .accessibilityIdentifier("projectEditor.budget")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
            Text("The money set aside for it. Leave it empty for no budget.").hType(.footnote).foregroundStyle(HColor.textSecondary)
              .padding(.horizontal, 4)
          }
        }
        field("Icon") {
          FlowLayout(spacing: 12) {
            ForEach(ProjectDraft.glyphs, id: \.self) { g in
              Button { model.glyph = g } label: {
                CategoryDisc(hue: .peach, icon: g.icon, size: .s40)
                  .padding(3)
                  .overlay { Circle().strokeBorder(model.glyph == g ? Hue.peach.ink : .clear, lineWidth: 2) }
                  .frame(minWidth: 44, minHeight: 44)
                  .contentShape(Circle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel(Self.glyphName(g))
              .accessibilityAddTraits(model.glyph == g ? [.isSelected] : [])
              .accessibilityIdentifier("projectEditor.icon.\(g.rawValue)")
            }
          }
        }
        VStack(spacing: 0) {
          Toggle(isOn: $model.hasStart.animation(.default)) {
            Text("Start date").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          }
          .tint(HColor.controlSwitchTrackOn)
          .frame(minHeight: 52)
          .accessibilityIdentifier("projectEditor.hasStart")
          if model.hasStart {
            DatePicker("Starts", selection: $model.start, displayedComponents: .date)
              .environment(\.timeZone, ProjectDates.calendar.timeZone)
              .hType(.body)
              .frame(minHeight: 52)
              .accessibilityIdentifier("projectEditor.start")
          }
          HDivider(inset: .none)
          Toggle(isOn: $model.hasEnd.animation(.default)) {
            Text("End date").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          }
          .tint(HColor.controlSwitchTrackOn)
          .frame(minHeight: 52)
          .accessibilityIdentifier("projectEditor.hasEnd")
          if model.hasEnd {
            DatePicker("Ends", selection: $model.end, displayedComponents: .date)
              .environment(\.timeZone, ProjectDates.calendar.timeZone)
              .hType(.body)
              .frame(minHeight: 52)
              .accessibilityIdentifier("projectEditor.end")
          }
          HDivider(inset: .none)
          Toggle(isOn: $model.countInPlan) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Count in monthly plan").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
              Text("Off keeps its spending out of your monthly budgets.")
                .hType(.footnote).foregroundStyle(HColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
          }
          .tint(HColor.controlSwitchTrackOn)
          .frame(minHeight: 52)
          .accessibilityIdentifier("projectEditor.countInPlan")
        }
        .padding(.horizontal, 16)
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))

        if let why = model.refusal {
          Text(why).hType(.footnote).foregroundStyle(HColor.statusErrorForeground)
            .accessibilityIdentifier("projectEditor.refusal")
        }
        Button(model.isNew ? "Create project" : "Save") { model.save() }
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("projectEditor.save")
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle(model.isNew ? "New project" : "Edit project")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if inSheet { SheetCloseButton(identifier: "projectEditor.close") { model.cancel() } }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { focused = nil }
      }
    }
  }

  private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
        .accessibilityAddTraits(.isHeader)
      content()
    }
  }

  static func glyphName(_ g: Glyph) -> String {
    switch g {
    case .flag: "Flag"
    case .travel: "Plane"
    case .rent: "House"
    case .shopping: "Bag"
    case .savingsJar: "Jar"
    case .entertainment: "Ticket"
    case .healthcare: "Health"
    case .transport: "Car"
    default: g.rawValue
    }
  }
}

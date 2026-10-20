import HasalaDesign
import HasalaModels
import SwiftUI

struct AddTransactionHost: View {
  let app: AppModel
  @State private var model: AddTransactionModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: AddTransactionModel(app: app))
  }

  var body: some View { AddTransactionSheet(model: model) }
}

struct AddTransactionSheet: View {
  @Bindable var model: AddTransactionModel
  @State private var choosingCategory = false
  @FocusState private var merchantFocused: Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Picker("Kind", selection: $model.direction) {
            Text("Money out").tag(Direction.out)
            Text("Money in").tag(Direction.in)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("add.direction")
          AmountFigure(entry: model.entry, caret: !merchantFocused, layout: .docked)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Amount")
            .accessibilityValue(model.entry.spoken())
            .accessibilityIdentifier("add.amount")
          field("Merchant") {
            TextField("Where or who", text: $model.merchant)
              .hType(.body)
              .foregroundStyle(HColor.fieldText)
              .textInputAutocapitalization(.words)
              .autocorrectionDisabled()
              .submitLabel(.done)
              .focused($merchantFocused)
              .padding(.horizontal, 16)
              .frame(minHeight: 52)
              .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
              .accessibilityLabel("Merchant")
              .accessibilityIdentifier("add.merchant")
          }
          details
          if let missing = model.missing {
            Text(missing).hType(.footnote).foregroundStyle(HColor.textSecondary)
              .padding(.horizontal, 4)
              .accessibilityIdentifier("add.missing")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 16)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(HColor.sheetSurfaceLarge)
      .safeAreaInset(edge: .bottom, spacing: 0) { dock }
      .navigationTitle("Add transaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "add.close") { model.cancel() }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { merchantFocused = false }
        }
      }
      .navigationDestination(isPresented: $choosingCategory) {
        AddCategoryPage(groups: model.categoryGroups, selected: model.categoryID) { id in
          model.categoryID = id
          choosingCategory = false
        }
      }
    }
    .planLargeSheet()
  }

  private var dock: some View {
    VStack(spacing: 0) {
      Button(model.saveTitle) { model.save() }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(!model.canSave)
        .accessibilityIdentifier("add.save")
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 12)
        .padding(.bottom, 16)
      if !merchantFocused {
        AmountKeypad(entry: $model.entry, layout: .docked)
      }
    }
    .background(HColor.sheetSurfaceLarge.ignoresSafeArea(edges: .bottom))
  }

  private var details: some View {
    VStack(spacing: 0) {
      Button {
        merchantFocused = false
        choosingCategory = true
      } label: {
        detailRow(icon: .tag, title: "Category") {
          if let c = model.category {
            HStack(spacing: 6) {
              Circle().fill(c.hue.ink).frame(width: 8, height: 8).accessibilityHidden(true)
              Text(c.name).foregroundStyle(HColor.textPrimary)
            }
          } else {
            Text("Choose").foregroundStyle(HColor.textLink)
          }
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
        }
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityLabel("Category, \(model.category?.name ?? "not chosen")")
      .accessibilityIdentifier("add.category")
      HDivider(inset: .text16)
      detailRow(icon: .calendar, title: "Date") {
        DatePicker("Date", selection: $model.postedAt, in: ...model.latest, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .environment(\.timeZone, ProjectDates.calendar.timeZone)
          .accessibilityIdentifier("add.date")
      }
      if !model.accounts.isEmpty {
        HDivider(inset: .text16)
        detailRow(icon: .bank, title: "Paid with") {
          Menu {
            Picker("Paid with", selection: $model.accountID) {
              Text("Not set").tag(AccountID?.none)
              ForEach(model.accounts) { a in Text(a.label).tag(AccountID?.some(a.id)) }
            }
          } label: {
            HStack(spacing: 4) {
              Text(model.account?.label ?? "Not set").foregroundStyle(HColor.textLink)
              HIconView(.chevronDown, size: 14, color: HColor.textLink)
            }
          }
          .accessibilityLabel("Paid with, \(model.account?.label ?? "not set")")
          .accessibilityIdentifier("add.account")
        }
      }
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private func detailRow(icon: HIcon, title: String, @ViewBuilder trailing: () -> some View) -> some View {
    ReflowingRow(spacing: 12) {
      HStack(spacing: 12) {
        HIconView(icon, size: 20, color: HColor.iconPrimary)
        Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
      }
    } trailing: {
      HStack(spacing: 8) { trailing() }.hType(.body)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .padding(.leading, 4)
        .accessibilityAddTraits(.isHeader)
      content()
    }
  }
}

struct AddCategoryPage: View {
  let groups: [CategoryGroup]
  let selected: CategoryID?
  let choose: (CategoryID) -> Void
  @State private var query = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 10) {
          HIconView(.magnifier, size: 20, color: HColor.fieldIcon)
          TextField("Search categories", text: $query)
            .hType(.body)
            .foregroundStyle(HColor.fieldText)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .accessibilityIdentifier("addCategory.search")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        ForEach(filtered) { g in
          VStack(alignment: .leading, spacing: 8) {
            Text(g.bucket.label).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
              .padding(.leading, 4).padding(.top, 2)
              .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 8) {
              ForEach(g.options) { o in
                ChoiceChip(o.name, dot: o.hue, selected: selected == o.id) { choose(o.id) }
                  .accessibilityIdentifier("addCategory.\(o.id)")
              }
            }
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Category")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var filtered: [CategoryGroup] {
    let q = query.trimmedSpaces.lowercased()
    guard !q.isEmpty else { return groups.filter { !$0.options.isEmpty } }
    return groups.map { CategoryGroup(bucket: $0.bucket, options: $0.options.filter { $0.name.lowercased().contains(q) }) }
      .filter { !$0.options.isEmpty }
  }
}

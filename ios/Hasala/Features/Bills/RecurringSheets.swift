import HasalaDesign
import HasalaModels
import SwiftUI

enum RecurringSheet: Identifiable, Hashable {
  case add
  case editAmount(BillID)
  case pause(BillID)
  case end(BillID)
  case link(BillID)
  case salary(BillID)

  var id: String {
    switch self {
    case .add: "add"
    case .editAmount(let id): "amount.\(id)"
    case .pause(let id): "pause.\(id)"
    case .end(let id): "end.\(id)"
    case .link(let id): "link.\(id)"
    case .salary(let id): "salary.\(id)"
    }
  }
}

struct RecurringSheetHost: View {
  let app: AppModel
  let sheet: RecurringSheet

  var body: some View {
    NavigationStack {
      switch sheet {
      case .add: AddRecurringSheet(app: app)
      case .editAmount(let id): EditAmountSheet(app: app, bill: id)
      case .pause(let id): PauseBillSheet(app: app, bill: id)
      case .end(let id): EndBillSheet(app: app, bill: id)
      case .link(let id): LinkPaymentsSheet(app: app, bill: id)
      case .salary(let id): SalaryEditSheet(app: app, bill: id)
      }
    }
    .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    .planLargeSheet()
  }
}

struct RecurringForm<Content: View, Dock: View>: View {
  let title: String
  let closeID: String
  @ViewBuilder let content: () -> Content
  @ViewBuilder let dock: () -> Dock
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) { content() }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(HColor.sheetSurfaceLarge)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 8) { dock() }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(HColor.sheetSurfaceLarge.ignoresSafeArea(edges: .bottom))
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      SheetCloseButton(identifier: closeID) { dismiss() }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
      }
    }
  }
}

struct RecurringField<Content: View>: View {
  let title: String
  var footer: String?
  @ViewBuilder let content: () -> Content

  init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
        .accessibilityAddTraits(.isHeader)
      content()
      if let footer {
        Text(footer).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
    }
  }
}

struct RecurringCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) { content() }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

struct RecurringTextField: View {
  let placeholder: String
  @Binding var text: String
  let label: String
  let id: String
  var amount = false

  var body: some View {
    HStack(spacing: 8) {
      if amount {
        Text("AED").hType(.body.weight(.semibold)).foregroundStyle(HColor.textSecondary).accessibilityHidden(true)
      }
      TextField(placeholder, text: $text, axis: .vertical)
        .lineLimit(1...4)
        .hType(amount ? .body.weight(.semibold) : .body)
        .foregroundStyle(HColor.fieldText)
        .keyboardType(amount ? .decimalPad : .default)
        .textInputAutocapitalization(amount ? .never : .words)
        .autocorrectionDisabled()
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 52)
    .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
  }
}

struct RecurringChoiceRow: View {
  let title: String
  var detail: String?
  let selected: Bool
  let id: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        RadioMark(selected: selected)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          if let detail {
            Text(detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier(id)
  }
}

struct RecurringRow<Trailing: View>: View {
  let icon: HIcon
  let title: String
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
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
}

struct PastPaymentsList: View {
  let payments: [PastPayment]
  @Binding var ticked: Set<TxnID>
  let hidden: Bool

  var body: some View {
    RecurringCard {
      ForEach(Array(payments.enumerated()), id: \.element.id) { index, p in
        if index > 0 { HDivider(inset: .text16) }
        let on = ticked.contains(p.id)
        Button {
          if on { ticked.remove(p.id) } else { ticked.insert(p.id) }
        } label: {
          HStack(spacing: 12) {
            RadioMark(selected: on)
            VStack(alignment: .leading, spacing: 2) {
              Text(p.merchant).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
              Text(Self.line(p)).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MoneyText(p.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3, color: HColor.moneyOut)
              .fixedSize()
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
          .contentShape(Rectangle())
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(p, hidden: hidden))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("bills.past.\(p.id)")
      }
    }
  }

  static func line(_ p: PastPayment) -> String {
    [p.date.short, p.account].compactMap { $0 }.joined(separator: " · ")
  }

  static func spoken(_ p: PastPayment, hidden: Bool) -> String {
    let amount = hidden ? "Amount hidden" : "\(p.amount.currency) \(MoneyFormat.string(p.amount.minor))"
    return [p.merchant, line(p), amount].joined(separator: ", ")
  }
}

enum RecurringCopy {
  static func every(_ n: Int, _ cadence: BillCadence) -> String {
    let unit = unit(cadence)
    return n <= 1 ? "Every \(unit)" : "Every \(n) \(unit)s"
  }

  static func unit(_ cadence: BillCadence) -> String {
    switch cadence {
    case .weekly: "week"
    case .monthly: "month"
    case .yearly: "year"
    }
  }

  static func link(_ n: Int) -> String {
    n == 1 ? "1 payment" : "\(n) payments"
  }

  static func positiveMinor(_ text: String, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> Int64? {
    guard let m = MoneyFormat.parseMinor(text.trimmingCharacters(in: .whitespaces), decimalSeparator: decimalSeparator),
      m > 0
    else { return nil }
    return m
  }
}

@MainActor
@Observable
final class AddRecurringModel {
  private let app: AppModel
  var name = ""
  var amountText = ""
  var varies = false
  var cadence: BillCadence = .monthly {
    didSet { every = min(every, cadence.maxEvery) }
  }
  var every = 1
  var firstDue: Date
  var categoryID: CategoryID?
  var accountID: AccountID?
  var keys: [String] = []
  var seed: TxnID?
  var ticked: Set<TxnID> = []
  private let decimalSeparator: String

  init(app: AppModel, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") {
    self.app = app
    self.decimalSeparator = decimalSeparator
    firstDue = ProjectDates.date(app.store.now.date)
    categoryID = BillsEngine.defaultCategory(app.store.state)
  }

  var hidden: Bool { app.amountsHidden }
  var state: LedgerState { app.store.state }
  var accounts: [Account] { state.accounts }
  var account: Account? { accountID.flatMap { id in accounts.first { $0.id == id } } }
  var category: HasalaModels.Category? { categoryID.flatMap { state.category($0) } }
  var seedPayment: Txn? { seed.flatMap { state.txn($0) } }
  var recent: [RecentPayment] { BillsEngine.recentPayments(state, now: app.store.now) }

  var minor: Int64? { RecurringCopy.positiveMinor(amountText, decimalSeparator: decimalSeparator) }

  var draft: BillDraft? {
    guard let minor, let categoryID else { return nil }
    let d = BillDraft(
      name: name, keys: keys, amount: .aed(minor), approximate: varies, cadence: cadence, every: every,
      firstDue: ProjectDates.local(firstDue), categoryID: categoryID, accountID: accountID,
      linkTxns: ticked.sorted())
    return d.refusal == nil ? d : nil
  }

  var missing: String? {
    if name.trimmedSpaces.isEmpty { return "Add a name" }
    if name.trimmedSpaces.count > BillDraft.maxNameLength { return "Keep the name to \(BillDraft.maxNameLength) characters" }
    if minor == nil { return "Enter the amount" }
    if categoryID == nil { return "Choose a category" }
    return nil
  }

  var suggestions: [PastPayment] {
    guard var d = draft else { return [] }
    d.linkTxns = []
    return BillsEngine.pastPayments(state, for: d)
  }

  func start(from txn: TxnID) {
    guard let d = BillsEngine.draft(from: txn, state, now: app.store.now) else { return }
    seed = txn
    name = d.name
    keys = d.keys
    amountText = MoneyFormat.draft(d.amount.minor)
    cadence = .monthly
    every = 1
    firstDue = ProjectDates.date(d.firstDue)
    if state.category(d.categoryID) != nil { categoryID = d.categoryID }
    if let a = d.accountID, accounts.contains(where: { $0.id == a }) { accountID = a }
    ticked = []
  }

  func clearSeed() {
    seed = nil
    keys = []
  }

  @discardableResult
  func save() -> Bool {
    guard var d = draft else { return false }
    let valid = Set(suggestions.map(\.id))
    d.linkTxns = ticked.filter { valid.contains($0) }.sorted()
    return app.perform(.addBill(d))
  }
}

struct AddRecurringSheet: View {
  @State private var model: AddRecurringModel
  @State private var step: Step?
  @Environment(\.dismiss) private var dismiss

  enum Step: Hashable { case category, payment, past }

  init(app: AppModel) {
    _model = State(initialValue: AddRecurringModel(app: app))
  }

  var body: some View {
    RecurringForm(title: "Add recurring", closeID: "bills.add.close") {
      fromPayment
      RecurringField("Name") {
        RecurringTextField(placeholder: "Netflix, rent, gym", text: $model.name, label: "Name", id: "bills.add.name")
      }
      RecurringField("Amount") {
        VStack(spacing: 12) {
          RecurringTextField(placeholder: "0.00", text: $model.amountText, label: "Amount, in dirhams",
                             id: "bills.add.amount", amount: true)
          RecurringCard {
            Toggle(isOn: $model.varies) {
              VStack(alignment: .leading, spacing: 2) {
                Text("The amount varies").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
                Text("Shown with ~, like a utility bill.").hType(.footnote).foregroundStyle(HColor.textSecondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 8)
            }
            .tint(HColor.controlSwitchTrackOn)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .accessibilityIdentifier("bills.add.varies")
          }
        }
      }
      RecurringField("How often") {
        VStack(spacing: 12) {
          Picker("Repeats", selection: $model.cadence) {
            Text("Weekly").tag(BillCadence.weekly)
            Text("Monthly").tag(BillCadence.monthly)
            Text("Yearly").tag(BillCadence.yearly)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("bills.add.cadence")
          RecurringCard {
            Stepper(value: $model.every, in: 1...model.cadence.maxEvery) {
              Text(RecurringCopy.every(model.every, model.cadence)).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .accessibilityIdentifier("bills.add.every")
            HDivider(inset: .text16)
            RecurringRow(icon: .calendar, title: "First payment") {
              DatePicker("First payment", selection: $model.firstDue, displayedComponents: .date)
                .labelsHidden()
                .environment(\.timeZone, ProjectDates.calendar.timeZone)
                .accessibilityIdentifier("bills.add.firstDue")
            }
          }
        }
      }
      details
      if let missing = model.missing {
        Text(missing).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .padding(.horizontal, 4)
          .accessibilityIdentifier("bills.add.missing")
      }
    } dock: {
      let more = !model.suggestions.isEmpty
      Button(more ? "Next" : "Add") {
        if more { step = .past } else if model.save() { dismiss() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .pillHeight()
      .disabled(model.draft == nil)
      .accessibilityIdentifier(more ? "bills.add.next" : "bills.add.save")
    }
    .navigationDestination(item: $step) { step in
      switch step {
      case .category:
        RecurringCategoryPage(state: model.state, selected: model.categoryID) { id in
          model.categoryID = id
          self.step = nil
        }
      case .payment:
        RecentPaymentsPage(payments: model.recent, hidden: model.hidden) { id in
          model.start(from: id)
          self.step = nil
        }
      case .past:
        AddPastPaymentsPage(model: model) { dismiss() }
      }
    }
  }

  @ViewBuilder private var fromPayment: some View {
    RecurringCard {
      Button { step = .payment } label: {
        RecurringRow(icon: .receipt, title: "Start from a payment") {
          if let seed = model.seedPayment {
            Text(seed.merchant).foregroundStyle(HColor.textPrimary).lineLimit(1)
          } else {
            Text("Choose").foregroundStyle(HColor.textLink)
          }
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
        }
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityLabel("Start from a payment, \(model.seedPayment?.merchant ?? "not chosen")")
      .accessibilityIdentifier("bills.add.fromPayment")
    }
  }

  private var details: some View {
    RecurringCard {
      Button { step = .category } label: {
        RecurringRow(icon: .tag, title: "Category") {
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
      .accessibilityIdentifier("bills.add.category")
      if !model.accounts.isEmpty {
        HDivider(inset: .text16)
        RecurringRow(icon: .bank, title: "Paid from") {
          Menu {
            Picker("Paid from", selection: $model.accountID) {
              Text("Not set").tag(AccountID?.none)
              ForEach(model.accounts) { a in Text(a.label).tag(AccountID?.some(a.id)) }
            }
          } label: {
            HStack(spacing: 4) {
              Text(model.account?.label ?? "Not set").foregroundStyle(HColor.textLink)
              HIconView(.chevronDown, size: 14, color: HColor.textLink)
            }
          }
          .accessibilityLabel("Paid from, \(model.account?.label ?? "not set")")
          .accessibilityIdentifier("bills.add.account")
        }
      }
    }
  }
}

struct AddPastPaymentsPage: View {
  @Bindable var model: AddRecurringModel
  let done: () -> Void

  var body: some View {
    let suggestions = model.suggestions
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("These payments look like \(model.name.trimmedSpaces). Tick the ones that paid it, and they count as its past payments.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
        PastPaymentsList(payments: suggestions, ticked: $model.ticked, hidden: model.hidden)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(HColor.sheetSurfaceLarge)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Button(model.ticked.isEmpty ? "Add without them" : "Add and link \(RecurringCopy.link(model.ticked.count))") {
        if model.save() { done() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .pillHeight()
      .disabled(model.draft == nil)
      .accessibilityIdentifier("bills.add.save")
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 12)
      .padding(.bottom, 16)
      .background(HColor.sheetSurfaceLarge.ignoresSafeArea(edges: .bottom))
    }
    .navigationTitle("Past payments")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct RecentPaymentsPage: View {
  let payments: [RecentPayment]
  let hidden: Bool
  let choose: (TxnID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if payments.isEmpty {
          EmptyNote(systemImage: "receipt", message: "No recent payments to start from.")
        } else {
          Text("Choose a payment, and its name, amount and day fill in.")
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
          RecurringCard {
            ForEach(Array(payments.enumerated()), id: \.element.id) { index, p in
              if index > 0 { HDivider(inset: .disc68) }
              Button { choose(p.id) } label: {
                HStack(spacing: HSpacing.listRowGap) {
                  CategoryDisc(hue: p.hue, glyph: p.glyph)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(p.merchant).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
                    Text(p.date.short).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  MoneyText(p.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3, color: HColor.moneyOut)
                    .fixedSize()
                }
                .padding(.horizontal, HSpacing.listRowInsetInline)
                .padding(.vertical, HSpacing.listRowInsetBlock)
                .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
                .contentShape(Rectangle())
              }
              .buttonStyle(HRowPressStyle())
              .accessibilityElement(children: .ignore)
              .accessibilityLabel([p.merchant, p.date.short,
                                   hidden ? "Amount hidden" : "\(p.amount.currency) \(MoneyFormat.string(p.amount.minor))"]
                .joined(separator: ", "))
              .accessibilityIdentifier("bills.recent.\(p.id)")
            }
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Start from a payment")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct RecurringCategoryPage: View {
  let state: LedgerState
  let selected: CategoryID?
  let choose: (CategoryID) -> Void

  var body: some View {
    let bills = BillsEngine.billCategories(state).map(CategoryOption.init)
    let billIDs = Set(bills.map(\.id))
    let groups = CategoryGroup.all(state)
      .map { CategoryGroup(bucket: $0.bucket, options: $0.options.filter { !billIDs.contains($0.id) }) }
      .filter { !$0.options.isEmpty }
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if !bills.isEmpty { group("Bills", bills) }
        ForEach(groups) { g in group(g.bucket.label, g.options) }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Category")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func group(_ title: String, _ options: [CategoryOption]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .padding(.leading, 4).padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
      FlowLayout(spacing: 8) {
        ForEach(options) { o in
          ChoiceChip(o.name, dot: o.hue, selected: selected == o.id) { choose(o.id) }
            .accessibilityIdentifier("bills.category.\(o.id)")
        }
      }
    }
  }
}

struct EditAmountSheet: View {
  let app: AppModel
  let bill: BillID
  @State private var amountText: String
  @State private var varies: Bool
  @State private var start: LocalDate?
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel, bill: BillID) {
    self.app = app
    self.bill = bill
    let b = app.store.state.bill(bill)
    _amountText = State(initialValue: b.map { MoneyFormat.draft(($0.nextAmount ?? $0.amount).minor) } ?? "")
    _varies = State(initialValue: b?.approximate ?? false)
    _start = State(initialValue: b.flatMap { BillsEngine.defaultAmountStart($0, today: app.store.now.date) })
  }

  private var b: Bill? { app.store.state.bill(bill) }
  private var minor: Int64? { RecurringCopy.positiveMinor(amountText) }

  var body: some View {
    let today = app.store.now.date
    let choices = b.map { BillsEngine.amountStarts($0, today: today) } ?? []
    let paid = b.flatMap(BillDueDates.latestPaid)
    RecurringForm(title: "Edit amount", closeID: "bills.amount.close") {
      RecurringField("Amount") {
        VStack(spacing: 12) {
          RecurringTextField(placeholder: "0.00", text: $amountText, label: "Amount, in dirhams",
                             id: "bills.amount.field", amount: true)
          RecurringCard {
            Toggle(isOn: $varies) {
              Text("The amount varies").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            }
            .tint(HColor.controlSwitchTrackOn)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .accessibilityIdentifier("bills.amount.varies")
          }
        }
      }
      RecurringField("Starting", footer: "Earlier payments keep their price.") {
        RecurringCard {
          ForEach(Array(choices.enumerated()), id: \.element) { index, date in
            if index > 0 { HDivider(inset: .text16) }
            RecurringChoiceRow(
              title: date.short,
              detail: date == paid ? "Last paid" : date == b?.nextDue ? "Next payment" : nil,
              selected: start == date, id: "bills.amount.start.\(date.ordinal)") { start = date }
          }
        }
      }
    } dock: {
      Button("Save") { save() }
        .buttonStyle(.pill(.primary, fill: true))
        .pillHeight()
        .disabled(minor == nil || start == nil || b == nil)
        .accessibilityIdentifier("bills.amount.save")
    }
  }

  private func save() {
    guard let b, let minor, let start else { return }
    if app.perform(.editBillAmount(bill, Money(minor: minor, currency: b.amount.currency), approximate: varies,
                                   from: start)) {
      dismiss()
    }
  }
}

struct PauseBillSheet: View {
  let app: AppModel
  let bill: BillID
  @State private var untilDate = false
  @State private var until: Date
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel, bill: BillID) {
    self.app = app
    self.bill = bill
    _until = State(initialValue: ProjectDates.date(app.store.now.date.adding(days: 30)))
  }

  var body: some View {
    let tomorrow = ProjectDates.date(app.store.now.date.adding(days: 1))
    RecurringForm(title: "Pause \(app.store.state.bill(bill)?.name ?? "")", closeID: "bills.pause.close") {
      RecurringField("Pause", footer: "While it's paused, nothing is expected and nothing is late.") {
        RecurringCard {
          RecurringChoiceRow(title: "Until I resume", selected: !untilDate, id: "bills.pause.untilResume") {
            withAnimation(.easeInOut(duration: 0.2)) { untilDate = false }
          }
          HDivider(inset: .text16)
          RecurringChoiceRow(title: "Until a date", selected: untilDate, id: "bills.pause.untilDate") {
            withAnimation(.easeInOut(duration: 0.2)) { untilDate = true }
          }
          if untilDate {
            HDivider(inset: .text16)
            RecurringRow(icon: .calendar, title: "Until") {
              DatePicker("Until", selection: $until, in: tomorrow..., displayedComponents: .date)
                .labelsHidden()
                .environment(\.timeZone, ProjectDates.calendar.timeZone)
                .accessibilityIdentifier("bills.pause.date")
            }
          }
        }
      }
    } dock: {
      Button("Pause") {
        if app.perform(.pauseBill(bill, until: untilDate ? ProjectDates.local(until) : nil)) { dismiss() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .pillHeight()
      .accessibilityIdentifier("bills.pause.save")
    }
  }
}

struct EndBillSheet: View {
  let app: AppModel
  let bill: BillID
  @State private var last: LocalDate?
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel, bill: BillID) {
    self.app = app
    self.bill = bill
    _last = State(initialValue: app.store.state.bill(bill).map { BillsEngine.defaultEnd($0, today: app.store.now.date) })
  }

  var body: some View {
    let today = app.store.now.date
    let b = app.store.state.bill(bill)
    let choices = b.map { BillsEngine.endChoices($0, today: today) } ?? []
    let paid = Set(b?.payments.map(\.due) ?? [])
    RecurringForm(title: "End \(b?.name ?? "")", closeID: "bills.end.close") {
      RecurringField("Last payment", footer: "Nothing is expected after this day. Its payments stay in Activity.") {
        RecurringCard {
          ForEach(Array(choices.enumerated()), id: \.element) { index, date in
            if index > 0 { HDivider(inset: .text16) }
            RecurringChoiceRow(
              title: date.short, detail: paid.contains(date) ? "Paid" : date == today ? "Today" : nil,
              selected: last == date, id: "bills.end.\(date.ordinal)") { last = date }
          }
        }
      }
    } dock: {
      Button("End it") {
        guard let last else { return }
        if app.perform(.endBill(bill, lastPayment: last)) { dismiss() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .pillHeight()
      .disabled(last == nil)
      .accessibilityIdentifier("bills.end.save")
    }
  }
}

struct LinkPaymentsSheet: View {
  let app: AppModel
  let bill: BillID
  @State private var ticked: Set<TxnID> = []
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let b = app.store.state.bill(bill)
    let payments = b.map { BillsEngine.pastPayments(app.store.state, for: $0) } ?? []
    RecurringForm(title: "Link past payments", closeID: "bills.link.close") {
      if payments.isEmpty {
        EmptyNote(systemImage: "link", message: "No other payments look like \(b?.name ?? "this one").")
          .accessibilityIdentifier("bills.link.empty")
      } else {
        Text("Tick the payments that paid \(b?.name ?? "it"). Nothing is linked until you do.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
        PastPaymentsList(payments: payments, ticked: $ticked, hidden: app.amountsHidden)
      }
    } dock: {
      Button(ticked.isEmpty ? "Link payments" : "Link \(RecurringCopy.link(ticked.count))") {
        let ids = payments.map(\.id).filter(ticked.contains)
        if app.perform(.linkBillPayments(bill, ids)) { dismiss() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .pillHeight()
      .disabled(ticked.isEmpty)
      .accessibilityIdentifier("bills.link.save")
    }
  }
}

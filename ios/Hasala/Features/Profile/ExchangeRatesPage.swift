import HasalaDesign
import HasalaModels
import SwiftUI

struct ExchangeRatesPage: View {
  @Bindable var app: AppModel

  private var page: ExchangeRates.Page { ExchangeRates.page(app.store.state) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        let page = page
        if !page.missing.isEmpty {
          section("Needs a rate") {
            ForEach(Array(page.missing.enumerated()), id: \.element.id) { index, row in
              if index > 0 { HDivider(inset: .text16) }
              link(row, supporting: row.notCounted > 0 ? .status(Self.notCountedLine(row.notCounted), .warning) : .text("No rate"),
                   trailing: .chevron)
            }
          }
        }
        section("Your rates") {
          ForEach(Array(page.rates.enumerated()), id: \.element.id) { index, row in
            if index > 0 { HDivider(inset: .text16) }
            link(row, supporting: .text(row.isPeg ? "Pegged rate" : "Your rate"),
                 trailing: .valueChevron(ExchangeRates.format(row.rateMicro ?? 0)))
          }
          if !page.rates.isEmpty { HDivider(inset: .text16) }
          Button { app.router.profile.append(.editRate(nil)) } label: {
            HListRow(title: "Add a currency", trailing: .chevron)
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityIdentifier("rates.add")
        }
        Text(Self.footnote)
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Exchange rates")
    .navigationBarTitleDisplayMode(.inline)
  }

  static let footnote =
    "AED for 1 unit of each currency. A rate counts that currency's transactions that aren't counted yet, and new ones, as estimates. Transactions already counted keep their rate."

  static func notCountedLine(_ n: Int) -> String {
    n == 1 ? "1 transaction not counted" : "\(n) transactions not counted"
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
      HListCard { content() }
    }
  }

  private func link(_ row: ExchangeRates.Row, supporting: HListRow.Supporting, trailing: HListRow.Trailing) -> some View {
    Button { app.router.profile.append(.editRate(row.currency)) } label: {
      HListRow(title: row.currency, supporting: supporting, trailing: trailing)
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityIdentifier("rates.\(row.currency)")
  }
}

struct RateEditorPage: View {
  @Bindable var app: AppModel
  let currency: String?

  @State private var code = ""
  @State private var rate = ""
  @State private var failure: String?
  @FocusState private var focus: Field?

  enum Field: Hashable { case code, rate }

  private var current: CurrencyRate? {
    currency.flatMap { c in app.store.state.rates.first { $0.currency == c } }
  }

  private var target: String { currency ?? ExchangeRates.normalizedCode(code) }
  private var peg: Int64? { ExchangeRates.pegs[target] }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if currency == nil {
          field("Currency code, like EUR", text: $code, id: "rate.code")
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($focus, equals: .code)
            .onSubmit { focus = .rate }
        }
        field("AED for 1 \(target.isEmpty ? "unit" : target)", text: $rate, id: "rate.value")
          .keyboardType(.decimalPad)
          .focused($focus, equals: .rate)
        if let failure {
          Text(failure).hType(.footnote).foregroundStyle(HColor.statusErrorForeground)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("rate.error")
        }
        if let peg, ExchangeRates.parse(rate) != peg {
          Button("Use the peg, \(ExchangeRates.format(peg))") {
            rate = ExchangeRates.format(peg)
            failure = nil
          }
          .buttonStyle(.pill(.secondary))
          .accessibilityIdentifier("rate.usePeg")
        }
        Text(RateEditorPage.note(target, peg: peg))
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
        Button("Save rate") { save() }
          .buttonStyle(.pill(.primary, fill: true))
          .disabled(rate.trimmingCharacters(in: .whitespaces).isEmpty || (currency == nil && code.isEmpty))
          .accessibilityIdentifier("rate.save")
          .padding(.top, 12)
        if current?.rateMicro != nil, let currency {
          Button("Remove rate", role: .destructive) {
            if app.perform(.unsetRate(currency: currency)) {
              app.say("\(currency) rate removed")
              pop()
            }
          }
          .buttonStyle(.pill(.secondary))
          .accessibilityIdentifier("rate.remove")
        }
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle(currency.map { "\($0) rate" } ?? "Add a currency")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      if let micro = current?.rateMicro { rate = ExchangeRates.format(micro) }
      focus = currency == nil ? .code : .rate
    }
  }

  static func note(_ currency: String, peg: Int64?) -> String {
    let removeLine = " Removing a rate leaves counted transactions as they are; new ones wait for a rate."
    guard peg != nil, !currency.isEmpty else {
      return "Use the rate on your card statement if you have it." + removeLine
    }
    return "\(currency) is pegged to the US dollar, so the peg is a close estimate. Your bank can charge a little more." + removeLine
  }

  private func field(_ prompt: String, text: Binding<String>, id: String) -> some View {
    TextField(prompt, text: text)
      .hType(.body)
      .foregroundStyle(HColor.fieldText)
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
      .accessibilityIdentifier(id)
  }

  private func save() {
    let ccy = target
    guard ExchangeRates.isCurrencyCode(ccy) else {
      failure = "Type a three-letter currency code, like EUR."
      return
    }
    guard ccy != Money.home else {
      failure = "AED is your home currency, so it needs no rate."
      return
    }
    guard let micro = ExchangeRates.parse(rate) else {
      failure = "Type a rate above 0 with at most 6 decimals, like 4.05."
      return
    }
    if app.perform(.setRate(currency: ccy, rateMicro: micro)) {
      app.say("\(ccy) rate saved")
      pop()
    }
  }

  private func pop() {
    if !app.router.profile.isEmpty { app.router.profile.removeLast() }
  }
}

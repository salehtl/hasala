import CoreCategorize
import HasalaDesign
import HasalaModel
import HasalaModels
import SwiftUI

/// Search · Ready and Results as you type (Paper "Search · Ready", "Search · Results as you
/// type (carre)"), in every build. The header's search opens it as
/// a sheet with the field focused; while it is empty, "Try asking" and the recent searches; as
/// you type, the top result, the matching transactions, the categories and the rules, the typed part in
/// bold. Everything is found in this iPhone's own ledger (`ActivityEngine`'s search): no
/// query leaves the device.
struct SearchView: View {
  let app: AppModel
  @State private var query = ""
  /// The field is up and focused when Search opens (Paper "Search · Ready": keyboard up).
  @State private var searching = false
  @State private var ask = AskSearchModel()
  @State private var opened: OpenedTransaction?
  @State private var addingMerchant = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  static let suggestions: [(question: String, term: String)] = [
    ("How much on dining this month?", "dining"),
    ("How much on rent this year?", "rent"),
    ("What did I spend at Carrefour?", "carrefour"),
  ]

  /// The "Try asking" rows this ledger has an answer for: a row whose word finds nothing
  /// (no rent, never at Carrefour) would open "No matches", so it is not offered.
  static func suggestions(in s: LedgerState, now: LocalDateTime) -> [(question: String, term: String)] {
    suggestions.filter { !SearchResults($0.term, s, now: now).isEmpty }
  }

  static func prompt(available: Bool) -> String {
    available ? "Ask about your money" : "Search merchants and categories"
  }

  static func readyTitle(available: Bool) -> String {
    available ? "Try asking" : "Try searching"
  }

  static func nothingFoundCopy(_ q: String, reason: SearchFallback?) -> (title: String, body: String) {
    let title = "No matches for “\(Bidi.isolate(q))”"
    if case .unavailable = reason {
      return (title, "Questions need Apple Intelligence on this iPhone. Try a merchant name or a category.")
    }
    return (title, "Try a merchant name or a category. Bank alerts usually spell merchant names in English.")
  }

  var body: some View {
    let typed = query.trimmedSpaces
    NavigationStack {
      ScrollView {
        Group {
          if typed.isEmpty {
            ready
          } else {
            results(typed)
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, HSpacing.scrollContentBottom)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(alignment: .top) { AmbientWash(.onTrack).ignoresSafeArea() }
      .background(HColor.surfaceSecondary)
      // Ready keeps its large title over the field (Paper "Search · Ready", spec 13 S1);
      // results take the room from the first letter (S3, no large title). The results also
      // drop the title's words: on a CI simulator the hidden bar left its large title drawn
      // over the top result, where an empty title leaves nothing to see.
      .navigationTitle(typed.isEmpty ? "Search" : "")
      .searchable(text: $query, isPresented: $searching, prompt: Self.prompt(available: ask.available))
      .searchPresentationToolbarBehavior(typed.isEmpty ? .avoidHidingContent : .automatic)
      // Merchant names and words as typed ("carre", "talabat"): no capital, no correction,
      // so no QuickType bar over the keys either (Paper's keyboard has none).
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .onSubmit(of: .search) { SearchHistory.shared.add(query) }
      .toolbar { SheetCloseButton(identifier: "search.close") { dismiss() } }
      .overlay(alignment: .bottom) { ToastHost(app: app) }
      .task(id: typed) {
        await ask.run(typed, app.store.state, now: app.store.now)
        ask.refresh(app.store.state, now: app.store.now)
      }
      .onChange(of: app.store.revision) { ask.refresh(app.store.state, now: app.store.now) }
    }
    .nestedTransactionSheet(item: $opened, app: app)
    .sheet(isPresented: $addingMerchant) {
      AddMerchantSheet(
        choices: AskSearch.merchantChoices(
          app.store.state, excluding: ask.answer(for: typed)?.filter.merchants ?? [])
      ) { m in
        ask.add(merchant: m, app.store.state, now: app.store.now)
      }
    }
    .onAppear {
      searching = true
      #if HASALA_MOCKS
        if let q = SearchHistory.launchQuery {
          SearchHistory.launchQuery = nil
          query = q
        }
      #endif
    }
  }

  private func open(_ id: TxnID) {
    app.router.transaction = []
    opened = OpenedTransaction(id: id)
  }

  // MARK: Ready

  private var ready: some View {
    VStack(alignment: .leading, spacing: 24) {
      let asks = Self.suggestions(in: app.store.state, now: app.store.now)
      if !asks.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          overline(Self.readyTitle(available: ask.available))
          VStack(spacing: 0) {
            ForEach(Array(asks.enumerated()), id: \.offset) { i, s in
              if i > 0 { HColor.borderSubtle.frame(height: 1).padding(.leading, 46).accessibilityHidden(true) }
              Button { query = ask.available ? s.question : s.term } label: {
                HStack(spacing: 12) {
                  HIconView(ask.available ? .chat : .magnifier, size: 18, color: HColor.actionAccent, strokeWidth: 2)
                  Text(ask.available ? s.question : s.term.capitalized).hType(.callout)
                    .foregroundStyle(HColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
              }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("search.ask.\(s.term)")
            }
          }
          .background(HColor.surfacePrimary)
          .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.placeholder")
      }

      let recent = SearchHistory.shared.recent
      if !recent.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            overline("Recent")
            Spacer()
            Button("Clear") { SearchHistory.shared.clear() }
              .buttonStyle(.plain)
              .hType(.subheadline.weight(.medium))
              .foregroundStyle(HColor.textLink)
              .frame(minHeight: HSpacing.targetMinimum)
          }
          FlowLayout(spacing: 8) {
            ForEach(recent, id: \.self) { r in
              Button { query = r } label: {
                HStack(spacing: 6) {
                  HIconView(.history, size: 14, color: HColor.textSecondary, strokeWidth: 2.2)
                  Text(r).hType(.subheadline.weight(.medium)).foregroundStyle(HColor.textPrimary)
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(minHeight: HSpacing.chipHeight)
                .background(HColor.chipSurface, in: Capsule())
                .contentShape(Capsule().inset(by: -2))
              }
              .buttonStyle(HPressStyle(scales: false))
            }
          }
        }
      }
    }
  }

  private func overline(_ title: String) -> some View {
    Text(title).hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
      .padding(.leading, 4)
      .accessibilityAddTraits(.isHeader)
  }

  // MARK: Results

  @ViewBuilder
  private func results(_ q: String) -> some View {
    let answer = ask.answer(for: q)
    let thinking = ask.isThinking(about: q)
    let fallback = ask.fallback(for: q)
    let found = SearchResults.find(
      q, app.store.state, now: app.store.now, aliases: ArabicAlias.bundled, keywordFallback: fallback != nil)
    let marks = found.shownFor.isEmpty ? [q] : found.shownFor
    if found.isEmpty && answer == nil && !thinking {
      nothingFound(q, reason: fallback)
    } else {
      VStack(alignment: .leading, spacing: 14) {
        if let answer {
          answerSection(answer, q)
        } else if thinking {
          thinkingRow
        }
        if !found.shownFor.isEmpty && answer == nil {
          Text(verbatim: SearchResults.shownForLine(found.shownFor)).hType(.subheadline)
            .foregroundStyle(HColor.textOnWashSecondary)
            .padding(.leading, 4)
            .accessibilityIdentifier("search.shownFor")
        }
        if let top = found.top {
          VStack(alignment: .leading, spacing: 8) {
            overline("Top result")
            topResult(top, in: found.rows, q, marks: marks)
          }
        }
        if !found.rows.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            overline("Transactions")
            HListCard {
              ForEach(Array(found.rows.prefix(3).enumerated()), id: \.element.id) { i, row in
                if i > 0 { HDivider(inset: .disc68) }
                Button {
                  SearchHistory.shared.add(q)
                  open(row.id)
                } label: {
                  resultRow(row, marks, detail: row.detail)
                }
                .buttonStyle(HRowPressStyle())
                .accessibilityIdentifier("search.txn.\(row.id)")
              }
              if let text = found.activityText(for: q) {
                HDivider(inset: .disc68)
                Button {
                  SearchHistory.shared.add(q)
                  ActivityRequests.shared.show(TxnFilter(text: text), in: app)
                } label: {
                  HStack(spacing: 12) {
                    Text(SearchResults.seeAllLabel(found.rows.count)).hType(.callout.weight(.medium))
                      .foregroundStyle(HColor.textLink)
                      .frame(maxWidth: .infinity, alignment: .leading)
                    HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
                  }
                  .padding(.horizontal, 16)
                  .frame(minHeight: HSpacing.targetMinimum)
                  .contentShape(Rectangle())
                }
                .buttonStyle(HRowPressStyle())
                .accessibilityIdentifier("search.seeAll")
              }
            }
          }
        }
        if !found.categories.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            overline("Categories")
            HListCard {
              ForEach(Array(found.categories.enumerated()), id: \.element.id) { i, c in
                if i > 0 { HDivider(inset: .disc68) }
                Button {
                  SearchHistory.shared.add(q)
                  ActivityRequests.shared.show(TxnFilter(category: c.id), in: app)
                } label: {
                  HStack(spacing: 12) {
                    CategoryDisc(hue: c.hue, icon: c.glyph.icon)
                    VStack(alignment: .leading, spacing: 1) {
                      highlighted(c.name, marks).hType(.callout)
                      Text("Open in Activity").hType(.footnote).foregroundStyle(HColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
                  }
                  .padding(.horizontal, 16)
                  .frame(minHeight: 56)
                  .contentShape(Rectangle())
                }
                .buttonStyle(HRowPressStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.name), open in Activity")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("search.category.\(c.id)")
              }
            }
          }
        }
        if !found.rules.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            overline("Rules")
            HListCard {
              ForEach(Array(found.rules.enumerated()), id: \.element.id) { i, r in
                if i > 0 { HDivider(inset: .disc68) }
                Button { app.router.open(.profile, profile: [.rules]) } label: {
                  HStack(spacing: 12) {
                    Circle().fill(HColor.listRowMonogram).frame(width: 40, height: 40)
                      .overlay { Circle().strokeBorder(HColor.borderSubtle, lineWidth: 1) }
                      .overlay { HIconView(.rule, size: 20, color: HColor.iconPrimary) }
                    VStack(alignment: .leading, spacing: 1) {
                      Text("\(Text(verbatim: "\u{2068}"))\(highlighted(r.pattern, marks))\(Text(verbatim: "\u{2069}  →  \(Bidi.isolate(r.category))"))")
                        .hType(.callout)
                        .foregroundStyle(HColor.textPrimary)
                      Text("\(r.matches) match\(r.matches == 1 ? "" : "es")").hType(.footnote)
                        .foregroundStyle(HColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
                  }
                  .padding(.leading, 16)
                  .padding(.trailing, 14)
                  .frame(minHeight: 56)
                  .contentShape(Rectangle())
                }
                .buttonStyle(HRowPressStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rule, \(r.pattern) to \(r.category), \(r.matches) matches")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("search.rule.\(r.id)")
              }
            }
          }
        }
      }
    }
  }

  private var thinkingRow: some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      Text("Reading your question on this iPhone…").hType(.subheadline).foregroundStyle(HColor.textSecondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("search.ask.thinking")
  }

  @ViewBuilder
  private func answerSection(_ a: AskAnswer, _ q: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      overline("Answer")
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          HIconView(.wand, size: 16, color: HColor.actionAccent, strokeWidth: 2)
          Text(a.headline).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textSecondary)
        }
        VStack(alignment: .leading, spacing: 2) {
          MoneyText(a.refundedMore ? Money(minor: a.total.minor.negated, currency: a.total.currency) : a.total,
                    figure: .large, unit: .unit, hidden: app.amountsHidden, hiddenGlyphs: 4,
                    color: a.isIncome || a.refundedMore ? HColor.moneyIn : HColor.textPrimary,
                    sign: a.isIncome || a.refundedMore ? .income : .none)
          Text("\(a.isIncome ? "Received" : (a.refundedMore ? "Refunded more than spent" : "Spent")) · \(a.countLine)")
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
          if let line = a.mark?.line {
            Text(line).hType(.footnote).foregroundStyle(HColor.textSecondary)
              .accessibilityIdentifier("search.answer.notCounted")
          }
        }
        if !a.scope.isEmpty || !a.filter.merchants.isEmpty {
          FlowLayout(spacing: 6) {
            ForEach(a.scope) { chip in
              Button {
                if !ask.remove(chip.part, app.store.state, now: app.store.now) { query = "" }
              } label: {
                HStack(spacing: 4) {
                  Text(chip.label).hType(.caption1).foregroundStyle(HColor.textPrimary)
                  HIconView(.close, size: 10, color: HColor.textSecondary, strokeWidth: 2.4)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(minHeight: 28)
                .background(HColor.chipSurfaceOnCard, in: Capsule())
                .contentShape(Capsule().inset(by: -8))
              }
              .buttonStyle(HPressStyle(scales: false))
              .accessibilityLabel("Remove \(chip.label) filter")
            }
            if !a.filter.merchants.isEmpty {
              Button { addingMerchant = true } label: {
                HStack(spacing: 4) {
                  HIconView(.add, size: 10, color: HColor.textLink, strokeWidth: 2.4)
                  Text("Add merchant").hType(.caption1.weight(.medium)).foregroundStyle(HColor.textLink)
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .frame(minHeight: 28)
                .overlay { Capsule().strokeBorder(HColor.borderSubtle, lineWidth: 1) }
                .contentShape(Capsule().inset(by: -8))
              }
              .buttonStyle(HPressStyle(scales: false))
              .accessibilityIdentifier("search.answer.addMerchant")
            }
            if a.scope.count > 1 {
              Button {
                ask.clearScope()
                query = ""
              } label: {
                Text("Clear all").hType(.caption1.weight(.medium)).foregroundStyle(HColor.textLink)
                  .frame(minHeight: 28)
                  .contentShape(Rectangle().inset(by: -8))
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("search.answer.clear")
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("search.answer.scope")
        }
        let inferred = ask.inferredMerchants(a, q)
        if !inferred.isEmpty {
          Text(verbatim: AskSearch.matchedNote(q, merchants: inferred.count)).hType(.caption1)
            .foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("search.answer.matched")
        }
        HStack(spacing: 6) {
          HIconView(.lock, size: 12, color: HColor.textSecondary, strokeWidth: 2)
          Text("Understood on this iPhone. Nothing was sent.").hType(.caption1)
            .foregroundStyle(HColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
      .hElevation(.nearFar)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("search.answer")
    }
    if !a.rows.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          overline("Transactions")
          Spacer()
          if let filter = a.activity, let label = AskSearch.seeAllLabel(a, app.store.state) {
            Button {
              SearchHistory.shared.add(q)
              ActivityRequests.shared.show(filter, in: app)
            } label: {
              Text(verbatim: label).hType(.subheadline.weight(.medium)).foregroundStyle(HColor.textLink)
                .multilineTextAlignment(.trailing)
                .frame(minHeight: HSpacing.targetMinimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.answer.seeAll")
          }
        }
        HListCard {
          ForEach(Array(a.rows.prefix(20).enumerated()), id: \.element.id) { i, row in
            if i > 0 { HDivider(inset: .disc68) }
            Button {
              SearchHistory.shared.add(q)
              open(row.id)
            } label: {
              resultRow(row, [], detail: row.detail)
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("search.answer.txn.\(row.id)")
          }
        }
      }
    }
  }

  private func topResult(_ top: MiniTxnRow, in rows: [MiniTxnRow], _ q: String, marks: [String]) -> some View {
    let summary = TopResultSummary(top, in: rows)
    return Button {
      SearchHistory.shared.add(q)
      ActivityRequests.shared.show(TxnFilter(text: top.merchant), in: app)
    } label: {
      HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
        CategoryDisc(hue: top.hue, icon: top.glyph.icon)
        VStack(alignment: .leading, spacing: 1) {
          highlighted(top.merchant, marks).hType(.body).foregroundStyle(HColor.textPrimary)
          topResultLine(summary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
      .padding(.vertical, 14)
      .padding(.leading, 14)
      .padding(.trailing, 12)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    }
    .buttonStyle(HPressStyle(scales: false))
    .hElevation(.nearFar)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(top.merchant), \(summary.spoken(hidden: app.amountsHidden))")
    .accessibilityHint("Opens in Activity")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("search.top")
  }

  private func topResultLine(_ summary: TopResultSummary) -> some View {
    let words = Text(verbatim: summary.countText).foregroundStyle(HColor.textSecondary)
    let line: Text
    if let figure = summary.figure(hidden: app.amountsHidden) {
      let bold = Text(verbatim: figure)
        .font(.system(.footnote, design: .rounded, weight: .bold).monospacedDigit())
        .foregroundStyle(HColor.textPrimary)
      line = Text("\(words)\(Text(verbatim: " · ").foregroundStyle(HColor.textSecondary))\(bold)")
    } else {
      line = words
    }
    return line.hType(.footnote)
  }

  private func resultRow(_ row: MiniTxnRow, _ marks: [String], detail: String) -> some View {
    HStack(spacing: 12) {
      CategoryDisc(hue: row.hue, icon: row.glyph.icon)
      VStack(alignment: .leading, spacing: 1) {
        highlighted(row.merchant, marks).hType(.callout).foregroundStyle(HColor.textPrimary)
        if let project = row.project {
          ProjectChipFlow(project.name) { Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary) }
        } else {
          Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if row.notCounted && !app.amountsHidden {
        Text("Not counted").hType(.subheadline).foregroundStyle(HColor.textSecondary).fixedSize()
      } else {
        MoneyText(row.amount, figure: .row, hidden: app.amountsHidden, hiddenGlyphs: 3,
                  color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none,
                  approx: row.estimate)
          .fixedSize()
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .frame(minHeight: 54)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  /// The typed part in bold, the rest regular (Paper "Carre" + "four").
  private func highlighted(_ text: String, _ marks: [String]) -> Text {
    guard let r = marks.lazy.filter({ !$0.isEmpty })
      .compactMap({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first
    else {
      return Text(text)
    }
    let bold = Font.custom(HWeight.bold.interFace, size: 16, relativeTo: .callout)
    return Text("\(Text(text[..<r.lowerBound]))\(Text(text[r]).font(bold))\(Text(text[r.upperBound...]))")
  }

  /// No matches (Paper page 17 "NothingFound", Proposed): echo the query, say what to try.
  private func nothingFound(_ q: String, reason: SearchFallback?) -> some View {
    let copy = Self.nothingFoundCopy(q, reason: reason)
    return VStack(spacing: 10) {
      Circle().fill(HColor.surfacePrimary).frame(width: 56, height: 56)
        .overlay { HIconView(.magnifier, size: 26, color: HColor.iconSecondary) }
        .accessibilityHidden(true)
      Text(verbatim: copy.title).hType(HType.title3.weight(.bold)).foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
      Text(verbatim: copy.body).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
    }
    .padding(.vertical, 32)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("search.none")
  }
}

private struct OpenedTransaction: Identifiable {
  let id: TxnID
}

private struct AddMerchantSheet: View {
  let choices: [(name: String, count: Int)]
  let pick: (String) -> Void
  @State private var filter = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let shown = filter.trimmedSpaces.isEmpty ? choices : choices.filter { SearchText.contains($0.name, filter.trimmedSpaces) }
    NavigationStack {
      List {
        ForEach(shown, id: \.name) { c in
          Button {
            pick(c.name)
            dismiss()
          } label: {
            HStack(spacing: 12) {
              Text(c.name).hType(.callout).foregroundStyle(HColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(AskSearch.countLabel(c.count)).hType(.footnote).foregroundStyle(HColor.textSecondary)
                .lineLimit(1)
                .fixedSize()
            }
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("search.addMerchant.\(c.name)")
        }
      }
      .navigationTitle("Add merchant")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Merchants")
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .toolbar { SheetCloseButton(identifier: "search.addMerchant.close") { dismiss() } }
    }
  }
}

struct TopResultSummary: Equatable {
  let merchant: String
  let count: Int
  let total: Money?
  let isIncome: Bool
  let estimate: Bool

  init(_ top: MiniTxnRow, in rows: [MiniTxnRow]) {
    let same = rows.filter { $0.merchant == top.merchant }
    merchant = top.merchant
    count = max(same.count, 1)
    let currencies = Set(same.map(\.amount.currency))
    let directions = Set(same.map(\.isIncome))
    if !same.isEmpty, currencies.count == 1, directions.count == 1, !same.contains(where: \.notCounted),
       let currency = currencies.first {
      total = Money(minor: Fils.sum(same.map(\.amount.minor)), currency: currency)
    } else {
      total = nil
    }
    isIncome = same.first?.isIncome ?? top.isIncome
    estimate = same.contains(where: \.estimate)
  }

  var countText: String { AskSearch.countLabel(count) }

  func figure(hidden: Bool) -> String? {
    guard let total else { return nil }
    if hidden { return MoneyFormat.hidden(count: 3) }
    let code = total.currency == "AED" ? "" : total.currency + " "
    return (estimate ? "\u{2248} " : "") + (isIncome ? "+" : "") + code + MoneyFormat.string(total.minor)
  }

  func line(hidden: Bool) -> String {
    figure(hidden: hidden).map { "\(countText) · \($0)" } ?? countText
  }

  func spoken(hidden: Bool) -> String {
    guard let total else { return countText }
    return MoneyPhrase([.text("\(countText), \(estimate ? "about " : "")\(isIncome ? "received " : "")"), .amount(total)])
      .spoken(hidden: hidden)
  }
}

enum ArabicAlias {
  nonisolated static let bundled: [DictEntry] = AccountRuntime.dictionary.entries.filter { $0.pattern.contains(where: isArabic) }

  nonisolated static func isArabic(_ c: Character) -> Bool {
    c.unicodeScalars.contains { s in
      (0x0600...0x06FF).contains(s.value) || (0x0750...0x077F).contains(s.value)
        || (0xFB50...0xFDFF).contains(s.value) || (0xFE70...0xFEFF).contains(s.value)
    }
  }

  static let variants: [Character: Character] = ["\u{0629}": "\u{0647}", "\u{0649}": "\u{064A}"]

  static func fold(_ s: String) -> String {
    String(SearchText.fold(s).filter { $0 != "\u{0640}" }.map { variants[$0] ?? $0 })
  }

  static func names(for q: String, _ entries: [DictEntry]) -> [String] {
    let t = fold(q.trimmedSpaces)
    guard t.filter(isArabic).count >= 2 else { return [] }
    var seen = Set<String>()
    return entries.compactMap { e in
      guard let d = e.display, e.pattern.contains(where: isArabic) else { return nil }
      let p = fold(e.pattern)
      let options: String.CompareOptions = [.diacriticInsensitive, .widthInsensitive]
      guard p.range(of: t, options: options) != nil || t.range(of: p, options: options) != nil else { return nil }
      return seen.insert(d.lowercased()).inserted ? d : nil
    }
  }
}

/// What a typed query finds in the ledger, across months: the transactions (newest first),
/// the categories by name, and the rules whose words contain it.
struct SearchResults {
  struct RuleMatch: Identifiable {
    let id: RuleID
    let pattern: String
    let category: String
    let matches: Int
  }

  let rows: [MiniTxnRow]
  let categories: [CategoryOption]
  let rules: [RuleMatch]
  private(set) var shownFor: [String] = []

  init(_ q: String, _ s: LedgerState, now: LocalDateTime) {
    let found = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: q)).days.flatMap(\.rows)
    // A transaction found by its merchant leads; one found by its category or note follows.
    let ordered = found.filter { SearchText.contains($0.merchant, q) }
      + found.filter { !SearchText.contains($0.merchant, q) }
    rows = ordered.compactMap { r in
      guard let t = s.txn(r.id) else { return nil }
      var row = r
      // "Groceries · Fri 9 Oct": what it was, and when.
      row.detail = "\(s.category(t.categoryID)?.name ?? "To review") · \(t.postedAt.date.short(today: now.date))"
      return row
    }
    categories = s.categories.filter { !$0.archived && $0.kind == .spending && SearchText.contains($0.name, q) }
      .map(CategoryOption.init)
    rules = s.rules.compactMap { r in
      guard let p = r.patterns.first(where: { SearchText.contains($0, q) }),
            let c = s.category(r.categoryID) else { return nil }
      return RuleMatch(id: r.id, pattern: p.lowercased(), category: c.name,
                       matches: s.txns.count { r.matches($0.merchant) })
    }
  }

  init(terms: [String], _ s: LedgerState, now: LocalDateTime, shownFor: [String]) {
    let parts = terms.map { SearchResults($0, s, now: now) }
    var rowIDs = Set<String>(), categoryIDs = Set<CategoryID>(), ruleIDs = Set<RuleID>()
    rows = parts.flatMap(\.rows).filter { rowIDs.insert($0.id).inserted }
    categories = parts.flatMap(\.categories).filter { categoryIDs.insert($0.id).inserted }
    rules = parts.flatMap(\.rules).filter { ruleIDs.insert($0.id).inserted }
    self.shownFor = shownFor
  }

  static func find(
    _ q: String, _ s: LedgerState, now: LocalDateTime, aliases entries: [DictEntry], keywordFallback: Bool
  ) -> SearchResults {
    let plain = SearchResults(q, s, now: now)
    let aliases = ArabicAlias.names(for: q, entries).filter { !SearchResults($0, s, now: now).isEmpty }
    if !aliases.isEmpty {
      let wider = SearchResults(terms: [q] + aliases, s, now: now, shownFor: aliases)
      if wider.rows.count > plain.rows.count || (plain.isEmpty && !wider.isEmpty) { return wider }
    }
    if plain.isEmpty && keywordFallback {
      let names = AskSearch.mentionedNames(in: q, s)
      if !names.isEmpty {
        let named = SearchResults(terms: names, s, now: now, shownFor: names)
        if !named.isEmpty { return named }
      }
    }
    return plain
  }

  static func shownForLine(_ names: [String]) -> String {
    let isolated = names.map(Bidi.isolate)
    let list =
      switch isolated.count {
      case 0, 1: isolated.first ?? ""
      case 2: "\(isolated[0]) and \(isolated[1])"
      default: isolated.dropLast().joined(separator: ", ") + " and " + isolated[isolated.count - 1]
      }
    return "Showing results for \(list)"
  }

  static func seeAllLabel(_ count: Int) -> String {
    "See all \(MoneyFormat.count(count)) in Activity"
  }

  func activityText(for q: String) -> String? {
    guard !rows.isEmpty else { return nil }
    if shownFor.isEmpty { return q }
    return shownFor.count == 1 ? shownFor[0] : nil
  }

  /// The merchant match people most likely meant: the newest one.
  var top: MiniTxnRow? { rows.first }
  var isEmpty: Bool { rows.isEmpty && categories.isEmpty && rules.isEmpty }
}

/// Recent searches, for this process only (nothing about what was searched is kept on disk),
/// and for the open account only: they are cleared when its runtime closes and when its data
/// leaves this iPhone (`BootController.closeRuntime`, `LocalAccountData.forget`).
@MainActor
@Observable
final class SearchHistory {
  static let shared = SearchHistory()
  private(set) var recent: [String] = []

  func add(_ q: String) {
    let t = q.trimmedSpaces.lowercased()
    guard !t.isEmpty else { return }
    recent.removeAll { $0 == t }
    recent.insert(t, at: 0)
    recent = Array(recent.prefix(6))
  }

  func clear() { recent = [] }

  #if HASALA_MOCKS
    /// A Debug screen launch's query (`search.results`).
    static var launchQuery: String?
  #endif
}

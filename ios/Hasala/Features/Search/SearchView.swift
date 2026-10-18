import HasalaDesign
import HasalaModels
import SwiftUI

/// Search · Ready and Results as you type (Paper "Search · Ready", "Search · Results as you
/// type (carre)"), in every build; no answers yet (plan D.2). The search tab grows into the
/// bottom field; while it is empty, "Try asking" and the recent searches; as you type, the
/// top result, the matching transactions, the categories and the rules, the typed part in
/// bold. Everything is found in this iPhone's own ledger (`ActivityEngine`'s search): no
/// query leaves the device.
struct SearchView: View {
  let app: AppModel
  @State private var query = ""
  /// The field is up and focused when Search opens (Paper "Search · Ready": keyboard up).
  @State private var searching = false
  @State private var ask = AskSearchModel()

  /// Paper's "Try asking" rows, each searching for the word it is about until Search answers
  /// questions (the fourth row, "Compare October with September", needs an answer card).
  static let suggestions: [(question: String, term: String)] = [
    ("How much on dining this month?", "dining"),
    ("When is rent due?", "rent"),
    ("What did I spend at Carrefour?", "carrefour"),
  ]

  /// The "Try asking" rows this ledger has an answer for: a row whose word finds nothing
  /// (no rent, never at Carrefour) would open "No matches", so it is not offered.
  static func suggestions(in s: LedgerState, now: LocalDateTime) -> [(question: String, term: String)] {
    suggestions.filter { !SearchResults($0.term, s, now: now).isEmpty }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        Group {
          if query.trimmedSpaces.isEmpty {
            ready
          } else {
            results(query.trimmedSpaces)
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
      .navigationTitle(query.trimmedSpaces.isEmpty ? "Search" : "")
      .searchable(text: $query, isPresented: $searching, prompt: "Ask about your money")
      .searchPresentationToolbarBehavior(query.trimmedSpaces.isEmpty ? .avoidHidingContent : .automatic)
      // Merchant names and words as typed ("carre", "talabat"): no capital, no correction,
      // so no QuickType bar over the keys either (Paper's keyboard has none).
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .onSubmit(of: .search) { SearchHistory.shared.add(query) }
      .overlay(alignment: .bottom) { ToastHost(app: app) }
      .task(id: query.trimmedSpaces) {
        await ask.run(query.trimmedSpaces, app.store.state, now: app.store.now)
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

  // MARK: Ready

  private var ready: some View {
    VStack(alignment: .leading, spacing: 24) {
      let asks = Self.suggestions(in: app.store.state, now: app.store.now)
      if !asks.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          overline("Try asking")
          VStack(spacing: 0) {
            ForEach(Array(asks.enumerated()), id: \.offset) { i, s in
              if i > 0 { HColor.borderSubtle.frame(height: 1).padding(.leading, 46).accessibilityHidden(true) }
              Button { query = ask.available ? s.question : s.term } label: {
                HStack(spacing: 12) {
                  HIconView(.chat, size: 18, color: HColor.actionAccent, strokeWidth: 2)
                  Text(s.question).hType(.callout).foregroundStyle(HColor.textPrimary)
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
    let found = SearchResults(q, app.store.state, now: app.store.now)
    let answer = ask.answer(for: q)
    let thinking = ask.isThinking(about: q)
    if found.isEmpty && answer == nil && !thinking {
      nothingFound(q)
    } else {
      VStack(alignment: .leading, spacing: 14) {
        if let answer {
          answerSection(answer, q)
        } else if thinking {
          thinkingRow
        }
        if let top = found.top {
          VStack(alignment: .leading, spacing: 8) {
            overline("Top result")
            topResult(top, q)
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
                  app.open(row.id)
                } label: {
                  resultRow(row, q, detail: row.detail)
                }
                .buttonStyle(HRowPressStyle())
                .accessibilityIdentifier("search.txn.\(row.id)")
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
                      highlighted(c.name, q).hType(.callout)
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
                      Text("\(highlighted(r.pattern, q))\(Text("  →  \(r.category)"))").hType(.callout)
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
          MoneyText(a.total, figure: .large, unit: .unit, hidden: app.amountsHidden, hiddenGlyphs: 4,
                    color: a.isIncome ? HColor.moneyIn : HColor.textPrimary, sign: a.isIncome ? .income : .none)
          Text("\(a.isIncome ? "Received" : "Spent") · \(a.countLine)").hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
        }
        if !a.scope.isEmpty {
          FlowLayout(spacing: 6) {
            ForEach(a.scope, id: \.self) { chip in
              Text(chip).hType(.caption1).foregroundStyle(HColor.textPrimary)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(HColor.chipSurfaceOnCard, in: Capsule())
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Searched for " + a.scope.joined(separator: ", "))
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
          if let filter = a.activity {
            Button("See all") {
              SearchHistory.shared.add(q)
              ActivityRequests.shared.show(filter, in: app)
            }
            .buttonStyle(.plain)
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .accessibilityIdentifier("search.answer.seeAll")
          }
        }
        HListCard {
          ForEach(Array(a.rows.prefix(5).enumerated()), id: \.element.id) { i, row in
            if i > 0 { HDivider(inset: .disc68) }
            Button {
              SearchHistory.shared.add(q)
              app.open(row.id)
            } label: {
              resultRow(row, "", detail: row.detail)
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("search.answer.txn.\(row.id)")
          }
        }
      }
    }
  }

  /// The best match: disc, the merchant with the typed part bold, its last amount and day,
  /// and "See all" (Activity searching the same words).
  private func topResult(_ row: MiniTxnRow, _ q: String) -> some View {
    HStack(spacing: 12) {
      CategoryDisc(hue: row.hue, icon: row.glyph.icon)
      VStack(alignment: .leading, spacing: 1) {
        highlighted(row.merchant, q).hType(.body).foregroundStyle(HColor.textPrimary)
        topResultLine(row)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("See all") {
        SearchHistory.shared.add(q)
        ActivityRequests.shared.show(TxnFilter(text: q), in: app)
      }
      .buttonStyle(.pill(.secondary, size: .small))
      .accessibilityIdentifier("search.seeAll")
    }
    .padding(.vertical, 14)
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .hElevation(.nearFar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("search.top")
  }

  /// "Groceries · 342.15 on Fri 9 Oct": one line of words with the figure in the rounded
  /// bold face, dots when amounts are hidden.
  private func topResultLine(_ row: MiniTxnRow) -> some View {
    let parts = row.detail.components(separatedBy: " · ")
    let what = "\(parts.first ?? "") · ", when = " on \(parts.last ?? "")"
    let digits = app.amountsHidden
      ? MoneyFormat.hidden(count: 3) : (row.isIncome ? "+" : "") + MoneyFormat.string(row.amount.minor)
    let figure = Text(verbatim: digits)
      .font(.system(.footnote, design: .rounded, weight: .bold).monospacedDigit())
      .foregroundStyle(HColor.textPrimary)
    return Text("\(Text(verbatim: what).foregroundStyle(HColor.textSecondary))\(figure)\(Text(verbatim: when).foregroundStyle(HColor.textSecondary))")
      .hType(.footnote)
      .accessibilityLabel(MoneyPhrase([.text(what), .amount(row.amount), .text(when)]).spoken(hidden: app.amountsHidden))
  }

  private func resultRow(_ row: MiniTxnRow, _ q: String, detail: String) -> some View {
    HStack(spacing: 12) {
      CategoryDisc(hue: row.hue, icon: row.glyph.icon)
      VStack(alignment: .leading, spacing: 1) {
        highlighted(row.merchant, q).hType(.callout).foregroundStyle(HColor.textPrimary)
        Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      MoneyText(row.amount, figure: .row, hidden: app.amountsHidden, hiddenGlyphs: 3,
                color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
        .fixedSize()
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 54)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  /// The typed part in bold, the rest regular (Paper "Carre" + "four").
  private func highlighted(_ text: String, _ q: String) -> Text {
    guard !q.isEmpty, let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else {
      return Text(text)
    }
    let bold = Font.custom(HWeight.bold.interFace, size: 16, relativeTo: .callout)
    return Text("\(Text(text[..<r.lowerBound]))\(Text(text[r]).font(bold))\(Text(text[r.upperBound...]))")
  }

  /// No matches (Paper page 17 "NothingFound", Proposed): echo the query, say what to try.
  private func nothingFound(_ q: String) -> some View {
    VStack(spacing: 10) {
      Circle().fill(HColor.surfacePrimary).frame(width: 56, height: 56)
        .overlay { HIconView(.magnifier, size: 26, color: HColor.iconSecondary) }
        .accessibilityHidden(true)
      Text("No matches for “\(q)”").hType(HType.title3.weight(.bold)).foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
      Text("Try a merchant name or a category.").hType(.subheadline).foregroundStyle(HColor.textSecondary)
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

  init(_ q: String, _ s: LedgerState, now: LocalDateTime) {
    let found = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: q)).days.flatMap(\.rows)
    // A transaction found by its merchant leads; one found by its category or note follows.
    let ordered = found.filter { $0.merchant.localizedCaseInsensitiveContains(q) }
      + found.filter { !$0.merchant.localizedCaseInsensitiveContains(q) }
    rows = ordered.compactMap { r in
      guard let t = s.txn(r.id) else { return nil }
      var row = r
      // "Groceries · Fri 9 Oct": what it was, and when.
      row.detail = "\(s.category(t.categoryID)?.name ?? "To review") · \(t.postedAt.date.short)"
      return row
    }
    categories = s.categories.filter { !$0.archived && $0.name.localizedCaseInsensitiveContains(q) }
      .map(CategoryOption.init)
    rules = s.rules.compactMap { r in
      guard let p = r.patterns.first(where: { $0.localizedCaseInsensitiveContains(q) }),
            let c = s.category(r.categoryID) else { return nil }
      return RuleMatch(id: r.id, pattern: p.lowercased(), category: c.name,
                       matches: s.txns.filter { r.matches($0.merchant) }.count)
    }
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

#if DEBUG
import HasalaModels
import SwiftUI

// The kit's catalogue (Debug only): every component in its states, one page per area, with the
// synthetic sample month (spec 01 §6.8). It is how a package checks a part against its Paper
// board before using it, at the default size and at AX3. Nothing here ships: the file compiles
// only into Debug builds.

/// Every component, page by page.
public struct ComponentCatalog: View {
  public enum Page: String, CaseIterable, Identifiable, Sendable {
    case foundations, icons, buttons, selection, lists, pace, feedback, cards, keypad

    public var id: String { rawValue }

    public var title: String {
      switch self {
      case .foundations: "Type, figures and washes"
      case .icons: "Icons, discs and marks"
      case .buttons: "Buttons and glass"
      case .selection: "Chips, pills and segments"
      case .lists: "Lists and rows"
      case .pace: "Money and pace"
      case .feedback: "Feedback and progress"
      case .cards: "Cards and mailboxes"
      case .keypad: "Amount keypad"
      }
    }
  }

  let page: Page?
  let scrollTo: Int?

  /// One page, or the index of pages when `page` is nil. `scrollTo` opens a page at one of its
  /// specimens (for screenshots of a long page).
  public init(page: Page? = nil, scrollTo: Int? = nil) {
    self.page = page
    self.scrollTo = scrollTo
  }

  public var body: some View {
    if let page {
      CatalogPage(page: page, scrollTo: scrollTo)
    } else {
      NavigationStack {
        List(Page.allCases) { page in
          NavigationLink(page.title) { CatalogPage(page: page, scrollTo: nil).navigationTitle(page.title) }
        }
        .navigationTitle("HasalaDesign")
      }
    }
  }
}

struct CatalogPage: View {
  let page: ComponentCatalog.Page
  let scrollTo: Int?
  @State private var hidden = false

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          HStack {
            Text(page.title).hType(.largeTitle).foregroundStyle(HColor.textPrimary)
            Spacer()
            GlassIconButton(hidden ? .eyeSlash : .eye, label: hidden ? "Show amounts" : "Hide amounts",
                            selected: hidden) { hidden.toggle() }
          }
          content
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, HSpacing.scrollContentBottom)
      }
      .background(alignment: .top) {
        ZStack(alignment: .top) {
          HColor.surfaceSecondary
          AmbientWash(.onTrack)
        }
        .ignoresSafeArea()
      }
      .onAppear {
        if let scrollTo { proxy.scrollTo(scrollTo, anchor: .top) }
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch page {
    case .foundations: FoundationsPage(hidden: hidden)
    case .icons: IconsPage()
    case .buttons: ButtonsPage()
    case .selection: SelectionPage()
    case .lists: ListsPage(hidden: hidden)
    case .pace: PacePage(hidden: hidden)
    case .feedback: FeedbackPage()
    case .cards: CardsPage(hidden: hidden)
    case .keypad: KeypadPage()
    }
  }
}

/// A titled specimen with an index to scroll to.
struct Specimen<Content: View>: View {
  let index: Int
  let title: String
  let content: Content

  init(_ index: Int, _ title: String, @ViewBuilder content: () -> Content) {
    self.index = index
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader).padding(.leading, 4)
      content
    }
    .id(index)
  }
}

/// The sample month (synthetic Maya, spec 01 §6.8).
enum Sample {
  static let spent = Money.aed(10_288_34)
  static let plan = Money.aed(19_000_00)
  static let tick = Money.aed(11_254_00)
  static let rows: [MiniTxnRow] = [
    MiniTxnRow(id: "talabat", merchant: "Talabat", glyph: .dining, hue: .lilac, detail: "Dining · 13:20",
               amount: .aed(64_50)),
    MiniTxnRow(id: "carrefour", merchant: "Carrefour", glyph: .groceries, hue: .sand, detail: "Groceries · 09:12",
               amount: .aed(342_15)),
    MiniTxnRow(id: "amazon", merchant: "Amazon.ae", glyph: .refunds, hue: .other,
               detail: "Refund · Shopping · 08:40", amount: .aed(185_00), isIncome: true),
    MiniTxnRow(id: "lulu", merchant: "Lulu Hypermarket", glyph: .groceries, hue: .sand, detail: "To review · 18:42",
               amount: .aed(214_30), monogram: "L", toReview: true),
  ]
  static let bills: [BillRowModel] = [
    BillRowModel(id: "axa", name: "AXA Insurance", glyph: .insurance, hue: .sand,
                 detail: [.status("Expected the 7th", .error)], amount: .aed(550_00)),
    BillRowModel(id: "dewa", name: "DEWA", glyph: .utilities, hue: .sand, detail: [.text("Wed 14 Oct · in 4 days")],
                 amount: .aed(489_15), approximate: true),
    BillRowModel(id: "salary", name: "Salary · Acme Gulf", glyph: .salary, hue: .sky,
                 detail: [.text("Wed 28 Oct · in 18 days")], amount: .aed(25_000_00), isIncome: true),
  ]
  static let mailboxes: [MailboxSnapshot] = [
    MailboxSnapshot(id: "gmail-1", provider: .gmail, address: "maya@example.com", state: .connected,
                    meta: "Checked 4 min ago", banks: ["Emirates NBD", "Dubai Islamic Bank"]),
    MailboxSnapshot(id: "outlook-1", provider: .outlook, address: "maya.k@example.com", state: .syncing,
                    meta: "Checking now", accountKind: "Personal Microsoft"),
    MailboxSnapshot(id: "outlook-2", provider: .outlook, address: "maya.k@example.com", state: .needsSignIn,
                    meta: "Checked 3 days ago", accountKind: "Personal Microsoft"),
    MailboxSnapshot(id: "gmail-2", provider: .gmail, address: "maya@example.com", state: .disconnected,
                    meta: "Off since 2 Oct"),
  ]
}

// MARK: - Pages

struct FoundationsPage: View {
  let hidden: Bool

  private let types: [(String, HType)] = [
    ("Large title", .largeTitle), ("Title 1", .title1), ("Title 2", .title2), ("Section", .section),
    ("Title 3", .title3), ("Headline", .headline), ("Body", .body), ("Callout", .callout), ("Row title", .rowTitle),
    ("Subheadline", .subheadline), ("Footnote", .footnote), ("Caption 1", .caption1), ("Caption 2", .caption2),
    ("Button", .button), ("Small button", .smallButton), ("Text button", .textButton), ("Overline", .overline),
  ]

  var body: some View {
    Specimen(0, "Text scale (Inter)") {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(types, id: \.0) { name, type in
          Text(name).hType(type).foregroundStyle(type == .textButton ? HColor.textLink : HColor.textPrimary)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(1, "Figure scale (SF Pro Rounded)") {
      VStack(alignment: .leading, spacing: 8) {
        MoneyText(Sample.spent, figure: .display, unit: .displayUnit, hidden: hidden, hiddenGlyphs: 6,
                  color: HColor.textPrimary)
        MoneyText(.aed(8_711_66), figure: .hero, unit: .unit, hidden: hidden, color: HColor.textPrimary, unitGap: 6)
        MoneyText(.aed(10_288_00), figure: .widget, style: .rounded, hidden: hidden, color: HColor.textPrimary)
        MoneyText(.aed(489_15), figure: .large, unit: .unit, hidden: hidden, hiddenGlyphs: 3,
                  color: HColor.textPrimary, unitGap: 5)
        MoneyText(.aed(7_140_00), figure: .medium, hidden: hidden, color: HColor.textPrimary)
        MoneyText(.aed(5_000_00), figure: .small, hidden: hidden, color: HColor.textPrimary)
        MoneyText(.aed(9_040_80), figure: .stat, hidden: hidden, color: HColor.textPrimary)
        FlowRow(spacing: 16) {
          MoneyText(.aed(64_50), figure: .row, hidden: hidden, hiddenGlyphs: 3)
          MoneyText(.aed(25_000_00), figure: .row, hidden: hidden, hiddenGlyphs: 3, color: HColor.moneyIn,
                    sign: .income)
          MoneyText(.aed(4_210_50), figure: .compact, hidden: hidden, hiddenGlyphs: 3, sign: .debt)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(2, "A long figure scales to its floor, AED with it") {
      MoneyText(.aed(123_456_789_00), figure: .display, unit: .displayUnit, hidden: hidden, hiddenGlyphs: 6,
                color: HColor.textPrimary)
        .frame(width: 280, alignment: .leading)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listCard()
    }
    Specimen(3, "Washes") {
      let washes: [(String, HWash)] = [
        ("On track", .onTrack), ("Over pace", .overPace), ("Over budget", .overBudget), ("Lilac", .hue(.lilac)),
        ("Setup", .setup), ("It works", .itWorks), ("Welcome", .welcome), ("Notifications", .notifications),
      ]
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        ForEach(washes, id: \.0) { name, wash in
          ZStack(alignment: .topLeading) {
            HColor.surfaceSecondary
            AmbientWash(wash, height: 90)
            Text(name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textOnWashSecondary).padding(10)
          }
          .frame(height: 90)
          .clipShape(RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
        }
      }
    }
    Specimen(4, "Elevation: flat, near, near + far") {
      HStack(spacing: 12) {
        ForEach(0..<3) { i in
          RoundedRectangle(cornerRadius: HRadius.card, style: .continuous)
            .fill(HColor.surfacePrimary)
            .frame(height: 64)
            .modifier(CatalogElevation(level: i))
        }
      }
    }
  }
}

struct CatalogElevation: ViewModifier {
  let level: Int

  func body(content: Content) -> some View {
    switch level {
    case 1: content.hElevation(.near)
    case 2: content.hElevation(.nearFar)
    default: content
    }
  }
}

struct IconsPage: View {
  var body: some View {
    Specimen(0, "Every icon (24 pt)") {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 10) {
        ForEach(HIcon.allCases, id: \.self) { icon in
          VStack(spacing: 4) {
            HIconView(icon, size: 24, color: HColor.iconPrimary)
            Text(icon.rawValue).font(.system(size: 9)).foregroundStyle(HColor.textSecondary).lineLimit(1)
              .minimumScaleFactor(0.6)
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(1, "Category discs: 32, 40, 56 and a hero ring") {
      HStack(spacing: 14) {
        CategoryDisc(hue: .sand, icon: .groceries, size: .s32)
        CategoryDisc(hue: .lilac, icon: .dining, size: .s40)
        CategoryDisc(hue: .mint, icon: .savings, size: .s40)
        CategoryDisc(hue: .sky, icon: .salary, size: .s40)
        CategoryDisc(hue: .peach, icon: .project, size: .s40)
        CategoryDisc(hue: .sand, icon: .insurance, size: .s56, ring: true)
      }
      .padding(16)
      .frame(maxWidth: .infinity)
      .background(Hue.rose.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card))
    }
    Specimen(2, "Monogram, bank plates, glyph plates, avatars") {
      HStack(spacing: 12) {
        MonogramDisc("L")
        MonogramDisc("L", size: 56)
        BankPlate(initials: "ENBD", hue: .sky)
        BankPlate(initials: "DIB", hue: .sand)
        GlyphPlate(icon: .monitor, hue: .sky)
        AvatarDisc(initial: "M")
      }
      .padding(16)
      .frame(maxWidth: .infinity)
      .listCard()
      AvatarDisc(initial: "M", size: 96, ring: true).frame(maxWidth: .infinity)
    }
    Specimen(3, "Provider marks and the Hasala mark") {
      HStack(spacing: 14) {
        ProviderMark(.gmail)
        ProviderMark(.outlook)
        ProviderMark(.gmail, size: .disc26).padding(6).background(HColor.actionAccent, in: Circle())
        ProviderMark(.outlook, size: .large64)
        ProviderMark(.gmail, faded: true)
      }
      .padding(16)
      .frame(maxWidth: .infinity)
      .listCard()
      HasalaMark().frame(height: 72).frame(maxWidth: .infinity)
    }
  }
}

struct ButtonsPage: View {
  @State private var loading = true

  var body: some View {
    Specimen(0, "Pills: primary, secondary, on grouped, destructive") {
      VStack(spacing: 10) {
        Button("Continue") {}.buttonStyle(.pill(.primary, fill: true))
        Button("Sign in with Face ID") {}.buttonStyle(.pill(.primary, fill: true, leadingIcon: .faceID))
        Button("Adjust plan") {}.buttonStyle(.pill(.secondary, fill: true))
        Button("Export as CSV") {}.buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .download))
        Button("Delete my account") {}.buttonStyle(.pill(.destructive, fill: true))
        Button("Sign out") {}.buttonStyle(.pill(.destructiveQuiet, fill: true))
      }
    }
    Specimen(1, "Sizes, tertiary, quiet, disabled, loading") {
      VStack(alignment: .leading, spacing: 10) {
        FlowRow(spacing: 8) {
          Button("Start") {}.buttonStyle(.pill(.primary, size: .medium))
          Button("Later") {}.buttonStyle(.pill(.secondary, size: .medium))
          Button("Track") {}.buttonStyle(.pill(.primary, size: .small))
          Button("Archive") {}.buttonStyle(.pill(.destructiveText, size: .small))
        }
        FlowRow(spacing: 8) {
          Button("Cancel") {}.buttonStyle(.pill(.tertiary, size: .medium))
          Button("Save") {}.buttonStyle(.pill(.primary, size: .medium)).disabled(true)
          Button("Export") {}.buttonStyle(.pill(.onGrouped, size: .medium)).disabled(true)
        }
        Button(loading ? "Saving" : "Save") { loading.toggle() }
          .buttonStyle(.pill(.primary, fill: true, loading: loading))
      }
    }
    Specimen(2, "Provider buttons") {
      VStack(spacing: 10) {
        ProviderButton(provider: .gmail) {}
        ProviderButton(provider: .outlook) {}
      }
    }
    Specimen(3, "Glass buttons") {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 16) {
        GlassIconButton(.eye, label: "Hide amounts") {}
        GlassIconButton(.eyeSlash, label: "Show amounts", selected: true) {}
        GlassIconButton(.bell, label: "Notifications, 4 new", badge: 4) {}
        GlassAvatarButton(initial: "M") {}
        GlassIconButton(.back, label: "Back") {}
        GlassIconButton(.close, label: "Close") {}
        GlassIconButton(.add, label: "Add transaction") {}
        GlassIconButton(.more, label: "More") {}
        GlassIconButton(.share, label: "Share") {}
        GlassIconButton(.filter, label: "Filter") {}
        GlassIconButton(.done, label: "Done", prominent: true) {}
        GlassIconButton(.close, label: "Close") {}.disabled(true)
      }
      .padding(16)
      .background(Hue.sky.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card))
    }
  }
}

struct SelectionPage: View {
  @State private var filter = "All"
  @State private var category = "Groceries"
  @State private var segment = "Spending"
  @State private var pair = "Rules"

  var body: some View {
    Specimen(0, "Filter chips") {
      VStack(alignment: .leading, spacing: 8) {
        FlowRow(spacing: 8) {
          FilterChip("All", selected: filter == "All") { filter = "All" }
          FilterChip("To review", count: 6, selected: filter == "To review") { filter = "To review" }
          FilterChip("Bills", count: 8, countStyle: .plain, selected: filter == "Bills") { filter = "Bills" }
        }
        FlowRow(spacing: 8) {
          FilterChip("Split evenly", selected: false, onCard: true) {}
          FilterChip("Bills", count: 8, countStyle: .plain, selected: true) {}
        }
        .padding(10)
        .listCard()
      }
    }
    Specimen(1, "Choice chips") {
      VStack(alignment: .leading, spacing: 8) {
        FlowRow(spacing: 7) {
          ForEach(["Rent", "Utilities", "Groceries"], id: \.self) { name in
            ChoiceChip(name, dot: .sand, selected: category == name) { category = name }
          }
        }
        FlowRow(spacing: 8) {
          ChoiceChip("None", selected: true, onCard: true) {}
          ChoiceChip("Japan trip", dot: .peach, selected: false, onCard: true) {}
        }
        .padding(10)
        .listCard()
      }
    }
    Specimen(2, "Info chips (on a card)") {
      FlowRow {
        InfoChip("Seen 5×")
        InfoChip("Every ~30 days")
        InfoChip("Last on 8 Oct")
        InfoChip("New merchant", style: .reason)
        InfoChip("Suggested", style: .suggested)
        InfoChip("LULU HYPERMARKET DXB MARINA", style: .rawText)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(3, "Status pills: 36, 32, 28, 26, 22") {
      VStack(alignment: .leading, spacing: 8) {
        StatusPillView(StatusPill("Concept · for review", tone: .accent), size: .s36, surface: .tinted)
        StatusPillView(StatusPill("3 days past usual", tone: .error), size: .s32)
        StatusPillView(StatusPill("New merchant", tone: .accent), size: .s28, surface: .tinted)
        FlowRow(spacing: 8) {
          StatusPillView(StatusPill("2 new today", tone: .accent))
          StatusPillView(StatusPill("In 4 days", tone: .warning, showsDot: false), surface: .tinted)
          StatusPillView(StatusPill("Price change", tone: .warning), size: .s22, surface: .tinted)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Hue.sky.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card))
    }
    Specimen(4, "Count badges (0 hidden, 99+)") {
      FlowRow(spacing: 14) {
        CountBadge(4, style: .glass20)
        CountBadge(6, style: .tab18)
        CountBadge(24, style: .tab18)
        CountBadge(120, style: .glass20)
        CountBadge(2, style: .title24)
        CountBadge(1, style: .row22)
        CountBadge(0, style: .glass20)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(5, "Segmented control") {
      VStack(spacing: 12) {
        HSegmentedControl(["Spending", "Income", "Transfer"], selection: $segment)
        HSegmentedControl(["Categories", "Rules"], selection: $pair)
      }
    }
  }
}

/// A wrapping row for chips in the catalogue.
struct FlowRow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += line + spacing
        line = 0
      }
      x += size.width + spacing
      line = max(line, size.height)
    }
    return CGSize(width: width.isFinite ? width : x, height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += line + spacing
        line = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}

struct ListsPage: View {
  let hidden: Bool
  @State private var faceID = true
  @State private var picked = "Groceries"

  var body: some View {
    Specimen(0, "Section header and transactions") {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Recent", trailing: .link("See all") {})
        OverlineHeader("Today") {
          MoneyText(.aed(91_50), figure: HFigure.badge.weight(.semibold), hidden: hidden, hiddenGlyphs: 3,
                    color: HColor.textSecondary)
        }
        HListCard {
          ForEach(Array(Sample.rows.enumerated()), id: \.element.id) { i, row in
            if i > 0 { HDivider(inset: .disc68) }
            TransactionRow(row, hidden: hidden)
          }
        }
      }
    }
    Specimen(1, "Settings rows, action and destructive rows") {
      VStack(spacing: 12) {
        HListCard {
          SettingsRow(icon: .globe, title: "Currency", accessory: .value("AED"))
          HDivider(inset: .icon52)
          SettingsRow(icon: .bell, title: "Notifications", accessory: .value("Important only"))
          HDivider(inset: .icon52)
          SettingsRow(icon: .faceID, title: "Face ID lock", accessory: .switch($faceID))
          HDivider(inset: .icon52)
          SettingsRow(icon: .add, title: "Add a rule", accessory: .none, role: .action)
        }
        HListCard { SettingsRow(icon: .archive, title: "Archive", accessory: .none, role: .destructive) }
      }
    }
    Specimen(2, "Rows with a badge, a status, a tick") {
      HListCard {
        HListRow(leading: .disc(.sand, .receipt), title: "Bills", supporting: "9 tracked · 1 new found", trailing: .badge(1))
        HDivider()
        HListRow(leading: .plate(initials: "DIB", hue: .sand), title: "DIB Credit Card",
                 supporting: "···8891 · statement due Sun 18 Oct", trailing: .amount(.aed(4_210_50)), hidden: hidden)
        HDivider()
        ForEach(["Groceries", "Rent"], id: \.self) { name in
          Button { picked = name } label: {
            HListRow(leading: .disc(.sand, name == "Rent" ? .rent : .groceries), title: name,
                     trailing: .check(picked == name))
          }
          .buttonStyle(HRowPressStyle())
          if name == "Groceries" { HDivider() }
        }
      }
    }
    Specimen(3, "Key-value details card") {
      VStack(spacing: 0) {
        KeyValueRow("Merchant", value: "Common Grounds")
        HDivider(inset: .none)
        KeyValueRow("Category", value: "Dining", dot: .lilac, chevron: true)
        HDivider(inset: .none)
        KeyValueRow("Note", value: "Add a note", chevron: true, placeholder: true)
      }
      .padding(.horizontal, 16)
      .listCard()
    }
    Specimen(4, "Bill rows") {
      HListCard {
        ForEach(Array(Sample.bills.enumerated()), id: \.element.id) { i, bill in
          if i > 0 { HDivider() }
          BillRowView(bill, hidden: hidden)
        }
      }
    }
    Specimen(5, "Header with a count and a line") {
      HSectionHeader("Needs a look", subtitle: "1 bill may be late · 1 new price", trailing: .count(2))
    }
  }
}

struct PacePage: View {
  let hidden: Bool
  @State private var phase = PaceFillPhase()
  @State private var replay = 0
  @Environment(\.hMotion) private var motion

  var body: some View {
    Specimen(0, "Home month bar: on track (with the reveal)") {
      VStack(alignment: .leading, spacing: 10) {
        MoneyText(phase.figure(Sample.spent), figure: .display, unit: .displayUnit, hidden: hidden,
                  hiddenGlyphs: 6, color: HColor.textPrimary)
        MonthPaceBar(spent: Sample.spent, plan: Sample.plan, tick: Sample.tick, verdict: .onTrack, hidden: hidden,
                     phase: phase)
        VerdictLine(verdict: .onTrack, fact: MoneyPhrase([.text("AED "), .amount(.aed(8_711_66), hidden: 3),
                                                          .text(" left")]),
                    hidden: hidden, link: ("See month", {}))
          .opacity(phase.verdictVisible ? 1 : 0)
        Button("Replay the reveal") { replay += 1 }.buttonStyle(.pill(.secondary, size: .small))
      }
      // The reveal belongs to the specimen, so a new id replays it.
      .paceFillSequence($phase, target: Sample.spent.fraction(of: Sample.plan), policy: motion)
      .id(replay)
    }
    Specimen(1, "Ahead of pace, over the plan, a closed month over, no plan") {
      VStack(alignment: .leading, spacing: 14) {
        MonthPaceBar(spent: .aed(12_900_00), plan: Sample.plan, tick: Sample.tick, verdict: .overPace)
        VerdictLine(verdict: .overPace, word: "Ahead of pace",
                    fact: MoneyPhrase([.text("AED "), .amount(.aed(6_100_00), hidden: 3), .text(" left")]),
                    hidden: hidden, link: ("See month", {}))
        MonthPaceBar(spent: .aed(20_240_00), plan: Sample.plan, tick: .aed(16_150_00), verdict: .overBudget)
        VerdictLine(verdict: .overBudget, word: "Over by AED 1,240.00", link: ("See month", {}))
        MonthPaceBar(spent: .aed(19_240_10), plan: Sample.plan, tick: nil, verdict: .overBudget, live: false)
        VerdictLine(verdict: .overBudget, word: "Ended 240.10 over", link: ("See recap", {}))
        MonthPaceBar(spent: Sample.spent, plan: .aed(0), tick: nil, verdict: .onTrack)
        VerdictLine(tone: .neutral, word: "No plan yet", link: ("Set your plan", {}))
      }
      .padding(16)
      .background(AmbientWash(.overPace, height: 360), alignment: .top)
      .clipShape(RoundedRectangle(cornerRadius: HRadius.card))
    }
    Specimen(2, "Card bars: on track, over pace, over budget") {
      VStack(alignment: .leading, spacing: 10) {
        ForEach([(Verdict.onTrack, 732, 320), (.overPace, 402, 320), (.overBudget, 1000, 320)], id: \.0) { v, s, t in
          CategoryPaceBar(spent: Permille(s), tick: Permille(t), verdict: v)
          VerdictLine(verdict: v, fact: "642.75 of 1,600", size: .card, onWash: false)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(3, "Slim and widget bars") {
      VStack(spacing: 12) {
        SlimProgressBar(Permille(480))
        SlimProgressBar(Permille(1000), fill: HColor.statusSuccessForeground)
        WidgetPaceBar(spent: Permille(540), tick: Permille(590), verdict: .onTrack)
        WidgetPaceBar(spent: Permille(540), tick: Permille(590), verdict: .onTrack, inverse: true)
          .padding(10)
          .background(HColor.widgetSurfaceInverse, in: RoundedRectangle(cornerRadius: 12))
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
  }
}

extension Money {
  /// This amount as a share of `plan`, for drawing (geometry only).
  func fraction(of plan: Money) -> Double {
    plan.minor > 0 ? Double(minor) / Double(plan.minor) : 0
  }
}

struct FeedbackPage: View {
  var body: some View {
    Specimen(0, "Toasts") {
      VStack(spacing: 10) {
        GlassToast(title: "Sorted into Groceries", actionTitle: "Undo") {}
        GlassToast(.ink(.eyeSlash), title: "Amounts hidden", subtitle: "Until you tap the eye again",
                   actionTitle: "Show") {}
        GlassToast(title: "Bill marked as paid")
      }
      .padding(12)
      .background(Hue.sky.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card))
    }
    Specimen(1, "Progress, steps, stories, background work") {
      VStack(alignment: .leading, spacing: 14) {
        ProgressBar(Permille(680), label: "Reading alerts", count: "182 of 268")
        HStack {
          StepIndicator(current: 2, of: 4)
          Spacer()
          Spinner(size: 12)
          Spinner(size: 16)
          Spinner(size: 20)
        }
        StoryProgress(count: 4, current: 1, fill: 0.62)
        HStack(spacing: 8) {
          BackgroundWorkPill(label: "Reading on this iPhone", count: "214 of 268")
        }
        BackgroundWorkPill(label: "Offline", busy: false)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(2, "Inline status") {
      VStack(alignment: .leading, spacing: 10) {
        InlineStatus(tone: .success, text: "Adds up exactly", size: .regular)
        InlineStatus(tone: .pace(.overPace), text: "Over pace", context: "on course for 1,992 of 1,600")
        InlineStatus(tone: .error, text: "That code isn't right. Check the newest email from us, or get a new code. 4 tries left.",
                     fieldError: true)
        InlineStatus(tone: .warning, text: "That code expired. Codes last 10 minutes, so we'll send you a fresh one.",
                     fieldError: true)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
    Specimen(3, "Status hero, result cards") {
      VStack(spacing: 12) {
        StatusHero(title: "Protected", body: "Passkey and 12 words are set.", hue: .mint, icon: .check)
        ResultCard(tone: .warning, title: "Bank shows AED 180.00 less", detail: "Hasala expected 41,823.50")
        ResultCard(tone: .error, title: "Couldn't send the code",
                   detail: "No connection. Nothing was lost. Check Wi-Fi or mobile data, then try again.",
                   action: ("Try again", {}))
      }
    }
    Specimen(4, "Success badges and empty states") {
      VStack(spacing: 12) {
        SuccessBadge(content: .check).frame(maxWidth: .infinity)
        SuccessBadge(content: .ring(0.64)).frame(maxWidth: .infinity)
        SuccessBadge(content: .coin).frame(maxWidth: .infinity)
        EmptyStateCard(title: "Nothing needs you", message: "We'll tell you when something does.")
          .listCard()
        EmptyStateCard(icon: .magnifier, tone: .neutral, title: "No matches for \u{201C}zuma march\u{201D}",
                       message: "Your transactions start on 1 April. Try a merchant name or a category.")
          .background(AmbientWash(.onTrack, height: 200), alignment: .top)
          .clipShape(RoundedRectangle(cornerRadius: HRadius.card))
      }
    }
  }
}

struct CardsPage: View {
  let hidden: Bool

  var body: some View {
    Specimen(0, "Brief cards") {
      VStack(spacing: 12) {
        BriefCard(hue: .rose, icon: .insurance, label: "AXA Insurance",
                  status: StatusPill("3 days past usual", tone: .error), figure: .money(.aed(550_00)),
                  body: "Car insurance usually arrives on the 7th. No bank email yet.", primaryTitle: "I paid it",
                  secondaryTitle: "Remind me", hidden: hidden, onPrimary: {}, onSecondary: {})
        BriefCard(hue: .sky, icon: .monitor, label: "To review", status: StatusPill("2 new today", tone: .accent),
                  figure: .count(6, unit: "to sort"), title: "Sort new transactions",
                  body: MoneyPhrase([.text("AED "), .amount(.aed(827_28), hidden: 3), .text(" isn't in your plan yet")]),
                  primaryTitle: "Start", secondaryTitle: "Later", secondaryWidth: 88, poster: .tall120,
                  width: HContainer.briefCard, hidden: hidden, onPrimary: {}, onSecondary: {})
      }
    }
    Specimen(1, "Mailbox rows, four states") {
      HListCard {
        ForEach(Array(Sample.mailboxes.enumerated()), id: \.element.id) { i, mailbox in
          if i > 0 { HDivider() }
          MailboxRow(mailbox)
        }
      }
    }
    Specimen(2, "Choose your email") {
      HListCard {
        ProviderRow(provider: .gmail) {}
        HDivider()
        ProviderRow(provider: .outlook) {}
      }
    }
  }
}

struct KeypadPage: View {
  @State private var docked = AmountEntry(typing: "25000")
  @State private var inline = AmountEntry(typing: "48.00")

  var body: some View {
    Specimen(0, "Docked (monthly income)") {
      VStack(spacing: 16) {
        AmountFigure(entry: docked, layout: .docked).frame(maxWidth: .infinity)
        AmountKeypad(entry: $docked, layout: .docked)
          .clipShape(RoundedRectangle(cornerRadius: HRadius.tile))
      }
    }
    Specimen(1, "Inline (in a sheet)") {
      VStack(spacing: 16) {
        AmountFigure(entry: inline, layout: .inline).frame(maxWidth: .infinity)
        AmountKeypad(entry: $inline, layout: .inline)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listCard()
    }
  }
}

#Preview("Catalogue") {
  ComponentCatalog()
}

#Preview("Money and pace · AX3") {
  ComponentCatalog(page: .pace)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif

import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Home · Default (Paper 14O7-0, spec 10 §2): one question first, "am I okay this month?" The
/// hero shows what is spent on needs and wants with its pace and a verdict in words, then the
/// widgets Maya arranges. Anything that needs her arrives behind the bell: its badge counts what
/// needs a look and it opens the Notifications sheet. There is no "Needs you" section.
///
/// The wash follows the verdict (blue on track, sand ahead of pace, rose over) and cross-fades
/// when it changes. A Release build leaves out what isn't built yet (`BuildSurface`): the
/// period pill's chevron, "See month", "Edit", "Add widget", and taps on widgets without a
/// detail screen. A review account's ledger is sample data, and Home says so.
struct HomeView: View {
  @Bindable var app: AppModel
  let model: any HomeModel
  /// Present once the account gate runs; it knows whether this is the review account.
  @Environment(AccountSession.self) private var session: AccountSession?

  private var snapshot: HomeSnapshot { model.snapshot }
  private var hidden: Bool { model.hidden }
  private var unfinished: Bool { BuildSurface.showsUnfinished }

  var body: some View {
    NavigationStack(path: Bindable(app.router).home) {
      TabScreen(
        app: app, title: nil, extra: .bell(unread: model.bell.count),
        onExtra: { app.router.open(.notifications) },
        wash: HWash(snapshot.hero.wash)
      ) {
        if session?.reviewAccount == true {
          SampleDataLabel()
            .padding(.horizontal, HSpacing.insetPage)
            .padding(.bottom, -12)
        }
        HomeHero(
          hero: snapshot.hero, hidden: hidden, month: app.store.now.date.yearMonth.title,
          changePeriod: unfinished ? { app.say("Picking a period isn't in this build yet", icon: .info) } : nil,
          seeMonth: unfinished ? { app.router.home.append(.insights) } : nil,
          setPlan: { app.tab = .plan })
          // Paper: 12 from the header to the pill's row (content 8, hero 4); the tab screen's
          // column starts 20 down for a large title.
          .padding(.top, -8)
        WidgetCanvas(widgets: snapshot.widgets, hidden: hidden, editable: unfinished,
                     opens: model.widgetOpens,
                     open: { id in if let next = model.openWidget(id) { app.router.home.append(next) } },
                     edit: { app.say("Editing widgets isn't in this build yet", icon: .info) })
      }
      .overlay(alignment: .bottom) {
        HomeImportPill(work: app.mailbox?.importing)
          .padding(.bottom, 12)
      }
      .navigationDestination(for: HomeRoute.self) { route in
        switch route {
        case .bills: BillsScreen(app: app)
        case .bill(let id): BillDetailView(app: app, bill: id)
        case .accounts: AccountsView(app: app)
        case .insights: InsightsPlaceholder()
        }
      }
    }
  }
}

struct HomeImportPill: View {
  var work: MailImport?

  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let motion = MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
    ZStack {
      if let work {
        BackgroundWorkPill(label: work.label, count: work.count, busy: work.busy)
          .accessibilityAddTraits(.updatesFrequently)
          .accessibilityIdentifier("home.importPill")
          .transition(motion.transition(.fade))
      }
    }
    .frame(maxWidth: .infinity)
    .animation(motion.animation(.fade), value: work != nil)
    .animation(motion.animation(.stateSwap), value: work?.state)
  }
}

/// "See month" in Debug, until Insights · October so far is built.
// TODO(spec 04 §16.1 "Insights"): Insights and the September recap.
private struct InsightsPlaceholder: View {
  var body: some View {
    ScrollView {
      PlaceholderCard(systemImage: "chart.line.uptrend.xyaxis", title: "October so far",
                      message: "This screen comes in a later build.")
        .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("October so far")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// "Sample data" over Home on the App Review demo account (`review_account`, spec 06
/// §13.4): its month was loaded from the bundled sample, not read from email.
struct SampleDataLabel: View {
  var body: some View {
    HStack(spacing: 6) {
      HIconView(.info, size: 14, color: HColor.chipInfoText)
      Text("Sample data")
    }
    .hType(.footnote.weight(.semibold))
    .foregroundStyle(HColor.chipInfoText)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(HColor.chipInfoSurface, in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Sample data. This account shows a sample month, not your email.")
    .accessibilityIdentifier("home.sampleData")
  }
}

#if HASALA_MOCKS
  #Preview("Home · Default") {
    MainView(app: AppModel(store: InMemoryLedger()))
  }

  #Preview("Home · Amounts hidden") {
    MainView(app: AppModel(store: InMemoryLedger(), amountsHidden: true))
  }
#endif

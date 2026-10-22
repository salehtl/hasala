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
/// when it changes. The period pill opens the period picker; another period scopes the hero,
/// shows that month's Budget pace and "Still about now". This month's widgets follow the
/// arrangement kept on this iPhone ("Edit", "Add widget"). A Release build leaves out taps on
/// widgets without a detail screen (`BuildSurface`). A review account's ledger is sample data, and Home says so.
struct HomeView: View {
  @Bindable var app: AppModel
  let model: any HomeModel
  /// Present once the account gate runs; it knows whether this is the review account.
  @Environment(AccountSession.self) private var session: AccountSession?
  @Environment(OnboardingStore.self) private var onboarding: OnboardingStore?

  private var snapshot: HomeSnapshot { model.snapshot }
  private var hidden: Bool { model.hidden }
  private var canvas: [HomeCanvasItem] { model.canvas }

  private var canvasActions: WidgetCanvasActions {
    WidgetCanvasActions(
      opens: { model.widgetOpens($0.id) },
      open: { item in if let next = model.openWidget(item.id) { app.router.home.append(next) } },
      setEditing: { app.editingHome = $0 },
      add: { app.sheet = .widgetGallery },
      remove: { item in
        if app.removeWidget(item.id) {
          AccessibilityNotification.Announcement("\(item.title) removed").post()
        }
      },
      move: { item, index in app.moveWidget(item.id, to: index) },
      moveBy: { item, offset in
        if app.moveWidget(item.id, by: offset) {
          AccessibilityNotification.Announcement(offset < 0 ? "Moved up" : "Moved down").post()
        }
      },
      configure: { item in app.sheet = .widgetConfig(item.kind, entry: item.id) })
  }

  var body: some View {
    let finish = onboarding?.finishSetupModel()
    NavigationStack(path: Bindable(app.router).home) {
      TabScreen(
        app: app, title: nil,
        wash: HWash(snapshot.hero.wash)
      ) {
        if session?.reviewAccount == true {
          SampleDataLabel()
            .padding(.horizontal, HSpacing.insetPage)
            .padding(.bottom, -12)
        }
        HomeHero(
          hero: snapshot.hero, hidden: hidden, period: app.period.title, isThisMonth: snapshot.isThisMonth,
          changePeriod: { app.sheet = .period },
          backToThisMonth: { app.period = .month(app.store.now.date.yearMonth) },
          insights: { app.router.home.append(.insights) },
          reading: app.mailbox?.importing != nil,
          openNotCounted: { model.openNotCounted($0) },
          openRates: { mark in
            app.router.open(.profile, profile: [.exchangeRates] + (mark.currency.map { [.editRate($0)] } ?? []))
          })
          // Paper: 12 from the header to the pill's row (content 8, hero 4); the tab screen's
          // column starts 20 down for a large title.
          .padding(.top, -8)
        if let finish, snapshot.isThisMonth {
          FinishSetupSection(model: finish, items: finish.items, importing: app.mailbox?.importing != nil) {
            app.router.open(.profile, profile: [.bankAlerts])
          }
        }
        if !canvas.isEmpty || snapshot.isThisMonth {
          WidgetCanvas(title: snapshot.canvasTitle, items: canvas, hidden: hidden,
                       editable: snapshot.isThisMonth, editing: app.editingHome && snapshot.isThisMonth,
                       actions: canvasActions)
        }
        if !snapshot.aboutNow.isEmpty {
          StillAboutNow(rows: snapshot.aboutNow, hidden: hidden) { destination in
            model.openNotification(destination)?()
          }
          .padding(.top, canvas.isEmpty ? 0 : -8)
        }
      }
      .overlay(alignment: .bottom) {
        HomeImportPill(work: app.mailbox?.importing) { app.router.open(.profile, profile: [.bankAlerts]) }
          .padding(.bottom, 12)
      }
      .task(id: app.store.revision) {
        finish?.refresh(hasTransactions: !app.store.state.txns.isEmpty)
        await finish?.remindAboutPhrase()
      }
      .task { await finish?.resumeImport() }
      .background {
        if let security = finish?.phraseSecurity { PhraseOnHome(model: security) }
      }
      .sheet(item: Binding(get: { finish?.planFlow }, set: { finish?.planFlow = $0 })) { MonthlyPlanSheet(model: $0) }
      .sheet(isPresented: Binding(get: { finish?.askingNotifications ?? false },
                                  set: { finish?.askingNotifications = $0 })) {
        if let finish { NotificationsAskSheet(model: finish) }
      }
      .sheet(isPresented: Binding(get: { finish?.showingNoAlerts ?? false },
                                  set: { finish?.showingNoAlerts = $0 }),
             onDismiss: {
               if finish?.takeBankAlertsRequest() == true { app.router.open(.profile, profile: [.bankAlerts]) }
             }) {
        if let finish { NoAlertsSheet(model: finish) }
      }
      .onChange(of: snapshot.isThisMonth) { _, _ in app.editingHome = false }
      .onChange(of: app.tab) { _, tab in if tab != .home { app.editingHome = false } }
      .navigationDestination(for: HomeRoute.self) { route in
        switch route {
        case .bills: BillsScreen(app: app)
        case .bill(let id): BillDetailView(app: app, bill: id)
        case .accounts: AccountsView(app: app)
        case .insights: InsightsView(app: app)
        }
      }
    }
  }
}

struct StillAboutNow: View {
  let rows: [AboutNowRow]
  let hidden: Bool
  let open: (NotificationDestination) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Still about now").hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .accessibilityAddTraits(.isHeader)
      HListCard {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
          if i > 0 { HDivider(inset: .text16).padding(.trailing, 16) }
          Button { open(row.destination) } label: {
            ReflowingRow(spacing: 12) {
              Text(row.title).hType(.headline).foregroundStyle(HColor.listRowTitle)
            } trailing: {
              Text(row.detail.rendered(hidden: hidden)).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(row.title)
          .accessibilityValue(row.detail.spoken(hidden: hidden))
          .accessibilityAddTraits(.isButton)
          .accessibilityIdentifier("home.aboutNow.\(row.id)")
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

struct HomeImportPill: View {
  var work: MailImport?
  var open: () -> Void = {}

  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let motion = MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
    ZStack {
      if let work {
        if work.opensBankAlerts {
          Button(action: open) {
            BackgroundWorkPill(label: work.label, count: work.count, busy: work.busy)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(work.label)
          .accessibilityHint("Opens Bank alerts")
          .accessibilityIdentifier("home.importPill")
          .transition(motion.transition(.fade))
        } else {
          BackgroundWorkPill(label: work.label, count: work.count, busy: work.busy)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("home.importPill")
            .transition(motion.transition(.fade))
        }
      }
    }
    .frame(maxWidth: .infinity)
    .animation(motion.animation(.fade), value: work != nil)
    .animation(motion.animation(.stateSwap), value: work?.state)
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

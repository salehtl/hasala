import HasalaDesign
import SwiftUI

/// Setup after the account (Paper row 10), one navigation stack.
struct SetupFlowView: View {
  @State private var model: SetupModel

  init(model: SetupModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack(path: $model.path) {
      BankView(model: model)
        .navigationDestination(for: SetupRoute.self) { route in
          switch route {
          case .gmail: GmailView(model: model)
          case .scan: ScanView(model: model)
          case .income: IncomeView(model: model)
          case .plan: StartingPlanView(model: model)
          case .cards: CardsView(model: model)
          case .result: ScanResultView(model: model)
          case .notifications: NotificationsStepView(model: model)
          case .done: DoneView(model: model)
          }
        }
    }
    .onAppear { model.resume() }
  }
}

private func failureText(_ f: SetupFailure?) -> some View {
  Group {
    if let m = f?.message {
      FailureBanner(failure: .badPhrase(m))
    }
  }
}

// MARK: - Bank (1 of 5)

struct BankView: View {
  @Bindable var model: SetupModel
  @State private var telling = false

  var body: some View {
    AccountScreen(
      title: "Which bank do you use?",
      subtitle: "Pick yours. Hasala reads only their transaction alerts, nothing else in your mail.",
      steps: (1, 5),
      trailing: ("Skip", model.skipBanks)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Available now").hType(.overline).foregroundStyle(HColor.textSecondary).padding(.leading, 16)
        VStack(spacing: 0) {
          ForEach(Array(SupportedBank.allCases.enumerated()), id: \.element) { i, bank in
            if i > 0 { Divider().padding(.leading, 68) }
            bankRow(bank)
          }
        }
        .listCard()
        HStack(spacing: 14) {
          Image(systemName: "plus")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(HColor.iconSecondary)
            .frame(width: 40, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HColor.borderControl, lineWidth: 1))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("Another bank?").hType(.headline).foregroundStyle(HColor.textPrimary)
            Text(model.bankRequestSent ? "Thanks. We'll email you when it's ready." : "Coming soon. Tell us yours.")
              .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
          Spacer()
          Button("Tell us") { telling = true }
            .buttonStyle(.pill(.secondary, size: .small))
            .accessibilityIdentifier("bank.tellUs")
        }
        .padding(16)
        .listCard()
        failureText(model.failure)
      }
    } footer: {
      LockNote(text: "Next you'll connect Gmail, read-only. Only alerts from the banks you pick are downloaded, straight to this iPhone.")
        .padding(.bottom, 8)
      BusyButton(title: model.chosenBanks.count == 1 ? "Continue with 1 bank" : "Continue with \(model.chosenBanks.count) banks",
                 busy: model.busy, enabled: !model.chosenBanks.isEmpty, identifier: "bank.continue") {
        Task { await model.continueWithBanks() }
      }
    }
    .alert("Which bank do you use?", isPresented: $telling) {
      TextField("Bank name", text: $model.bankRequest)
      Button("Send") { Task { await model.sendBankRequest() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("We'll tell the developer which bank to add next. We send only the bank's name.")
    }
  }

  private func bankRow(_ bank: SupportedBank) -> some View {
    let on = model.chosenBanks.contains(bank)
    return Button {
      model.toggle(bank)
    } label: {
      HStack(spacing: 14) {
        // Paper draws the bank's monogram; a text monogram fails the Dynamic Type audit
        // inside the row's fixed disc, so the disc carries a bank glyph in the bank's tint.
        IconDisc(systemImage: "building.columns", tint: bank == .enbd ? HColor.blue100 : HColor.green50,
                 ink: bank == .enbd ? HColor.blue950 : HColor.green950)
        VStack(alignment: .leading, spacing: 2) {
          Text(bank.name).hType(.headline).foregroundStyle(HColor.textPrimary)
          if let note = bank.note { Text(note).hType(.subheadline).foregroundStyle(HColor.textSecondary) }
        }
        Spacer()
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 24))
          .foregroundStyle(on ? HColor.actionAccent : HColor.iconTertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(on ? .isSelected : [])
    .accessibilityIdentifier("bank.\(bank.rawValue)")
  }
}

// MARK: - Gmail (2 of 5)

struct GmailView: View {
  @Bindable var model: SetupModel

  var body: some View {
    AccountScreen(
      title: "Read-only Gmail, on your iPhone.",
      subtitle: "Your bank alerts are fetched from Gmail by this iPhone. Our server never receives your emails.",
      steps: (2, 5),
      onBack: model.back,
      trailing: ("Skip", model.skipGmail)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Hasala reads").hType(.overline).foregroundStyle(HColor.statusSuccessForeground)
          check("Alerts from \(model.orderedBanks.map(\.shortName).formatted(.list(type: .and))), and nothing else", ok: true)
          check("Downloaded and read here, on this iPhone", ok: true)
          Divider()
          Text("Never").hType(.overline).foregroundStyle(HColor.textSecondary)
          check("The rest of your inbox. It's never downloaded.", ok: false)
          check("Sending, deleting or changing your email", ok: false)
          check("Passing your emails to our server or an AI service", ok: false)
        }
        .padding(18)
        .listCard()
        Text("Google's permission screen still asks to let Hasala read your email, because Gmail offers nothing narrower. To catch new alerts quickly, our server is told when new mail arrives, never what it says.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        failureText(model.failure)
      }
    } footer: {
      if model.offersSampleData {
        BusyButton(title: "Use sample data", busy: model.busy, identifier: "gmail.sample") {
          Task { await model.useSampleData() }
        }
        BusyButton(title: "Connect Gmail", busy: false, kind: .tertiary, identifier: "gmail.connect") {
          Task { await model.connectGmail() }
        }
      } else {
        BusyButton(title: "Connect Gmail", busy: model.busy, identifier: "gmail.connect") {
          Task { await model.connectGmail() }
        }
        Text("Not on Gmail? Hasala works with Gmail for now.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .frame(minHeight: 28)
      }
    }
  }

  private func check(_ text: String, ok: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle.fill")
        .foregroundStyle(ok ? HColor.statusSuccessForeground : HColor.iconTertiary)
        .accessibilityHidden(true)
      Text(text).hType(.callout).foregroundStyle(HColor.textPrimary).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - The scan (2 of 5)

struct ScanProgressCard: View {
  var scan: ScanProgress?
  var banks: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        Image("HasalaMark").resizable().scaledToFit().frame(width: 48, height: 48).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(scan?.read ?? 0)").hFigure(.medium).foregroundStyle(HColor.textPrimary)
            Text("of \(scan?.total ?? 0) alerts").hType(.callout.weight(.semibold)).foregroundStyle(HColor.textSecondary)
          }
          Text("\(banks) · on this iPhone").hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
      }
      ProgressView(value: scan?.fraction ?? 0).tint(HColor.actionAccent)
    }
    .padding(18)
    .listCard()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("scan.progress")
  }
}

struct ScanView: View {
  var model: SetupModel

  var body: some View {
    AccountScreen(
      title: "Reading your bank alerts, on this iPhone.",
      subtitle: "Your alerts are read here and sealed before anything syncs. It takes a minute or two, so set up your plan meanwhile.",
      steps: (2, 5),
      onBack: model.back
    ) {
      VStack(spacing: 12) {
        ScanProgressCard(scan: model.scan, banks: model.orderedBanks.map(\.shortName).formatted(.list(type: .and)))
        VStack(alignment: .leading, spacing: 14) {
          stage("Downloading alerts from your banks", done: model.scan.map { $0.phase != .downloading } ?? false,
                running: model.scan?.phase == .downloading)
          stage("Left the rest of your inbox alone", done: model.scan != nil, running: false)
          stage("Sorting, right here", done: !(model.scan?.isRunning ?? true),
                running: model.scan?.phase == .sorting,
                detail: "Your rules first, then a UAE merchant list, then Apple's on-device model. Anything unsure waits for you. Nothing goes to an AI service.")
          stage("Seal everything before it syncs", done: false, running: false)
        }
        .padding(18)
        .listCard()
        failureText(model.failure)
      }
    } footer: {
      Button("Set up your plan") { model.planWhileScanning() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("scan.setUpPlan")
    }
  }

  private func stage(_ text: String, done: Bool, running: Bool, detail: String? = nil) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Group {
        if running {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? HColor.statusSuccessForeground : HColor.iconTertiary)
        }
      }
      .frame(width: 22)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(text).hType(running ? .rowTitle : .callout)
          .foregroundStyle(done || running ? HColor.textPrimary : HColor.textSecondary)
        if let detail, running {
          Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(done ? "done" : running ? "in progress" : "waiting")
  }
}

/// "Reading on this iPhone 214 of 268" pill shown on the income and plan steps.
struct ScanPill: View {
  var scan: ScanProgress?

  var body: some View {
    if let scan {
      HStack(spacing: 8) {
        if scan.isRunning {
          ProgressView().controlSize(.mini)
          Text("Reading on this iPhone").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          Text("\(scan.read) of \(scan.total)").hType(.footnote).foregroundStyle(HColor.textSecondary)
        } else {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(HColor.statusSuccessForeground)
          Text("All \(scan.total) alerts read on this iPhone").hType(.footnote.weight(.semibold))
            .foregroundStyle(HColor.textPrimary)
        }
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 36)
      .background(HColor.surfacePrimary, in: Capsule())
      .elevation()
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("scan.pill")
    }
  }
}

// MARK: - Income (3 of 5)

struct IncomeView: View {
  @Bindable var model: SetupModel
  @FocusState private var focused: Bool

  var body: some View {
    AccountScreen(
      title: "What lands in your account each month?",
      subtitle: "After tax. You can change it any time.",
      steps: (3, 5),
      onBack: model.back,
      trailing: ("Skip", model.skipIncome)
    ) {
      VStack(spacing: 20) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("AED").hFigure(.unit).foregroundStyle(HColor.textSecondary)
          TextField("0", text: $model.incomeText)
            .keyboardType(.numberPad)
            .focused($focused)
            .hFigure(.display)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize()
            .accessibilityIdentifier("income.field")
            .accessibilityLabel("Monthly income in dirhams")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        Menu {
          ForEach(1...31, id: \.self) { d in
            Button("Paid on the \(ordinal(d))") { model.payday = d }
          }
        } label: {
          HStack(spacing: 6) {
            Text("Paid on the \(ordinal(model.payday))").hType(.rowTitle)
            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
          }
          .foregroundStyle(HColor.textPrimary)
          .padding(.horizontal, 16)
          .frame(minHeight: 44)
          .background(HColor.surfacePrimary, in: Capsule())
        }
        .accessibilityIdentifier("income.payday")
        ScanPill(scan: model.scan)
      }
    } footer: {
      Button("Continue") { model.continueWithIncome() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("income.continue")
    }
    .onAppear { focused = true }
  }

  private func ordinal(_ d: Int) -> String {
    let suffix: String
    switch (d % 10, d % 100) {
    case (1, let t) where t != 11: suffix = "st"
    case (2, let t) where t != 12: suffix = "nd"
    case (3, let t) where t != 13: suffix = "rd"
    default: suffix = "th"
    }
    return "\(d)\(suffix)"
  }
}

// MARK: - Starting plan (4 of 5)

struct StartingPlanView: View {
  @Bindable var model: SetupModel
  @State private var editing = false

  var body: some View {
    AccountScreen(
      title: "Here's a plan to start with.",
      subtitle: "\(model.plan.needsPercent)% for needs, \(model.plan.wantsPercent)% for wants, \(model.plan.savingsPercent)% for savings. Hasala fills in your categories, and you can change any of them later.",
      steps: (4, 5),
      onBack: model.back,
      trailing: ("Skip", { Task { await model.savePlan(skip: true) } })
    ) {
      VStack(spacing: 12) {
        splitBar
        let amounts = model.incomeMinor.map { model.plan.amounts(income: $0) }
        bucket("house", HColor.bucketNeedsStart, HColor.bucketNeedsInk, "Needs", amounts?.needs,
               "Rent, utilities, groceries, transport, healthcare, insurance")
        bucket("fork.knife", HColor.bucketWantsStart, HColor.bucketWantsInk, "Wants", amounts?.wants,
               "Dining, entertainment, shopping, travel, subscriptions")
        bucket("banknote", HColor.bucketSavingsStart, HColor.bucketSavingsInk, "Savings", amounts?.savings,
               "Savings, investments, paying off debt")
        ScanPill(scan: model.scan).padding(.top, 8)
        failureText(model.failure)
      }
    } footer: {
      BusyButton(title: "Use this plan", busy: model.busy, enabled: model.plan.isValid, identifier: "plan.use") {
        Task { await model.savePlan() }
      }
      Button("Change the split") { editing = true }
        .buttonStyle(.pill(.tertiary, fill: true))
        .accessibilityIdentifier("plan.change")
    }
    .sheet(isPresented: $editing) {
      SplitEditor(plan: $model.plan).presentationDetents([.medium])
    }
  }

  private var splitBar: some View {
    let parts: [(Int, Color)] = [
      (model.plan.needsPercent, HColor.bucketNeedsInk), (model.plan.wantsPercent, HColor.bucketWantsInk),
      (model.plan.savingsPercent, HColor.bucketSavingsInk),
    ]
    return GeometryReader { geo in
      HStack(alignment: .top, spacing: 4) {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
          VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(part.1.opacity(0.3)).frame(height: 12)
            Text("\(part.0)%").hType(.footnote.weight(.semibold)).foregroundStyle(part.1)
          }
          .frame(width: max(0, (geo.size.width - 8) * CGFloat(part.0) / 100))
        }
      }
    }
    .frame(height: 36)
    .accessibilityElement()
    .accessibilityLabel(
      "Needs \(model.plan.needsPercent)%, wants \(model.plan.wantsPercent)%, savings \(model.plan.savingsPercent)%")
  }

  private func bucket(_ symbol: String, _ tint: Color, _ ink: Color, _ name: String, _ amount: Int64?, _ text: String)
    -> some View
  {
    HStack(alignment: .top, spacing: 14) {
      IconDisc(systemImage: symbol, tint: tint, ink: ink)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(name).hType(.headline).foregroundStyle(HColor.textPrimary)
          Spacer()
          if let amount {
            Text((amount / 100).formatted(.number.grouping(.automatic))).hFigure(.row).foregroundStyle(HColor.textPrimary)
            Text("a month").hType(.footnote).foregroundStyle(HColor.textSecondary)
          }
        }
        Text(text).hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .listCard()
    .accessibilityElement(children: .combine)
  }
}

struct SplitEditor: View {
  @Binding var plan: StartingPlan
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Stepper("Needs \(plan.needsPercent)%", value: $plan.needsPercent, in: 0...100, step: 5)
        Stepper("Wants \(plan.wantsPercent)%", value: $plan.wantsPercent, in: 0...100, step: 5)
        Stepper("Savings \(plan.savingsPercent)%", value: $plan.savingsPercent, in: 0...100, step: 5)
        if !plan.isValid {
          Text("The three add up to \(plan.needsPercent + plan.wantsPercent + plan.savingsPercent)%. Make them 100%.")
            .foregroundStyle(HColor.statusErrorForeground)
        }
      }
      .navigationTitle("Change the split")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.disabled(!plan.isValid)
        }
      }
    }
  }
}

// MARK: - Cards (5 of 5)

struct CardsView: View {
  @Bindable var model: SetupModel

  var body: some View {
    AccountScreen(
      title: "Are these your cards?",
      subtitle: "We found these in your bank alerts. Turn off any that aren't yours, like a family member's card, and their alerts are skipped.",
      steps: (5, 5),
      onBack: model.back
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if model.scanRunning || model.cards.isEmpty {
          ScanProgressCard(scan: model.scan, banks: model.orderedBanks.map(\.shortName).formatted(.list(type: .and)))
        } else {
          VStack(spacing: 0) {
            ForEach(Array(model.cards.enumerated()), id: \.element.id) { i, card in
              if i > 0 { Divider().padding(.leading, 72) }
              Toggle(isOn: Binding(get: { card.keep }, set: { _ in model.toggleCard(card.id) })) {
                HStack(spacing: 14) {
                  RoundedRectangle(cornerRadius: 6)
                    .fill(card.bank == .enbd ? HColor.blue800 : HColor.green700)
                    .frame(width: 40, height: 28)
                    .opacity(card.keep ? 1 : 0.4)
                    .accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 2) {
                    Text("\(card.bank.name) ·· \(card.last4)").hType(.headline)
                      .foregroundStyle(card.keep ? HColor.textPrimary : HColor.textSecondary)
                    Text(card.keep ? "\(card.alertCount) transactions" : "Not yours · \(card.alertCount) alerts skipped")
                      .hType(.footnote).foregroundStyle(HColor.textSecondary)
                  }
                }
              }
              .tint(HColor.actionAccent)
              .padding(.horizontal, 16)
              .frame(minHeight: 68)
              .accessibilityIdentifier("card.\(card.last4)")
            }
          }
          .listCard()
          Text("Only alerts from cards you keep on are counted. If a new card turns up later, Hasala asks you first. Change this any time in Bank alerts.")
            .hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        failureText(model.failure)
      }
    } footer: {
      ScanPill(scan: model.scan).padding(.bottom, 8)
      BusyButton(title: model.keptCards == 1 ? "Continue with 1 card" : "Continue with \(model.keptCards) cards",
                 busy: model.busy, enabled: !model.scanRunning && !model.cards.isEmpty, identifier: "cards.continue") {
        Task { await model.confirmCards() }
      }
    }
  }
}

// MARK: - Result

struct ScanResultView: View {
  var model: SetupModel

  var body: some View {
    let s = model.summary ?? ScanSummary(total: 0, byRules: 0, byDictionary: 0, byModel: 0, toReview: 0)
    AccountScreen(
      title: "\(s.total) transactions, sorted.",
      subtitle: "All on this iPhone. \(s.sortedThemselves) sorted themselves; \(s.toReview) wait for a quick swipe.",
      wash: HColor.hueMintStart,
      centered: true
    ) {
      VStack(spacing: 16) {
        SuccessBadge().frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 12) {
          Text("How they were sorted").hType(.overline).foregroundStyle(HColor.textSecondary)
          row(HColor.actionAccent, "UAE merchant list", s.byDictionary)
          row(HColor.blue300, "Apple's on-device model", s.byModel)
          row(HColor.amber300, "Waiting for your swipe", s.toReview)
          Divider()
          Text("From now on your own rules go first. Nothing was sent to an AI service.")
            .hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .listCard()
      }
    } footer: {
      Button("Continue") { model.path.append(.notifications) }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("result.continue")
    }
  }

  private func row(_ color: Color, _ text: String, _ n: Int) -> some View {
    HStack(spacing: 10) {
      Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(text).hType(.callout).foregroundStyle(HColor.textPrimary)
      Spacer()
      Text("\(n)").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Notifications

struct NotificationsStepView: View {
  @Bindable var model: SetupModel

  var body: some View {
    AccountScreen(
      title: "A nudge when money moves.",
      subtitle: "A short note when a transaction lands, a bill is due or a budget reaches 80%."
    ) {
      VStack(spacing: 14) {
        VStack(spacing: 10) {
          Text("9:41").font(.system(.largeTitle, design: .rounded).weight(.semibold)).foregroundStyle(HColor.white)
          HStack(spacing: 12) {
            Image("HasalaMark").resizable().scaledToFit().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
              Text("Hasala").hType(.rowTitle)
              Text(model.showDetails ? "AED 342.15 at Carrefour" : "New transaction").hType(.subheadline)
            }
            Spacer()
            Text("now").hType(.footnote).foregroundStyle(HColor.textSecondary)
          }
          .foregroundStyle(HColor.textPrimary)
          .padding(14)
          .background(HColor.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(18)
        .background(LinearGradient(colors: [HColor.blue950, HColor.blue800], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lock Screen preview: \(model.showDetails ? "amount and merchant shown" : "New transaction")")
        Text("What your Lock Screen shows by default").hType(.footnote).foregroundStyle(HColor.textSecondary)
        Toggle(isOn: $model.showDetails) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Show amounts and merchants").hType(.headline).foregroundStyle(HColor.textPrimary)
            Text("Off by default, so a glance at your Lock Screen shows no amounts or names.")
              .hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        .tint(HColor.actionAccent)
        .padding(16)
        .listCard()
        .accessibilityIdentifier("notifications.details")
        LockNote(text: "Hasala writes its notifications on this iPhone. Our server only sends a silent signal to wake the app. It never sends what a notification says.")
      }
    } footer: {
      Button("Allow notifications") { Task { await model.allowNotifications() } }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("notifications.allow")
      LinkButton(title: "Not now", identifier: "notifications.notNow") { model.notNow() }
    }
  }
}

// MARK: - Done

struct DoneView: View {
  var model: SetupModel

  var body: some View {
    AccountScreen(
      title: model.firstName.isEmpty ? "You're set." : "You're set, \(model.firstName).",
      subtitle: "Your budget is worked out on this iPhone, and the key stays with you.",
      wash: HColor.hueMintStart,
      centered: true
    ) {
      VStack(spacing: 14) {
        Image("HasalaMark").resizable().scaledToFit().frame(width: 132, height: 120).frame(maxWidth: .infinity)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 12) {
          if let s = model.summary { done("\(s.total) transactions sorted on this iPhone") }
          if model.facts.planSet { done("Your plan is ready, starting at \(model.plan.needsPercent)/\(model.plan.wantsPercent)/\(model.plan.savingsPercent)") }
          done("Encrypted on this iPhone before it syncs")
          done(model.showDetails ? "Lock Screen shows amounts and merchants" : "Lock Screen shows no amounts or names")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listCard()
        NoteCard(systemImage: "key", title: "Keep your recovery phrase safe",
                 text: "It and your passkey are the only ways to unlock your data on a new iPhone. We can't reset them.",
                 tint: HColor.statusWarningSurface)
      }
    } footer: {
      Button("Go to Home") { model.finish() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("done.home")
    }
  }

  private func done(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(HColor.statusSuccessForeground).accessibilityHidden(true)
      Text(text).hType(.callout).foregroundStyle(HColor.textPrimary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

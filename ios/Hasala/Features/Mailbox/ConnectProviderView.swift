import HasalaDesign
import HasalaModels
import SwiftUI

/// The read-only connect screen for one provider (Paper "Setup · 2 of 4 · Connect Gmail,
/// read-only" 6RN, "Connect email · Setup 2 of 4 · Outlook, read-only" 1MRM), in setup and
/// in the profile: where the alerts come from and who reads them, what Hasala reads and
/// never reads, then the provider's own sign-in ("Continue with Google", "Continue with
/// Microsoft"; Microsoft's and Google's screens are theirs, in the system web sheet).
///
/// Once connected it shows the mailbox and "Continue" (`mail.continue`), never a second
/// sign-in: setup's Back from the first scan lands here (plan B3.2 rule 2). In setup it
/// carries the step indicator; in the profile it doesn't. A failure that has its own screen
/// (`MailConnectCoordinator.errorScreen`) is the host's to show; the rest show here.
///
/// When the build holds one link and the account's is to the other provider, the sign-in
/// asks first, in the system alert the disconnect uses: "Change your email?" ("This
/// replaces your Gmail connection. …", "Use Outlook").
struct ConnectProviderView: View {
  let provider: MailProviderKind
  @Bindable var coordinator: MailConnectCoordinator
  let banks: [SupportedBank]
  /// Review accounts: "Use sample data" (`mail.sample`) instead of mail.
  var sample: (() -> Void)?
  var onConnected: (String) -> Void
  var onChooseDifferent: () -> Void
  /// The providers are the screen behind this one (Profile › Bank alerts › Add a mailbox):
  /// the system Back is how to pick another, so the dock doesn't offer it again, and the
  /// screen fits above its dock inside the profile sheet.
  var choiceIsBack: Bool
  /// The mailbox a confirmed sign-in replaces, while "Change your email?" asks.
  @State private var switching: MailboxSnapshot?
  /// The provider of the link a confirmed sign-in takes over from another iPhone, while
  /// "Read your email on this iPhone?" asks.
  @State private var takingOver: MailProviderKind?

  init(
    provider: MailProviderKind, coordinator: MailConnectCoordinator, banks: [SupportedBank],
    sample: (() -> Void)? = nil, onConnected: @escaping (String) -> Void, onChooseDifferent: @escaping () -> Void,
    choiceIsBack: Bool = false
  ) {
    self.provider = provider
    self.coordinator = coordinator
    self.banks = banks
    self.sample = sample
    self.onConnected = onConnected
    self.onChooseDifferent = onChooseDifferent
    self.choiceIsBack = choiceIsBack
  }

  private var steps: (current: Int, of: Int)? {
    if case .setup(let steps) = coordinator.context { return steps.map { ($0.0, $0.1) } }
    return nil
  }

  private var signInAgainID: String? {
    if case .signInAgain(let id) = coordinator.context { return id }
    return nil
  }

  private var isSetup: Bool {
    if case .setup = coordinator.context { return true }
    return false
  }

  var body: some View {
    let connected = coordinator.connectedMailbox(provider)
    AccountScreen(title: title(connected), subtitle: subtitle, steps: steps, back: .system) {
      VStack(alignment: .leading, spacing: 0) {
        Group {
          if let connected {
            HListCard { MailboxRow(connected) }
              .accessibilityIdentifier("mail.connected")
          } else {
            FlowStrip(provider: provider)
          }
        }
        .hTransition(.stateSwap)
        ReadsNeverCard(banks: banks)
          .padding(.top, 16)
        Text(MailCopy.readNote)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 10)
          .padding(.horizontal, 8)
        if let message = coordinator.inlineMessage, case .failed(let failure)? = coordinator.outcome {
          InlineStatus(tone: Self.tone(failure), text: message, size: .regular)
            .padding(.top, 16)
            .padding(.horizontal, 8)
            .hTransition(.rise)
            .accessibilityIdentifier("mail.status")
        }
      }
      // Paper puts the strip 20 under the question; the template leaves 24.
      .padding(.top, -4)
      .hAnimation(.stateSwap, value: connected?.id)
      .hAnimation(.rise, value: coordinator.inlineMessage)
    } footer: {
      if let connected {
        BusyButton(title: "Continue", busy: false, identifier: "mail.continue") { onConnected(connected.id) }
          .dockPill()
      } else if let sample {
        // A review account: the sample month is the one pill, as the foundation drew it,
        // and the provider's sign-in is the text button under it. Nothing else to choose,
        // so no footer link: the dock stays as tall as Paper's (a pill and a 44 line), and
        // the caption keeps clear of it.
        BusyButton(title: "Use sample data", busy: false, identifier: "mail.sample", action: sample)
          .dockPill()
        Button(action: connect) {
          HStack(spacing: 10) {
            if !coordinator.busy { ProviderMark(provider, size: .disc26) }
            Text(provider.continueTitle)
          }
        }
        .buttonStyle(.pill(.tertiary, size: .medium, fill: true, loading: coordinator.busy))
        .dockPill()
        .accessibilityIdentifier("mail.connect.\(provider.rawValue)")
      } else {
        ProviderButton(provider: provider, loading: coordinator.busy, action: connect)
          .dockPill()
          .accessibilityIdentifier("mail.connect.\(provider.rawValue)")
        footerLink
      }
    }
    // At large text sizes the screen scrolls under its dock: say so once.
    .scrollIndicatorsFlash(onAppear: true)
    .alert(MailCopy.switchTitle, isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
           presenting: switching) { _ in
      Button("Cancel", role: .cancel) {}
      Button("Use \(provider.appName)") { run(replacing: true) }
        .accessibilityIdentifier("mail.confirmSwitch")
    } message: { old in
      Text(MailCopy.switchMessage(from: old.provider, to: provider))
    }
    .alert(MailCopy.takeoverTitle, isPresented: Binding(get: { takingOver != nil }, set: { if !$0 { takingOver = nil } }),
           presenting: takingOver) { _ in
      Button("Cancel", role: .cancel) {}
      Button("Read it here") { run(replacing: true) }
        .accessibilityIdentifier("mail.confirmTakeover")
    } message: { held in
      Text(MailCopy.takeoverMessage(from: held, to: provider))
    }
    // Setup moves on to the first scan; the profile's moment is Bank alerts' new row.
    .hHaptic(.success, trigger: connectedOutcome) { _, new in isSetup && new != nil }
  }

  private var connectedOutcome: String? {
    if case .connected(let id)? = coordinator.outcome { return id }
    return nil
  }

  private func title(_ connected: MailboxSnapshot?) -> String {
    if connected != nil { return "\(provider.appName) is connected." }
    if signInAgainID != nil { return "Sign in to \(provider.appName) again." }
    return "Read-only \(provider.appName), on your iPhone."
  }

  private var subtitle: String {
    if let id = signInAgainID, coordinator.connectedMailbox(provider) == nil {
      let row = coordinator.mailbox.mailboxes.first { $0.id == id }
      // A sign-in that the provider didn't end (live: no Outlook mailbox on that account).
      if let note = row?.note { return note }
      let address = row?.address ?? "this mailbox"
      return "\(provider.company) ended Hasala's access to \(address). Sign in again and this iPhone catches up. Nothing else changes."
    }
    return "Your bank alerts are fetched from \(provider.appName) by this iPhone. Our server never receives your emails."
  }

  /// "Not your email? Choose a different one." (Gmail, 6RN); Outlook says first that a work
  /// account may need its admin (1MRM). With one provider to offer there is nothing else to
  /// choose, so it asks which email the person uses instead (plan B4.6 rule 2). A new
  /// sign-in to one mailbox has nothing to choose, and with the providers behind this
  /// screen Back chooses (Outlook keeps its line about accounts).
  ///
  /// The live Microsoft app takes personal accounts only, in every build, so the Release
  /// surface says so (main's footnote) where Paper draws the work account's line; Debug
  /// keeps Paper's, which the `outlookAdmin` mock's admin board follows.
  @ViewBuilder private var footerLink: some View {
    if signInAgainID != nil {
      EmptyView()
    } else if coordinator.mailbox.connectable.count <= 1 {
      TellUsWhichLink()
    } else if choiceIsBack {
      if provider == .outlook {
        Text(Self.outlookAccountLine)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
          .accessibilityIdentifier(BuildSurface.showsUnfinished ? "mail.workAccount" : "mail.personalOnly")
      }
    } else if provider == .outlook {
      TextLinkRow(lead: Self.outlookAccountLine,
                  link: "Choose a different email", identifier: "mail.notYours", action: onChooseDifferent)
    } else {
      TextLinkRow(lead: "Not your email?", link: "Choose a different one.", identifier: "mail.notYours",
                  action: onChooseDifferent)
    }
  }

  /// Outlook's line about which Microsoft accounts work.
  static var outlookAccountLine: String {
    BuildSurface.showsUnfinished
      ? "Work or school account? Your organisation may need to approve Hasala first."
      : "Outlook: personal Microsoft accounts only."
  }

  /// The provider's sign-in; once connected, on to the next screen. A sign-in that would
  /// replace the account's link to another provider asks first.
  private func connect() {
    if let held = coordinator.takesOver {
      takingOver = held
    } else if let old = coordinator.replaced(by: provider) {
      switching = old
    } else {
      run(replacing: false)
    }
  }

  private func run(replacing: Bool) {
    Task {
      await coordinator.connect(provider, replacing: replacing)
      if case .connected(let id)? = coordinator.outcome { onConnected(id) }
    }
  }

  /// Amber for what fixes itself or waits on the person elsewhere, red for a failure, blue
  /// for a mailbox already read here.
  static func tone(_ failure: MailConnectFailure) -> InlineStatus.Tone {
    switch failure {
    case .alreadyConnected: .accent
    case .offline, .takenByOtherIPhone, .cancelled: .warning
    case .adminApprovalNeeded, .noMailbox, .failed: .error
    }
  }
}

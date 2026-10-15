/// The mail providers a person can read bank alerts from (Paper P2 "14.9 · Connect your email").
///
/// This is the app's own, provider-neutral name for a provider. It does not mirror
/// CoreMailbox's `MailProviderID`; the mapping lives only in the app's live mailbox layer.
public enum MailProviderKind: String, CaseIterable, Sendable, Identifiable, Codable {
  case gmail
  case outlook

  public var id: String { rawValue }

  /// "Gmail", "Outlook".
  public var appName: String {
    switch self {
    case .gmail: "Gmail"
    case .outlook: "Outlook"
    }
  }

  /// "Google", "Microsoft".
  public var company: String {
    switch self {
    case .gmail: "Google"
    case .outlook: "Microsoft"
    }
  }

  /// The provider button: "Continue with Google", "Continue with Microsoft".
  public var continueTitle: String { "Continue with \(company)" }

  /// The second line of the provider's row in "Choose your email".
  public var chooserSubtitle: String {
    switch self {
    case .gmail: "Any Google account"
    case .outlook: "Outlook.com, Hotmail, Live, or work or school Microsoft 365"
    }
  }

  /// How Hasala reaches the mailbox, as the mailbox detail says it.
  public var access: String {
    switch self {
    case .gmail: "Read-only mail"
    case .outlook: "Read-only, through Microsoft"
    }
  }
}

/// Where one mailbox is (Paper page 15 "Mailbox row": four status chips).
public enum MailboxState: Hashable, Sendable {
  /// Connected and reading its first alerts: "Checking now".
  case syncing
  case connected
  /// The provider ended Hasala's access; a new sign-in fixes it.
  case needsSignIn
  /// The person disconnected it. Past transactions stay.
  case disconnected
}

/// One mailbox as every surface draws it. Strings are ready to show; nothing here is sent
/// anywhere (the mailbox list stays on the device).
public struct MailboxSnapshot: Identifiable, Hashable, Sendable {
  /// "gmail" in the live build; "gmail-1", "outlook-1" in the mock.
  public var id: String
  public var provider: MailProviderKind
  /// The mailbox address, never the Hasala account email.
  public var address: String
  public var state: MailboxState
  /// The freshness line: "Checked 4 min ago", "Checking now", "Checked Wed", "Off since 2 Oct".
  public var meta: String
  /// "Personal Microsoft", "Work or school"; nil for Google.
  public var accountKind: String?
  /// The banks read from this mailbox: "Emirates NBD", "Dubai Islamic Bank".
  public var banks: [String]
  /// "Wed 7 Oct, 09:14".
  public var lastChecked: String?
  /// "2 Oct".
  public var connectedOn: String?
  /// A line under the row, e.g. "Read on your other iPhone".
  public var note: String?

  public init(
    id: String, provider: MailProviderKind, address: String, state: MailboxState, meta: String,
    accountKind: String? = nil, banks: [String] = [], lastChecked: String? = nil, connectedOn: String? = nil,
    note: String? = nil
  ) {
    self.id = id
    self.provider = provider
    self.address = address
    self.state = state
    self.meta = meta
    self.accountKind = accountKind
    self.banks = banks
    self.lastChecked = lastChecked
    self.connectedOn = connectedOn
    self.note = note
  }
}

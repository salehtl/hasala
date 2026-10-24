import HasalaModels

/// Main's Live layer names the provider `MailboxProvider`; the app's contract names it
/// `MailProviderKind` (HasalaModels). Same cases, same raw values ("gmail", "outlook"), so
/// LocalAccountData's stored value reads back unchanged.
typealias MailboxProvider = MailProviderKind

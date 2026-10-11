// CoreMailbox (Mailbox/), spec 04 §2.2 and §7. Owner: WS-12. The Gmail lane on the holder iPhone.
//
//   HTTP.swift                 the HTTPExchange seam; ephemeral URLSession for Google (§7.2)
//   GmailOAuth.swift           PKCE, state, authorize URL, callback check, token endpoint (§7.2)
//   TokenProvider.swift        GmailTokenProvider (§2.7) and the Keychain-backed refresh custody (§7.3)
//   GmailClient.swift          profile, sender-filtered messages.list, metadata/raw get, watch, stop
//   BankDomains.swift          the trusted set, the sender query, typed-sender normalization (§7.5, §7.6)
//   Disposition.swift          one message -> set aside | ParsedMail -> txn_ingested payload (§7.6)
//   MailboxState.swift         mailbox_* tables as values and the MailboxPersistence port (§4.2)
//   Ports.swift                MailboxLedger, MailboxServer, MailboxStepUp (the rest of the app)
//   MailboxServerClient.swift  hasalad routes 34-38 and meta (spec 02 §13)
//   MailboxEngine.swift        connect, the cycle, first-connect scan, Add a sender, View the email
//
// Platform halves live in the app: Platform/GmailAuth (ASWebAuthenticationSession presenter,
// Keychain refresh-token store) and Platform/Background (BGAppRefreshTask, BGProcessingTask).

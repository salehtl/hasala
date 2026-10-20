import HasalaModels

/// The setup screens after the account (Paper row 10 and P2.9 row 1), pushed over the bank
/// step: your email (read-only, per provider), its error, the first scan, income, the
/// starting plan, the result, notifications and done. "Choose your email" is a sheet over
/// the bank step, not a route.
enum SetupRoute: Hashable {
  /// The read-only connect screen for one provider; its connected state once it ran.
  case connect(MailProviderKind)
  /// The connect didn't happen (an admin's approval, a closed or declined sign-in).
  case connectError(MailProviderKind)
  case scan
  case income
  case plan
  case result
  case sort
  case notifications
  case done
}

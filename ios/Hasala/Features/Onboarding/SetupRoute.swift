import HasalaModels

/// The setup screens pushed over the bank step, which connects the email itself: the
/// connect's error. "Choose your email" is a sheet over the bank step, not a route.
enum SetupRoute: Hashable {
  /// The connect didn't happen (an admin's approval, a closed or declined sign-in).
  case connectError(MailProviderKind)
}

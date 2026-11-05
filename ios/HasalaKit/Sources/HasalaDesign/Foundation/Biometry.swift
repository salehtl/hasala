public enum HBiometry: Sendable, Hashable, CaseIterable {
  case faceID, touchID, opticID, none

  public var name: String? {
    switch self {
    case .faceID: "Face ID"
    case .touchID: "Touch ID"
    case .opticID: "Optic ID"
    case .none: nil
    }
  }

  public var icon: HIcon {
    switch self {
    case .faceID, .opticID: .faceID
    case .touchID: .touchID
    case .none: .passkey
    }
  }

  public var signInTitle: String {
    name.map { "Sign in with \($0)" } ?? "Sign in with your passkey"
  }

  public var confirmTitle: String {
    name.map { "Confirm with \($0)" } ?? "Confirm with your passkey"
  }

  public func use(_ action: String) -> String {
    name.map { "Use \($0) to \(action)" } ?? "Use your passkey to \(action)"
  }
}

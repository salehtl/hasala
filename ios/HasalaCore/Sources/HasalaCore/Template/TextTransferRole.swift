public enum TextTransferRole: String, Sendable, Equatable, CaseIterable {
  case notice
  case alert

  static func parse(_ s: String) -> TextTransferRole? {
    allCases.first { $0.rawValue.utf8.elementsEqual(s.utf8) }
  }

  public init?(definition d: TemplateDefinition) {
    guard d.isSMS, let role = Self.parse(d.transferRole) else { return nil }
    self = role
  }

  public static let byTemplate: [String: TextTransferRole] = Dictionary(
    BundledTemplates.load(channel: .sms).templates.compactMap { t in
      TextTransferRole(definition: t.definition).map { (t.definition.id, $0) }
    },
    uniquingKeysWith: { first, _ in first })

  public static func of(templateRef ref: String) -> TextTransferRole? {
    byTemplate[String(ref.prefix { $0 != "@" })]
  }

  public var counterpart: TextTransferRole { self == .notice ? .alert : .notice }
}

import CoreCategorize
import CoreReplay
import HasalaText

public enum CategoryRefusal: Error, Sendable, Equatable {
  case nameEmpty
  case nameTooLong(max: Int)
  case nameInvalid
  case nameTaken(String)
  case iconInvalid
  case parentNotAllowed
  case atCap(max: Int)
  case unknownCategory
  case builtinLocked
  case systemCannotHide

  public var message: String {
    switch self {
    case .nameEmpty: "Enter a name."
    case .nameTooLong(let max): "Use \(max) characters or fewer."
    case .nameInvalid: "This name has a character that cannot be used."
    case .nameTaken(let name): "You already have a category named \(name)."
    case .iconInvalid: "Choose another icon."
    case .parentNotAllowed: "Choose a category from the list for it to count as."
    case .atCap(let max): "You have \(max) categories. Archive one to add another."
    case .unknownCategory: "This category no longer exists."
    case .builtinLocked: "A built-in category keeps its type."
    case .systemCannotHide: "This category is needed and cannot be hidden."
    }
  }
}

public struct CategoryRules: Sendable {
  public let view: TaxonomyView

  public init(_ view: TaxonomyView) { self.view = view }

  public var activeCustomCount: Int { view.ordered.filter { !$0.builtin && $0.active }.count }

  public var canAddActive: Bool { activeCustomCount < TaxonomyV1.maxActiveCustom }

  public static func nameKey(_ name: String) -> String { UserText.normalize(name).lowercased() }

  public func checkName(_ typed: String, excluding id: String? = nil) -> CategoryRefusal? {
    let name = UserText.normalize(typed)
    if name.isEmpty { return .nameEmpty }
    if name.unicodeScalars.count > TaxonomyV1.maxNameScalars { return .nameTooLong(max: TaxonomyV1.maxNameScalars) }
    if TextRules.checkLabel(name) != nil { return .nameInvalid }
    let key = Self.nameKey(name)
    let clash = view.ordered.first { c in
      c.active && !(id.map { utf8Equal($0, c.id) } ?? false) && Self.nameKey(c.name) == key
    }
    if let clash { return .nameTaken(clash.name) }
    return nil
  }

  public func checkIcon(_ icon: String?) -> CategoryRefusal? {
    guard let icon else { return nil }
    return Grammar.isIconID(icon) ? nil : .iconInvalid
  }

  public func checkCreate(name: String, parent: String, icon: String? = nil) -> CategoryRefusal? {
    if let r = checkName(name) { return r }
    if let r = checkIcon(icon) { return r }
    guard isOfferedParent(parent) else { return .parentNotAllowed }
    guard canAddActive else { return .atCap(max: TaxonomyV1.maxActiveCustom) }
    return nil
  }

  public func checkEdit(id: String, name: String? = nil, icon: String? = nil, parent: String? = nil) -> CategoryRefusal? {
    guard let current = view.info(id) else { return .unknownCategory }
    if let name, UserText.normalize(name) != current.name, let r = checkName(name, excluding: current.id) { return r }
    if let r = checkIcon(icon) { return r }
    if let parent {
      if current.builtin { return .builtinLocked }
      let unchanged = current.parent.map { utf8Equal($0, parent) } ?? false
      guard unchanged ? TaxonomyV1.isParentCandidate(parent) : isOfferedParent(parent) else { return .parentNotAllowed }
    }
    return nil
  }

  public func checkSetActive(id: String, active: Bool) -> CategoryRefusal? {
    guard let current = view.info(id) else { return .unknownCategory }
    if !active { return current.builtin && TaxonomyV1.isSystem(current.id) ? .systemCannotHide : nil }
    if current.active { return nil }
    if let r = checkName(current.name, excluding: current.id), case .nameTaken = r { return r }
    if current.builtin { return nil }
    return canAddActive ? nil : .atCap(max: TaxonomyV1.maxActiveCustom)
  }

  public func isOfferedParent(_ parent: String) -> Bool {
    TaxonomyV1.isParentCandidate(parent) && (view.info(parent)?.active ?? true)
  }
}

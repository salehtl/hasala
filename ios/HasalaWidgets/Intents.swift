import AppIntents
import HasalaModels
import HasalaWidgetData
import WidgetKit

private func storedSnapshot() -> WidgetSnapshot? {
  WidgetSnapshotStore.shared()?.read()
}

struct CategoryEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
  static let defaultQuery = CategoryEntityQuery()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CategoryEntityQuery: EntityQuery {
  func entities(for identifiers: [CategoryEntity.ID]) async throws -> [CategoryEntity] {
    all().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [CategoryEntity] { all() }

  func defaultResult() async -> CategoryEntity? {
    storedSnapshot()?.category(nil).map { CategoryEntity(id: $0.id, name: $0.name) }
  }

  private func all() -> [CategoryEntity] {
    (storedSnapshot()?.categories ?? []).map { CategoryEntity(id: $0.id, name: $0.name) }
  }
}

struct CategoryWatchIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Category watch"
  static let description = IntentDescription("Choose the category to watch.")

  @Parameter(title: "Category")
  var category: CategoryEntity?
}

struct ProjectEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
  static let defaultQuery = ProjectEntityQuery()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ProjectEntityQuery: EntityQuery {
  func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
    all().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [ProjectEntity] { all() }

  func defaultResult() async -> ProjectEntity? { all().first }

  private func all() -> [ProjectEntity] {
    (storedSnapshot()?.projects ?? []).compactMap { w in w.id.map { ProjectEntity(id: $0, name: w.name) } }
  }
}

struct ProjectWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Project"
  static let description = IntentDescription("Choose the project to follow.")

  @Parameter(title: "Project")
  var project: ProjectEntity?
}

struct GoalEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Goal"
  static let defaultQuery = GoalEntityQuery()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct GoalEntityQuery: EntityQuery {
  func entities(for identifiers: [GoalEntity.ID]) async throws -> [GoalEntity] {
    all().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [GoalEntity] { all() }

  func defaultResult() async -> GoalEntity? { all().first }

  private func all() -> [GoalEntity] {
    (storedSnapshot()?.goals ?? []).compactMap { w in w.id.map { GoalEntity(id: $0, name: w.name) } }
  }
}

struct GoalWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Goal"
  static let description = IntentDescription("Choose the savings goal to follow.")

  @Parameter(title: "Goal")
  var goal: GoalEntity?
}

import Foundation
import HasalaModels

public struct WidgetSnapshotStore: Sendable {
  public static let appGroup = "group.app.hasala.ios"
  public static let fileName = "widget-snapshot.json"
  public static let directoryName = "Widgets"

  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public static func shared() -> WidgetSnapshotStore? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      return nil
    }
    return WidgetSnapshotStore(
      directory: container.appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true))
  }

  public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

  public static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
  }

  public static func decode(_ data: Data) -> WidgetSnapshot? {
    guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
      snapshot.version == WidgetSnapshot.currentVersion
    else { return nil }
    return snapshot
  }

  @discardableResult
  public func write(_ snapshot: WidgetSnapshot) throws -> Data {
    let data = try Self.encode(snapshot)
    try write(data)
    return data
  }

  public func write(_ data: Data) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = fileURL
    try url.setResourceValues(values)
  }

  public func read() -> WidgetSnapshot? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return Self.decode(data)
  }

  public func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}

// `projection.sqlite` as one value (spec 04 §4.3): the database the projector
// writes and the screens read. It keeps GRDB inside CoreProjection (R6): the
// sync layer and the app hold a `ProjectionStore`, never a database handle.
import CoreCategorize
import CoreReplay
import CoreWire
import Foundation
import GRDB

public final class ProjectionStore: Sendable {
  let queue: DatabaseQueue
  /// Typed queries and observation over this projection.
  public let reader: LedgerReader
  /// The file, or nil for an in-memory projection.
  public let url: URL?

  init(queue: DatabaseQueue, url: URL?) {
    self.queue = queue
    self.url = url
    reader = LedgerReader(queue)
  }

  /// Opens (or creates) `<directory>/projection.sqlite`. The directory is the
  /// account's store directory, already prepared by `FileHygiene` (CoreStore);
  /// the caller excludes the database files from backup after the first write.
  public static func open(directory: URL) throws -> ProjectionStore {
    let url = directory.appendingPathComponent("projection.sqlite")
    return ProjectionStore(queue: try Projector.open(path: url.path), url: url)
  }

  /// An in-memory projection (tests, previews).
  public static func inMemory() throws -> ProjectionStore {
    ProjectionStore(queue: try Projector.open(path: nil), url: nil)
  }

  /// Replaces the projection with `state` plus the outbox overlay (`pending`,
  /// one inner array per pending blob, in order), in one transaction.
  public func project(
    _ state: State, pending: [[Op]], writerID: String, dictionary: MerchantDictionary, projectedAtMs: Int64
  ) throws {
    try Projector.project(
      state, pending: pending, writerID: writerID, dictionary: dictionary, projectedAtMs: projectedAtMs, into: queue)
  }
}

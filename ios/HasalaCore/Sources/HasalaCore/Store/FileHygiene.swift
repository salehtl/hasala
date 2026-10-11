// File protection and backup exclusion (spec 04 §4.1; spec 01 §11.2).
//
// `<AS>/accounts/<user_id>/` holds plaintext financial data, so the directory
// is created with `completeUntilFirstUserAuthentication` and excluded from
// iCloud and Finder backup, and both are re-asserted on every launch before the
// pools open. The database files are excluded individually as well; WAL and SHM
// appear after the first write, so `excludeDatabaseFiles` runs again then.
import Foundation

public enum FileHygiene {
  /// Creates `directory` (and parents) with the protection class, then marks
  /// it excluded from backup. Idempotent.
  public static func prepareDirectory(_ directory: URL) throws {
    let fm = FileManager.default
    #if os(iOS)
      let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
      let attrs: [FileAttributeKey: Any] = [:]
    #endif
    if !fm.fileExists(atPath: directory.path) {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attrs)
    } else if !attrs.isEmpty {
      try fm.setAttributes(attrs, ofItemAtPath: directory.path)
    }
    try exclude(directory)
  }

  /// Excludes `db` and its `-wal` / `-shm` companions that exist.
  public static func excludeDatabaseFiles(at db: URL) throws {
    for suffix in ["", "-wal", "-shm"] {
      let u = URL(fileURLWithPath: db.path + suffix)
      if FileManager.default.fileExists(atPath: u.path) { try exclude(u) }
    }
  }

  public static func exclude(_ url: URL) throws {
    var u = url
    var v = URLResourceValues()
    v.isExcludedFromBackup = true
    try u.setResourceValues(v)
  }

  /// Whether `url` is excluded from backup (tests, diagnostics).
  public static func isExcluded(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
  }
}

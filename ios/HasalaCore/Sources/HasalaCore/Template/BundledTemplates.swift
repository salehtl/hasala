// The bank templates shipped in the app bundle (spec 04 §4.6): CoreResources'
// `templates/<id>.json`, copied from server/internal/tmpl/seed by ios/tools/templates/sync.swift.
// There are no over-the-air template updates in the beta; the bundle is covered by the app's
// code signature, and each file is also checked against TemplatesManifest's SHA-256 here.
//
// A template that fails the SHA-256 check, the definition checks or the dialect gate is
// SKIPPED and reported by id and reason (content-free, for diagnostics); the others still
// load. When none load, the mailbox halts with `templates_unavailable` (spec 04 §7.11).
import CorePrimitives
import CoreResources
import Foundation

public enum BundledTemplates {
  public struct Skipped: Sendable, Equatable {
    public let id: String
    /// "missing", "sha256", "definition" or "dialect".
    public let reason: String
  }

  public struct LoadResult: Sendable {
    /// Compiled templates, in manifest order.
    public let templates: [CompiledTemplate]
    public let skipped: [Skipped]
  }

  /// Loads, verifies and compiles every bundled template.
  public static func load() -> LoadResult {
    load(entries: TemplatesManifest.entries) { file in
      CoreResources.bundle.url(forResource: file, withExtension: nil, subdirectory: "templates")
        .flatMap { try? Data(contentsOf: $0) }
    }
  }

  /// `load()` over an explicit manifest and reader (tests).
  static func load(entries: [TemplatesManifest.Entry], read: (String) -> Data?) -> LoadResult {
    var templates: [CompiledTemplate] = []
    var skipped: [Skipped] = []
    for e in entries {
      guard let data = read(e.file) else {
        skipped.append(Skipped(id: e.id, reason: "missing"))
        continue
      }
      guard Hex.encode(sha256(data)).utf8.elementsEqual(e.sha256.utf8) else {
        skipped.append(Skipped(id: e.id, reason: "sha256"))
        continue
      }
      do throws(TemplateError) {
        let t = try CompiledTemplate(json: [UInt8](data))
        guard t.definition.id.utf8.elementsEqual(e.id.utf8), t.definition.version == e.version else {
          skipped.append(Skipped(id: e.id, reason: "definition"))
          continue
        }
        templates.append(t)
      } catch .dialect {
        skipped.append(Skipped(id: e.id, reason: "dialect"))
      } catch {
        skipped.append(Skipped(id: e.id, reason: "definition"))
      }
    }
    return LoadResult(templates: templates, skipped: skipped)
  }
}

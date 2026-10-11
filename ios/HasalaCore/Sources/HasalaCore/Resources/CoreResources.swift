// CoreResources (Resources/), spec 04 §2.2. Resource-only target. Owners: WS-12 (templates/),
// WS-16 (merchant-dictionary.json, sample/), WS-14 (common-passwords-v1.txt). Holds the bundled
// data of spec 04 §4.6 and exposes Bundle.module accessors and the SHA-256 manifests.
//
// templates/ holds the bundled bank templates, copied from server/internal/tmpl/seed by
// ios/tools/templates/sync.swift, which also writes TemplatesManifest.swift (CoreTemplate's
// BundledTemplates loads and verifies them). sample/ holds only a .gitkeep until its owner fills
// it. The two single-file resources are declared in Package.swift by their owners when the files
// land (SwiftPM refuses a declared resource that does not exist).
import Foundation

/// The bundle that carries this package's resources.
public enum CoreResources {
  public static var bundle: Bundle { Bundle.module }

  /// `common-passwords-v1.txt` (spec 04 §4.6, §6.1.2): one ASCII-lowercased entry
  /// per line, read by `PasswordPolicy.Blocklist(text:)`. Empty if it is missing.
  public static func commonPasswords() -> String {
    guard let url = Bundle.module.url(forResource: "common-passwords-v1", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return text
  }
}

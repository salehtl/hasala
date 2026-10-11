// CoreResources (Resources/), spec 04 §2.2. Resource-only target. Owners: WS-12 (templates/),
// WS-16 (merchant-dictionary.json, sample/), WS-14 (common-passwords-v1.txt). Holds the bundled
// data of spec 04 §4.6 and exposes Bundle.module accessors and the SHA-256 manifests.
//
// templates/ and sample/ hold only a .gitkeep until their owners fill them. The two single-file
// resources are declared in Package.swift by their owners when the files land (SwiftPM refuses a
// declared resource that does not exist).
import Foundation

/// The bundle that carries this package's resources.
public enum CoreResources {
  public static var bundle: Bundle { Bundle.module }
}

import CoreText
import Foundation

/// The bundled faces (spec 04 §14.3): Inter 4.1 static Regular, Medium, SemiBold and
/// Bold, under the SIL Open Font License 1.1 (see LICENSES/OFL-1.1.txt and NOTICE).
/// Figures use the system's SF Pro Rounded and are not bundled.
public enum HasalaFonts {
  public static let faces = ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold"]

  /// Registers the bundled faces for this process. Call once at launch (the app and,
  /// later, the widget extension); repeated calls are harmless.
  @discardableResult
  public static func register() -> Bool {
    registration
  }

  private static let registration: Bool = {
    var ok = true
    for face in faces {
      guard let url = Bundle.module.url(forResource: face, withExtension: "ttf", subdirectory: "Fonts") else {
        ok = false
        continue
      }
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        // Already registered (a second process-wide call) is not a failure.
        let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
        if code != CTFontManagerError.alreadyRegistered.rawValue { ok = false }
      }
    }
    return ok
  }()

  /// True when every bundled face resolves by its PostScript name.
  public static var allFacesAvailable: Bool {
    faces.allSatisfy { name in
      let font = CTFontCreateWithName(name as CFString, 12, nil)
      return (CTFontCopyPostScriptName(font) as String) == name
    }
  }
}

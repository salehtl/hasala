import CoreText
import Foundation

/// The bundled face (spec 04 §14.3): Inter 4.1's variable font (InterVariable.ttf, weight
/// and optical-size axes), under the SIL Open Font License 1.1 (see LICENSES/OFL-1.1.txt
/// and NOTICE). Its named Regular, Medium, SemiBold and Bold instances are the four
/// weights. Paper sets Inter with automatic optical sizing, and Core Text does the same for
/// a font with an `opsz` axis: each size gets its own cut (the display cut from 32 pt), so
/// a title is as narrow as on the boards and keeps their line breaks. Figures use the
/// system's SF Pro Rounded and are not bundled.
public enum HasalaFonts {
  /// The font files in `Fonts/`.
  public static let files = ["InterVariable"]
  /// The PostScript names of the instances the type scale uses (`HWeight.interFace`).
  public static let faces = ["InterVariable", "InterVariable-Medium", "InterVariable-SemiBold", "InterVariable-Bold"]

  /// Registers the bundled font for this process. Call once at launch (the app and,
  /// later, the widget extension); repeated calls are harmless.
  @discardableResult
  public static func register() -> Bool {
    registration
  }

  private static let registration: Bool = {
    var ok = true
    for file in files {
      guard let url = Bundle.module.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts") else {
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

  /// True when every instance the type scale uses resolves by its PostScript name.
  public static var allFacesAvailable: Bool {
    faces.allSatisfy { name in
      let font = CTFontCreateWithName(name as CFString, 12, nil)
      return (CTFontCopyPostScriptName(font) as String) == name
    }
  }
}

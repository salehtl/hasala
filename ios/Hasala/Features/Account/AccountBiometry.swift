import HasalaDesign
import LocalAuthentication
import SwiftUI

extension EnvironmentValues {
  @Entry var hBiometry: HBiometry = .faceID
}

extension HBiometry {
  init(_ type: LABiometryType) {
    switch type {
    case .faceID: self = .faceID
    case .touchID: self = .touchID
    case .opticID: self = .opticID
    default: self = .none
    }
  }

  static func device(arguments: [String] = ProcessInfo.processInfo.arguments) -> HBiometry {
    if let i = arguments.firstIndex(of: "-HasalaBiometry"), i + 1 < arguments.count {
      switch arguments[i + 1] {
      case "touchID": return .touchID
      case "none": return .none
      default: return .faceID
      }
    }
    #if HASALA_MOCKS
      return .faceID
    #else
      let context = LAContext()
      _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
      return HBiometry(context.biometryType)
    #endif
  }

  var noun: String { name ?? "your passkey" }
}

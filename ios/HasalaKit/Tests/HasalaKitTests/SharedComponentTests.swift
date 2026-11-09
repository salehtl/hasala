import HasalaModels
import SwiftUI
import Testing

@testable import HasalaDesign

@Suite("Shared components")
@MainActor
struct SharedComponentTests {
  @Test func anAvatarPictureOnlyShowsForTheAddressItWasLoadedFor() {
    let picture = AvatarPicture(image: Image(systemName: "person"), email: "a@example.com")
    #expect(picture.shown(for: "a@example.com") != nil)
    #expect(picture.shown(for: "b@example.com") == nil)
    #expect(picture.shown(for: nil) == nil)
  }

  @Test func biometryWordingFollowsTheDevice() {
    #expect(HBiometry.faceID.signInTitle == "Sign in with Face ID")
    #expect(HBiometry.touchID.signInTitle == "Sign in with Touch ID")
    #expect(HBiometry.touchID.icon == .touchID)
    #expect(HBiometry.none.signInTitle == "Sign in with your passkey")
    #expect(HBiometry.none.confirmTitle == "Confirm with your passkey")
    for kind in HBiometry.allCases {
      #expect(!kind.signInTitle.localizedCaseInsensitiveContains("passcode"))
    }
  }

  @Test func textActionsHaveTwoTiers() {
    #expect((HType.textButton.size, HType.textButton.leading, HType.textButton.weight) == (17, 24, .semibold))
    #expect((HType.inlineLink.size, HType.inlineLink.leading, HType.inlineLink.weight) == (15, 20, .semibold))
    #expect(HInlineLinkStyle.minimumHitHeight == 44)
  }

  @Test func cardAndSectionHeadsHaveTwoTiers() {
    #expect((HType.section.size, HType.section.leading, HType.section.weight) == (22, 28, .bold))
    #expect((HType.cardTitle.size, HType.cardTitle.leading, HType.cardTitle.weight) == (17, 22, .semibold))
  }

  @Test func smallPillsReach44() {
    #expect(PillButtonStyle.Size.small.height + 2 * PillButtonStyle.Size.small.hitOutset >= 44)
    #expect(PillButtonStyle.Size.medium.hitOutset == 0)
    #expect(PillButtonStyle.Size.large.hitOutset == 0)
  }

  @Test func aPillKeepsItsIconUntilTheSpinnerTakesItsPlace() {
    let leading = PillButtonStyle.leading
    #expect(leading(.faceID, false, false) == .icon(.faceID))
    #expect(leading(.faceID, true, false) == .icon(.faceID))
    #expect(leading(.faceID, true, true) == .spinner)
    #expect(leading(.faceID, false, true) == .icon(.faceID))
  }

  @Test func aPillWithNoIconShowsOnlyTheSpinner() {
    let leading = PillButtonStyle.leading
    #expect(leading(nil, false, false) == .empty)
    #expect(leading(nil, true, false) == .empty)
    #expect(leading(nil, true, true) == .spinner)
    #expect(leading(nil, false, true) == .empty)
  }

  @Test func aDisabledOnGroupedPillCanReadAsOff() {
    #expect(PillButtonStyle.disabledFill(.onGrouped, greysWhenDisabled: false) == HColor.surfacePrimary)
    #expect(PillButtonStyle.disabledFill(.onGrouped, greysWhenDisabled: true) == HColor.appleFillsSecondary)
    #expect(PillButtonStyle.disabledFill(.primary, greysWhenDisabled: false) == HColor.appleFillsSecondary)
  }

  @Test func stepIndicatorShowsItsStepInWords() {
    #expect(StepIndicator.caption(current: 2, total: 3) == "Step 2 of 3")
  }

  @Test func mailboxChipStatesAStatus() {
    #expect(MailboxStatusChip.word(.needsSignIn) == "Sign-in ended")
    #expect(MailboxStatusChip.word(.connected) == "Connected")
  }

  @Test func discsGrowWithTextUpToHalfAgain() {
    #expect(DiscScale.factor(1) == 1)
    #expect(DiscScale.factor(0.82) == 1)
    #expect(abs(DiscScale.factor(1.25) - 1.25) < 0.0001)
    #expect(DiscScale.factor(2.4) == 1.5)
    #expect(CategoryDisc.Size.s40.side * DiscScale.factor(3) == 60)
  }

  @Test func deleteKeyOffersClearAmount() {
    #expect(KeypadKey.clearActionName(for: .delete) == "Clear amount")
    #expect(KeypadKey.clearActionName(for: .digit(4)) == nil)
    #expect(KeypadKey.clearActionName(for: .decimal) == nil)
  }

  @Test func contrastEdgeFollowsIncreaseContrast() {
    #expect(HContrastEdge.isShown(contrast: .increased, forced: false))
    #expect(!HContrastEdge.isShown(contrast: .standard, forced: false))
    #expect(HContrastEdge.isShown(contrast: .standard, forced: true))
    #expect(HContrastEdge.color == HColor.borderControl)
    #expect(HContrastEdge.width == 1)
  }

  @Test func chipDrawsAnEdgeUnderIncreaseContrast() throws {
    func chip(_ increased: Bool) -> some View {
      FilterChip("Dining", selected: false) {}
        .padding(10)
        .background(Color.white)
        .environment(\.hIncreasedContrast, increased)
    }
    #expect(!(try edgeFound(chip(false), x: 30, y: 10)))
    #expect(try edgeFound(chip(true), x: 30, y: 10))
  }

  @Test func trackDrawsAnEdgeUnderIncreaseContrast() throws {
    func track(_ increased: Bool) -> some View {
      SlimProgressBar(Permille(500))
        .frame(width: 200)
        .padding(10)
        .background(Color.white)
        .environment(\.hIncreasedContrast, increased)
    }
    #expect(!(try edgeFound(track(false), x: 150, y: 10)))
    #expect(try edgeFound(track(true), x: 150, y: 10))
  }

  private func edgeFound(_ view: some View, x: Int, y: Int) throws -> Bool {
    let scale = 3
    let renderer = ImageRenderer(content: view)
    renderer.scale = CGFloat(scale)
    let image = try #require(renderer.cgImage)
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    for top in (y - 2) * scale...(y + 2) * scale {
      let row = height - 1 - top
      guard row >= 0, row < height else { continue }
      let i = (row * width + x * scale) * 4
      if HRGBA(bytes[i], bytes[i + 1], bytes[i + 2], 1).isNear(HPalette.borderControl) { return true }
    }
    return false
  }
}

extension HRGBA {
  func isNear(_ other: HRGBA, tolerance: Int = 24) -> Bool {
    abs(Int(red) - Int(other.red)) <= tolerance && abs(Int(green) - Int(other.green)) <= tolerance
      && abs(Int(blue) - Int(other.blue)) <= tolerance
  }
}

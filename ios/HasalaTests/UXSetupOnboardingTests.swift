import Foundation
import HasalaMocks
import SwiftUI
import Testing

@testable import Hasala

@MainActor
@Suite("Onboarding copy and pacing")
struct UXSetupOnboardingTests: AccountSuite {
  private func atMethod(_ account: MockAccountService) async -> SignupModel {
    account.delay = .zero
    let m = SignupModel(account: account)
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    return m
  }

  @Test func aPasswordAccountIsToldTheWordsShowOnlyInSetup() async {
    let m = await atMethod(MockAccountService())
    m.method = .password
    await m.continueWithMethod()
    #expect(m.wordsOnlyInSetup)
    #expect(PhraseShowView.createNote(canShowAgain: !m.wordsOnlyInSetup)
      == "After this, you can't see them again. Check every word.")
    #expect(PhraseIntroView.onlyYouHaveThem(wordsOnlyInSetup: true)
      == "We can't reset or resend them. You'll see them only during setup. Lose them and every device that can unlock Hasala, and your data is gone for good.")
    #expect(PhraseIntroView.onlyYouHaveThem(wordsOnlyInSetup: false)
      == "We can't reset or resend them. Lose them and every device that can unlock Hasala, and your data is gone for good.")
  }

  @Test func aPasskeyWithoutPRFIsToldTheWordsShowOnlyInSetup() async {
    let account = MockAccountService()
    account.passkeyPRF = false
    let m = await atMethod(account)
    m.method = .passkey
    await m.continueWithMethod()
    #expect(m.path.last == .phraseIntro)
    #expect(m.passkeyWithoutPRF)
    #expect(m.wordsOnlyInSetup)
    #expect(AccountReadyView.subtitle(capabilities: .all, passkey: true, passkeyHoldsKeys: !m.passkeyWithoutPRF)
      == "Keep the paper safe, away from this iPhone. Your words can't be shown again.")
  }

  @Test func aPasskeyWithPRFThatShowsTheWordsKeepsTheUsualNote() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    account.passkeySynced = false
    let m = await atMethod(account)
    m.method = .passkey
    await m.continueWithMethod()
    #expect(m.path.last == .phraseIntro)
    #expect(!m.wordsOnlyInSetup)
    #expect(PhraseShowView.createNote(canShowAgain: true) == "They hide again when you leave this screen.")
    #expect(AccountReadyView.subtitle(capabilities: .all, passkey: true, passkeyHoldsKeys: !m.passkeyWithoutPRF)
      == "Keep the paper safe, away from this iPhone. See the words again in Profile, with Face ID.")
  }

  @Test func theMethodScreenNoLongerPromisesTheOtherWayLater() {
    for proven in [true, false] {
      #expect(!SignInMethodView.subtitle(emailProvenByLink: proven).contains("later"))
    }
    #expect(SignInMethodView.subtitle(emailProvenByLink: false) == "Your email is verified.")
    #expect(SignInMethodView.passwordDetail.contains("your 12 words can't be shown again"))
  }

  @Test func anyTouchOrReduceMotionMakesTheStoriesHandPaced() {
    #expect(!StoriesView.handPaced(voiceOver: false, accessibilitySize: false, reduceMotion: false, handStopped: false))
    #expect(StoriesView.handPaced(voiceOver: false, accessibilitySize: false, reduceMotion: true, handStopped: false))
    #expect(StoriesView.handPaced(voiceOver: false, accessibilitySize: false, reduceMotion: false, handStopped: true))
    #expect(StoriesView.stopsAutoAdvance(.tracking))
    #expect(StoriesView.stopsAutoAdvance(.interacting))
    #expect(!StoriesView.stopsAutoAdvance(.animating))
    #expect(!StoriesView.stopsAutoAdvance(.idle))
  }

  @Test func anInviteNotFoundWaitsForAChangedCode() {
    let m = SignupModel(account: MockAccountService())
    m.inviteText = Self.code
    #expect(InviteCodeView.canContinue(m))
    m.failure = .notInvited
    #expect(!InviteCodeView.canContinue(m))
    m.inviteText = "ABCDEFGHIJKLMNOPQRSTUVWY"
    #expect(InviteCodeView.canContinue(m))
  }

  @Test func anInviteNotFoundFromALinkSaysTheLinkDidNotWork() {
    #expect(InviteCodeView.notFoundMessage(fromLink: true)
      == "This invite link didn't work. It may have been used or expired.")
    #expect(InviteCodeView.notFoundMessage(fromLink: false)
      == "We couldn't find that invite. Check each character against your email.")
    #expect(InviteCodeView.alreadyUsedDetail
      == "Each invite works once. Made an account? You don't need another.")
  }

  @Test func aPastedLinkThatIsNotAnInviteSaysSo() {
    let m = SignupModel(account: MockAccountService())
    m.usePastedInvite("https://example.com/not-an-invite")
    #expect(m.path == [.invite])
    #expect(m.pastedLinkRefused)
    #expect(InviteCodeView.notAnInviteLink
      == "Not a Hasala invite link. Enter the code from your invite email.")
    m.inviteText = "A"
    #expect(!m.pastedLinkRefused)
    m.usePastedInvite(Self.code)
    #expect(!m.pastedLinkRefused)
    #expect(CopiedInviteCard.title == "Have an invite link?")
  }

  @Test func theTermsLineAsksOnContinuing() {
    #expect(StoriesView.termsWording == "By continuing, you agree to our Terms and Privacy Policy.")
  }

  @Test func whoCanSeeWhatNamesEveryPartyInPlainWords() {
    for outlook in [true, false] {
      let lines = WhoCanSeeSheet.serverSees(outlook: outlook)
      #expect(!lines.joined().contains("keyed hash"))
      #expect(lines.contains { $0.contains("scrambled form of your password") })
      #expect(lines.contains { $0.contains("made with a secret key") && $0.contains("for a moment") })
    }
    #expect(WhoCanSeeSheet.serverSees(outlook: false).last?.hasPrefix("Your Gmail address") == true)
    #expect(WhoCanSeeSheet.serverSees(outlook: true).last?.hasPrefix("Your mailbox address") == true)
    #expect(WhoCanSeeSheet.serverCantSee.contains("texts"))
    #expect(WhoCanSeeSheet.cloudflare.contains("With Cloud suggestions on"))
    #expect(WhoCanSeeSheet.bankTextsTitle == "Bank texts, if you use them")
    #expect(WhoCanSeeSheet.bankTexts == "Read on your iPhone and sent to no one.")
    #expect(WhoCanSeeSheet.bankTextsHue == .mint)
    #expect(WhoCanSeeSheet.serverSees(outlook: true)[1] == "Your passkey's public key, or a scrambled form of your password")
    #expect(WhoCanSeeSheet.serverSees(outlook: true).last
      == "Your mailbox address for a moment when you connect and with each Gmail notice, then only a code made with a secret key")
    #expect(WhoCanSeeSheet.apple.hasPrefix("Your email for the TestFlight invite, and that you installed Hasala."))
  }

  @Test func inviteReadyOffersTheWordsNowOrFromHome() {
    #expect(InviteReadyView.nextSteps.count == 3)
    #expect(InviteReadyView.nextSteps[2] == "Save your 12 recovery words, now or from Home")
  }

  @Test func theReviewStoryArtSaysHasalaSuggests() {
    #expect(StoryArt.descriptions[3].contains("Hasala suggests Groceries next time"))
    #expect(!StoryArt.descriptions[3].contains("learns"))
  }

  @Test func incomeAsksAfterAnyDeductions() {
    #expect(IncomeStep.subtitle == "After deductions. Change it any time.")
  }

  @Test func eachSplitHandleNamesTheBucketItTradesWith() {
    let plan = StartingPlan()
    #expect(plan.handleValue(0) == "50%, Wants 30%")
    #expect(plan.handleValue(1) == "30%, Savings 20%")
    let moved = plan.moving(handle: 0, to: 55)
    #expect(moved.handleValue(0) == "55%, Wants 25%")
    #expect(moved.splitAnnouncement == "Needs 55%, wants 25%, savings 20%")
  }

  @Test func bucketSteppersTradeAsTheHandlesDo() {
    let plan = StartingPlan()
    #expect(plan.stepping(.needs, by: 5) == StartingPlan(needsPercent: 55, wantsPercent: 25, savingsPercent: 20))
    #expect(plan.stepping(.savings, by: 5) == StartingPlan(needsPercent: 50, wantsPercent: 25, savingsPercent: 25))
    #expect(plan.stepping(.wants, by: 5) == StartingPlan(needsPercent: 50, wantsPercent: 35, savingsPercent: 15))
    #expect(plan.stepping(.wants, by: -5) == StartingPlan(needsPercent: 50, wantsPercent: 25, savingsPercent: 25))
    let noSavings = StartingPlan(needsPercent: 50, wantsPercent: 50, savingsPercent: 0)
    #expect(noSavings.stepping(.wants, by: 5) == StartingPlan(needsPercent: 45, wantsPercent: 55, savingsPercent: 0))
    #expect(noSavings.stepping(.savings, by: -5) == nil)
    let allWants = StartingPlan(needsPercent: 0, wantsPercent: 100, savingsPercent: 0)
    #expect(allWants.stepping(.wants, by: 5) == nil)
    #expect(allWants.stepping(.needs, by: -5) == nil)
    let noWants = StartingPlan(needsPercent: 80, wantsPercent: 0, savingsPercent: 20)
    #expect(noWants.stepping(.needs, by: 5) == nil)
    #expect(noWants.stepping(.savings, by: 5) == nil)
    #expect(noWants.stepping(.wants, by: -5) == nil)
  }

  @Test func theStartingPlanOffersAResetOnceChanged() {
    #expect(!StartingPlan().changed)
    #expect(StartingPlan(needsPercent: 55, wantsPercent: 25, savingsPercent: 20).changed)
    #expect(PlanStep.resetTitle == "Reset to 50 / 30 / 20")
    #expect(PlanStep.subtitle(StartingPlan(needsPercent: 55, wantsPercent: 25, savingsPercent: 20))
      == "55% needs, 25% wants, 20% savings. Hasala fills in your categories.")
  }
}

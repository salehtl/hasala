import HasalaDesign
import SwiftUI

// The welcome stories (Paper row 10, the four "Welcome" boards and the "Who can see
// what" sheet) and Welcome · Join with an invite, or sign in (page 14). Privacy-first:
// every claim is one of spec 01 §14's sentences or says less than one.

struct Story: Identifiable {
  let id: Int
  let overline: String
  let title: String
  let accent: String?
  let body: String
  let symbol: String
  let caption: String
}

enum Stories {
  static let all: [Story] = [
    Story(id: 0, overline: "Welcome to Hasala", title: "Know what's left.", accent: "Keep it to yourself.",
          body: "A calm budget from your bank alert emails, worked out on your iPhone. Bills sit apart, so rent never looks like overspending.",
          symbol: "chart.bar.doc.horizontal", caption: "Encrypted on your iPhone"),
    Story(id: 1, overline: "On your iPhone", title: "Your bank emails do the typing.", accent: nil,
          body: "Hasala reads the alerts your bank already sends, right here on your iPhone, and turns them into a live budget. No bank logins.",
          symbol: "envelope.badge", caption: "Read on this iPhone"),
    Story(id: 2, overline: "Private by design", title: "Your phone holds the key.", accent: nil,
          body: "Hasala reads your bank alerts on this iPhone and encrypts every transaction here before it's synced. Our server stores your transactions only in a form it has no key to open.",
          symbol: "lock.shield", caption: "How our server stores it: sealed"),
    Story(id: 3, overline: "Review", title: "Sort a week in a minute.", accent: nil,
          body: "Swipe new transactions into Needs, Wants or Savings. Hasala learns each merchant on your iPhone and sorts it for you next time.",
          symbol: "hand.draw", caption: "Always Groceries for Lulu"),
  ]
}

struct StoriesView: View {
  var onGetStarted: () -> Void
  var onSignIn: () -> Void
  /// The pager's page: the onboarding store's, so it stays when the person comes back.
  @Binding var page: Int
  @State private var showingWhoSees = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        ForEach(Stories.all) { s in
          Capsule()
            .fill(s.id <= page ? HColor.textPrimary : HColor.appleFillsSecondary)
            .frame(height: 3)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .frame(minHeight: 44, alignment: .top)
      .contentShape(Rectangle())
      .accessibilityElement()
      .accessibilityLabel("Story \(page + 1) of \(Stories.all.count)")
      HStack(spacing: 8) {
        Image("HasalaMark")
          .resizable().scaledToFit()
          .frame(width: 32, height: 32)
          .accessibilityHidden(true)
        Text("Hasala").hType(.headline).foregroundStyle(HColor.textPrimary)
        Text("Welcome").hType(.body).foregroundStyle(HColor.textSecondary)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)

      TabView(selection: $page) {
        ForEach(Stories.all) { story in
          StoryPage(story: story, onWhoSees: story.id == 2 ? { showingWhoSees = true } : nil)
            .tag(story.id)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      .accessibilityIdentifier("stories.pager")

      VStack(spacing: 12) {
        Button("Get started", action: onGetStarted)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("stories.getStarted")
        Button("I already have an account", action: onSignIn)
          .buttonStyle(.pill(.tertiary, fill: true))
          .accessibilityIdentifier("stories.signIn")
        LockNote(text: "Read-only Gmail · Encrypted on your iPhone")
          .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 8)
    }
    .background(alignment: .top) {
      LinearGradient(colors: [HColor.washMorning, HColor.surfaceSecondary], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
    .background(HColor.surfaceSecondary)
    .toolbar(.hidden, for: .navigationBar)
    .sheet(isPresented: $showingWhoSees) { WhoCanSeeSheet() }
  }
}

private struct StoryPage: View {
  let story: Story
  var onWhoSees: (() -> Void)?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        illustration
          .frame(maxWidth: .infinity)
          .frame(height: 260)
        Text(story.overline)
          .hType(.overline)
          .foregroundStyle(HColor.blue950)
          .padding(.top, 16)
        Group {
          if let accent = story.accent {
            Text("\(Text(story.title).foregroundStyle(HColor.textPrimary))\n\(Text(accent).foregroundStyle(HColor.actionAccent))")
          } else {
            Text(story.title).foregroundStyle(HColor.textPrimary)
          }
        }
        .hType(.largeTitle)
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
        Text(story.body)
          .hType(.body)
          .foregroundStyle(HColor.textOnWashSecondary)
          .padding(.top, 8)
          .fixedSize(horizontal: false, vertical: true)
        if let onWhoSees {
          Button(action: onWhoSees) {
            Label("Who can see what", systemImage: "chevron.right")
              .labelStyle(TrailingIconLabel())
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .hType(.rowTitle)
          .foregroundStyle(HColor.textLink)
          .padding(.top, 4)
          .accessibilityIdentifier("stories.whoSees")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private var illustration: some View {
    ZStack {
      Circle()
        .stroke(HColor.white.opacity(0.8), lineWidth: 1.5)
        .frame(width: 240, height: 240)
      VStack(spacing: 14) {
        Image(systemName: story.symbol)
          .font(.system(size: 54, weight: .regular))
          .foregroundStyle(HColor.actionAccent)
          .frame(width: 116, height: 116)
          .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
          .elevation()
        HStack(spacing: 6) {
          Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
          Text(story.caption).hType(.caption1)
        }
        .foregroundStyle(HColor.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(HColor.surfacePrimary, in: Capsule())
        .elevation()
      }
    }
    .accessibilityHidden(true)
  }
}

private struct TrailingIconLabel: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.title
      configuration.icon.font(.system(size: 12, weight: .semibold))
    }
  }
}

/// "Who can see what" (Paper sheet over the third story). The rows say what spec 01 §14
/// says (S-03, S-04, S-06, S-18), shortened, never more.
struct WhoCanSeeSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Your iPhone holds the key. Here's everyone else.")
            .hType(.title2)
            .foregroundStyle(HColor.textPrimary)
          VStack(alignment: .leading, spacing: 0) {
            party("Hasala, our server", symbol: "server.rack",
                  text: "Can see: your name and email address, that your account exists and when it was made, how and when you sign in, your passkeys' public keys, which devices you've added, how much encrypted data each device uploads and when, and your IP address.\nCan't see: your emails, amounts, merchants, categories, budget or plan.")
            Divider().padding(.leading, 56)
            party("Cloudflare", symbol: "cloud",
                  text: "Carries our traffic and sends our emails. It can see what our server sees, including the codes we email you, but not your transactions.")
            Divider().padding(.leading, 56)
            party("Google", symbol: "envelope",
                  text: "Sees your mail, as it already does, and that you gave Hasala read-only access. Hasala asks Gmail only for emails from your banks' alert addresses.")
            Divider().padding(.leading, 56)
            party("Apple", symbol: "iphone",
                  text: "Sees that you installed Hasala through TestFlight. Your passkey is saved in iCloud Keychain. Keep two-factor authentication on for your Apple Account.")
          }
          .padding(.vertical, 4)
          .listCard()
          NoteCard(systemImage: "key", title: "Keep your 12 words safe",
                   text: "Your passkey and 12-word recovery phrase are the only ways to unlock your data on a new iPhone. We can't reset them.",
                   tint: HColor.statusWarningSurface)
          WebLink(title: "Read the privacy policy", url: "https://hasala.app/privacy", identifier: "whoSees.privacy")
        }
        .padding(HSpacing.insetPage)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Who can see what")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) { dismiss() }.accessibilityIdentifier("whoSees.close")
        }
      }
    }
  }

  private func party(_ name: String, symbol: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 16) {
      IconDisc(systemImage: symbol, size: 40)
      VStack(alignment: .leading, spacing: 4) {
        Text(name).hType(.headline).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .accessibilityElement(children: .combine)
  }
}

/// Welcome · Join with an invite, or sign in (spec 04 §6.2 signup step 1).
struct JoinWelcomeView: View {
  var onJoin: () -> Void
  var onSignIn: () -> Void
  var onBack: (() -> Void)?

  var body: some View {
    GeometryReader { geo in
      ScrollView {
        content.frame(minHeight: geo.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .background(alignment: .top) {
      RadialGradient(colors: [HColor.washMorning, HColor.surfaceSecondary], center: .top, startRadius: 40,
                     endRadius: 420)
        .ignoresSafeArea()
    }
    .background(HColor.surfaceSecondary)
    // Back is the system's, with its swipe (plan decision 7); `onBack` says whether there is one.
    .accountHeader(back: onBack == nil ? .none : .system)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer(minLength: 16)
      VStack(spacing: 12) {
        Image("HasalaMark")
          .resizable().scaledToFit()
          .frame(width: 140, height: 132)
          .accessibilityHidden(true)
        Text("Hasala").hType(.title1).foregroundStyle(HColor.textPrimary)
      }
      .frame(maxWidth: .infinity)
      Spacer(minLength: 24)
      Text("Private beta · by invite")
        .hType(.overline)
        .foregroundStyle(HColor.blue950)
      Text("Know what's left. Keep it to yourself.")
        .hType(.largeTitle)
        .foregroundStyle(HColor.textPrimary)
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
      Text("Hasala reads your bank alerts on this iPhone and encrypts every transaction here before it's synced. Our server stores your transactions only in a form it has no key to open.")
        .hType(.body)
        .foregroundStyle(HColor.textOnWashSecondary)
        .padding(.top, 8)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 24)
      VStack(spacing: 12) {
        Button("Join with an invite", action: onJoin)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("welcome.join")
        Button("Sign in", action: onSignIn)
          .buttonStyle(.pill(.tertiary, fill: true))
          .accessibilityIdentifier("welcome.signIn")
        WebLink(title: "No invite yet? Join the waitlist", url: "https://hasala.app", identifier: "welcome.waitlist")
        VStack(spacing: 0) {
          Text("By continuing you agree to the")
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
          HStack(spacing: 4) {
            legalLink("Terms", "https://hasala.app/terms")
            Text("and").hType(.footnote).foregroundStyle(HColor.textSecondary)
            legalLink("Privacy Policy", "https://hasala.app/privacy")
          }
        }
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.bottom, 8)
  }

  private func legalLink(_ title: String, _ url: String) -> some View {
    Link(destination: URL(string: url)!) {
      Text(title)
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.textSecondary)
        .underline()
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
  }
}

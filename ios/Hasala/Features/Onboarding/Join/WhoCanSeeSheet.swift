import HasalaDesign
import HasalaModels
import SwiftUI

/// "Who can see what" (Paper "Welcome · Story 3 · Who can see what (sheet)", spec 04 §7): a
/// large sheet that lists everyone who can see anything, and what. Opened from story 3's
/// link and from "What Hasala reads, and what it doesn't" on "Your account is ready".
///
/// Every line says what the privacy policy says, or less: Paper's first row leaves out the
/// name and its Cloudflare row the emails we send, which our server and Cloudflare do see, so
/// both are added (`docs/legal/privacy.md`). The mail row names only providers this build can
/// connect: "Google" alone until Outlook is connectable (plan B4.6 rule 4).
struct WhoCanSeeSheet: View {
  /// Outlook can be connected in this build, so Microsoft sees mail too.
  var outlook: Bool

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text("Your iPhone holds the key. Here's everyone else.")
            .hType(HType(size: 22, leading: 28, weight: .bold, tracking: -0.35, textStyle: .title2))
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
          parties
          keyNotice
          privacyLink
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 6)
        .padding(.bottom, 34)
      }
      .scrollBounceBehavior(.basedOnSize)
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Who can see what")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) { dismiss() }
            // Paper's close glyph is the glass's vibrant ink, not the accent.
            .tint(HColor.textPrimary)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("whoSees.close")
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationBackground(HColor.sheetSurfaceLarge)
    .accessibilityIdentifier("whoSees.sheet")
  }

  // MARK: Parties

  private var parties: some View {
    VStack(spacing: 0) {
      // Paper EW0-0: this row's column sets its title and both lists 8 apart.
      PartyRow(tile: AnyView(AppIconTile(size: 36, radius: 10)), title: "Hasala, our server", top: 14, titleGap: 8) {
        VStack(alignment: .leading, spacing: 8) {
          section("Can see", color: HColor.textSecondary) {
            VStack(alignment: .leading, spacing: 4) {
              bullet("Your email address and name, and that your account exists")
              bullet("Your passkey's public key")
              bullet("When you sync, and how much sealed data you store")
              bullet("Your devices' push tokens")
              bullet("A keyed hash of your mailbox address and when new mail arrives, so it can wake your iPhone")
            }
          }
          section("Can't see", color: HColor.statusSuccessForeground) {
            line("Your emails, amounts, merchants, categories, budget or plan")
          }
        }
      }
      divider
      PartyRow(tile: tile(.other, .cloud), title: "Cloudflare") {
        line("Our network provider, which also sends our emails. Sees request details, like IP addresses and times, the emails we send you, and the sealed data passing through. It can't open it.")
      }
      divider
      PartyRow(tile: tile(.sky, .envelope), title: outlook ? "Google or Microsoft" : "Google") {
        line(outlook
          ? "Sees your mail, as it already does, and that you gave Hasala read-only access. Nothing Hasala works out goes back to them."
          : "Sees your mail, as it already does, and that you gave Hasala read-only access. Nothing Hasala works out goes back to Google.")
      }
      divider
      PartyRow(tile: tile(.other, .globe), title: "Gravatar") {
        line("Your iPhone asks it for your picture with a code made from your email address. It sees that request and your IP address. No picture means your initials.")
      }
      divider
      PartyRow(tile: tile(.lilac, .phone), title: "Apple") {
        line("Sees that you installed Hasala through TestFlight. Your passkey syncs in iCloud Keychain, end-to-end encrypted by Apple.")
      }
    }
    .padding(.vertical, 4)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }

  private var divider: some View {
    Rectangle().fill(HColor.borderSubtle).frame(height: 1).padding(.leading, 64)
  }

  private func tile(_ hue: Hue, _ icon: HIcon) -> AnyView {
    AnyView(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(hue.perceptualGradient)
        .overlay { HIconView(icon, size: 20, color: hue.ink) }
        .frame(width: 36, height: 36))
  }

  private func section<Content: View>(_ label: String, color: Color, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        // Scales with footnote: caption 2 stops growing early at the accessibility sizes.
        .hType(HType(size: 11, leading: 16, weight: .semibold, trackingEm: 0.06, uppercase: true, textStyle: .footnote))
        .foregroundStyle(color)
      content()
    }
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(HColor.neutral400).frame(width: 4, height: 4).frame(width: 4).frame(height: bulletLane)
      line(text)
    }
  }

  @ScaledMetric(relativeTo: .subheadline) private var bulletLane: CGFloat = 20

  private func line(_ text: String) -> some View {
    Text(text)
      .hType(HType(size: 14, leading: 20, weight: .regular, textStyle: .subheadline))
      .foregroundStyle(HColor.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Key notice and link

  private var keyNotice: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(LinearGradient(colors: [Color(HRGBA(0xF9, 0xDC, 0x94, 1)), Color(HRGBA(0xEB, 0xB0, 0x4A, 1))],
                             startPoint: .top, endPoint: .bottom))
        .frame(width: 36, height: 36)
        .background(Circle().fill(Color(HRGBA(0xC9, 0x8A, 0x1E, 1))).offset(y: 2))
        .overlay { HIconView(.key, size: 18, color: HColor.amber800, strokeWidth: 2.4) }
        .padding(.bottom, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Only you can unlock it")
          .hType(.rowTitle)
          .foregroundStyle(HColor.amber950)
        Text("Your passkey and 12-word recovery phrase are the only ways in on a new iPhone. We can't reset them.")
          .hType(HType(size: 14, leading: 20, weight: .regular, textStyle: .subheadline))
          .foregroundStyle(HColor.amber950)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(
      .linearGradient(
        Gradient(colors: [Color(HRGBA(0xFF, 0xF6, 0xE2, 1)), Color(HRGBA(0xFB, 0xE9, 0xC4, 1))])
          .colorSpace(.perceptual),
        startPoint: .top, endPoint: .bottom),
      in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var privacyLink: some View {
    Link(destination: URL(string: "https://hasala.app/privacy")!) {
      HStack(spacing: 4) {
        Text("Read the privacy policy")
          .hType(.subheadline.weight(.semibold))
        HIconView(.chevronRight, size: 14, color: HColor.textLink, strokeWidth: 2.4)
      }
      .foregroundStyle(HColor.textLink)
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
    }
    .padding(.horizontal, 4)
    .accessibilityIdentifier("whoSees.privacy")
  }
}

/// One party: a 36 tile, a 16/22 title and what it sees (Paper ListRow, 64 divider inset).
/// The title sits 2 over a one-line answer, 8 over the server's "Can see" lists.
private struct PartyRow<Content: View>: View {
  let tile: AnyView
  let title: String
  var top: CGFloat = 12
  var titleGap: CGFloat = 2
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      tile.accessibilityHidden(true)
      VStack(alignment: .leading, spacing: titleGap) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, top)
    .accessibilityElement(children: .combine)
  }
}

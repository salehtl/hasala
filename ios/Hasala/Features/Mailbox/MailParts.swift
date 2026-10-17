import HasalaDesign
import HasalaModels
import SwiftUI

// The parts the mailbox screens share (Paper P2.9 "Connect your email", P1 "Profile · Bank
// alerts"; spec 06 §3): the Gmail-to-this-iPhone strip, the "Hasala reads / Never" card, the
// reasons card of the two errors, the text link rows, the accent action row and the bank
// row. The kit's `MailboxRow`, `ProviderRow`, `ProviderButton` and `ProviderMark` do the rest.

// MARK: - Copy

enum MailCopy {
  /// "Emirates NBD and DIB": the banks as the read-only card and the scan name them.
  static func banks(_ banks: [SupportedBank]) -> String {
    banks.map(\.shortName).formatted(.list(type: .and))
  }

  /// The caption under the read-only card (Paper 6RN, 1MRM: "New mail note"), two lines as
  /// Paper draws it, so the screen fits above its dock and nothing sits cut off behind the
  /// provider's button. Paper's is the push sentence; a Release build relays no push, so it
  /// says how new alerts are really caught (no promise the beta doesn't keep).
  static var readNote: String {
    BuildSurface.showsUnfinished
      ? "To catch new alerts quickly, our server is told when new mail arrives, never what it says."
      : "This iPhone checks for new alerts when you open Hasala, and from time to time in the background."
  }

  /// Under the Mailboxes card (Paper 1NS8). The server's part of a new-mail wake is
  /// Debug's: a Release build relays none.
  static var mailboxesFootnote: String {
    BuildSurface.showsUnfinished
      ? "Read on this iPhone, read-only. Only alerts from your banks are downloaded. Our server sees a keyed hash of each address and when new mail arrives, never the mail."
      : "Read on this iPhone, read-only. Only alerts from your banks are downloaded. Our server sees a keyed hash of each address, never the mail."
  }

  /// The toast after a new sign-in to a mailbox whose provider ended access (Paper flow:
  /// "Connected again · Checks again from the last check").
  static func signedInAgain(_ provider: MailProviderKind) -> String {
    "\(provider.appName) connected again. Catching up from the last check."
  }

  /// The toast after a new mailbox (Paper 1NYL).
  static func added(_ provider: MailProviderKind) -> String {
    "\(provider.appName) connected. Checking for alerts."
  }

  /// Where to take Hasala's permission away on the provider's side (Paper 1O9X names
  /// Microsoft's; Google's is its permissions page).
  static func consentPage(_ provider: MailProviderKind) -> String {
    switch provider {
    case .gmail: "myaccount.google.com/permissions"
    case .outlook: "account.live.com/consent/Manage"
    }
  }

  /// The system alert before a connect replaces the account's one link (main's "Change
  /// your email?"; Paper has no board for it, so it is the disconnect alert's kind).
  static let switchTitle = "Change your email?"

  /// Its message: "This replaces your Gmail connection. Hasala reads your bank alerts from
  /// Outlook instead."
  static func switchMessage(from old: MailProviderKind, to new: MailProviderKind) -> String {
    "This replaces your \(old.appName) connection. Hasala reads your bank alerts from \(new.appName) instead. Past transactions stay."
  }

  /// The system alert before a connect takes the account's link over from another iPhone
  /// (a new install or a recovered account, while the server still names the earlier
  /// iPhone; Paper has no board for it, so it is the switch alert's kind).
  static let takeoverTitle = "Read your email on this iPhone?"

  /// Its message. The other iPhone may be one the person no longer has: the server can't
  /// tell, so the copy says both.
  static func takeoverMessage(from held: MailProviderKind, to new: MailProviderKind) -> String {
    let reads = held == new
      ? "Hasala reads it on this iPhone instead"
      : "Hasala reads your bank alerts from \(new.appName) on this iPhone instead"
    return "Your \(held.appName) is read on another iPhone, or was on one you no longer have. \(reads), and the other iPhone stops. Past transactions stay."
  }

  /// The system alert's message before a disconnect (Paper "Mailbox · Disconnect (alert)").
  /// Google's: the disconnect revokes Hasala's access at Google itself, so it says so
  /// (and where to check). Microsoft has no revoke, so its permission is removed there.
  static func disconnectMessage(_ provider: MailProviderKind) -> String {
    switch provider {
    case .gmail:
      "Hasala stops reading this mailbox, ends its access at Google and deletes its sign-in from this iPhone. Past transactions stay. To check on Google's side, visit \(consentPage(provider))."
    case .outlook:
      "Hasala stops reading this mailbox and forgets its sign-in. Past transactions stay. To remove the permission on \(provider.company)'s side too, visit \(consentPage(provider))."
    }
  }
}

// MARK: - The success moment

/// A mailbox connected, or read again after a new sign-in, on a screen that goes as it
/// ends (`ConnectMailPage`: Add a mailbox's provider screen, the Profile card's "Connect
/// your email" or "Sign in again"). Bank alerts takes it once it shows, whether it was
/// under that screen or is made new in its place, and plays the motion policy's success:
/// the new row lands with the haptic, or the haptic plays for the mailbox read again.
/// One at a time, for the process, like `MailLaunch`'s Debug taps.
enum MailboxMoment: Equatable {
  case added(mailboxID: String)
  case signedInAgain(mailboxID: String)

  /// The moment no Bank alerts has shown yet.
  private(set) static var pending: MailboxMoment?

  static func hand(_ moment: MailboxMoment) {
    pending = moment
  }

  /// The pending moment, once.
  static func take() -> MailboxMoment? {
    defer { pending = nil }
    return pending
  }

  /// The mailbox a pending `added` lands (Bank alerts holds its row back from the first frame).
  static var pendingAddition: String? {
    if case .added(let id)? = pending { return id }
    return nil
  }
}

extension MotionPolicy {
  /// How long `kind` takes to come to rest under this policy (none when it shows at once),
  /// so the success haptic plays as the motion settles, never as it starts (motion policy).
  func settleDelay(_ kind: HMotion.Kind) -> Duration {
    .seconds(curve(kind)?.nominalDuration ?? 0)
  }
}

// MARK: - Glyphs Paper draws that the icon set doesn't hold

/// A 24-grid glyph from a Paper board, drawn from its path data: the hero's check and "!",
/// the link of "How Hasala reads your email", the action row's plus.
struct PaperGlyph: View {
  struct Part {
    let d: String
    var fill = false
  }

  /// Bank alerts' working hero: `M5.5 12.5l4.2 4.2 8.8-9.2`.
  static let check = [Part(d: "M5.5 12.5l4.2 4.2 8.8-9.2")]
  /// The "needs you" hero: a bar and a dot.
  static let alert = [Part(d: "M12 7.5v5.5"), Part(d: "M13.4 17a1.4 1.4 0 1 1-2.8 0a1.4 1.4 0 1 1 2.8 0Z", fill: true)]
  /// The not-connected hero: Paper's envelope.
  static let envelope = [
    Part(d: "M5.5 5.5h13a2.5 2.5 0 0 1 2.5 2.5v8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 16V8a2.5 2.5 0 0 1 2.5-2.5Z"),
    Part(d: "m3.8 7 8.2 6 8.2-6"),
  ]
  static let link = [
    Part(d: "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1.2 1.2"),
    Part(d: "M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1.2-1.2"),
  ]
  static let eyeOff = [
    Part(d: "M3.5 3.5l17 17"),
    Part(d: "M10.4 5.1A9.6 9.6 0 0 1 12 5c5 0 8.4 4.1 9.4 7-.4 1.1-1.2 2.4-2.3 3.6M6.7 6.7C4.7 8 3.2 9.9 2.6 12c1 2.9 4.4 7 9.4 7 1.8 0 3.4-.5 4.8-1.3"),
    Part(d: "M9.9 9.9a3 3 0 0 0 4.2 4.2"),
  ]
  static let plus = [Part(d: "M12 5v14M5 12h14")]
  /// The read-only card's tick and dash (12 in a 20 badge).
  static let tick = [Part(d: "m5 12.5 4.5 4.5L19 7.5")]
  static let dash = [Part(d: "M6 12h12")]

  let parts: [Part]
  let size: CGFloat
  let color: Color
  /// In grid units.
  let lineWidth: CGFloat

  init(_ parts: [Part], size: CGFloat, color: Color, lineWidth: CGFloat) {
    self.parts = parts
    self.size = size
    self.color = color
    self.lineWidth = lineWidth
  }

  var body: some View {
    Canvas { context, canvas in
      let box = CGRect(origin: .zero, size: canvas)
      let unit = min(canvas.width, canvas.height) / 24
      for part in parts {
        guard let svg = try? SVGPath(parsing: part.d) else { continue }
        let path = svg.path(in: box)
        if part.fill {
          context.fill(path, with: .color(color))
        } else {
          context.stroke(path, with: .color(color),
                         style: StrokeStyle(lineWidth: lineWidth * unit, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

// MARK: - The read-only screen's parts

/// "Gmail → This iPhone" (Paper "Flow · Gmail to this iPhone"): where the alerts come from
/// and where they're read, two chips and a dotted arrow.
struct FlowStrip: View {
  let provider: MailProviderKind
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: 0))
    layout {
      chip(title: provider.appName, detail: "Read-only", lifted: false) {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Hue.sky.perceptualGradient)
          .frame(width: 36, height: 36)
          .overlay { HIconView(.envelope, size: 20, color: Hue.sky.ink, strokeWidth: 1.9) }
      }
      arrow
      chip(title: "This iPhone", detail: "Reads and sorts", lifted: true) {
        // P1's tile (Paper "Slot mark · tile"), the one the join screens draw.
        AppIconTile(size: 36, radius: 10)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("From \(provider.appName), read-only, to this iPhone, which reads and sorts")
  }

  private var arrow: some View {
    Canvas { context, _ in
      var dots = Path()
      dots.move(to: CGPoint(x: 2, y: 6))
      dots.addLine(to: CGPoint(x: 23, y: 6))
      context.stroke(dots, with: .color(HColor.blue400),
                     style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0, 5]))
      var head = Path()
      head.move(to: CGPoint(x: 22, y: 2))
      head.addLine(to: CGPoint(x: 27, y: 6))
      head.addLine(to: CGPoint(x: 22, y: 10))
      context.stroke(head, with: .color(HColor.blue600),
                     style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }
    .frame(width: 30, height: 12)
    .frame(width: 36)
    .rotationEffect(typeSize.isAccessibilitySize ? .degrees(90) : .zero)
    .padding(.leading, typeSize.isAccessibilitySize ? 16 : 0)
  }

  private func chip(title: String, detail: String, lifted: Bool, @ViewBuilder tile: () -> some View) -> some View {
    HStack(spacing: 8) {
      tile()
      VStack(alignment: .leading, spacing: 0) {
        Text(title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        Text(detail).hType(HType(size: 12, leading: 16, weight: .regular, textStyle: .caption))
          .foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .padding(.leading, 8)
    .padding(.trailing, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: Color(HRGBA(0, 0, 0, 0.04)), radius: 1, x: 0, y: 1)
    .shadow(color: lifted ? Color(HRGBA(30, 42, 94, 0.08)) : .clear, radius: 10, x: 0, y: 8)
  }
}

/// "Hasala reads / Never" (Paper "What is and isn't read"): the banks picked and the iPhone
/// on one side, the rest of the inbox, sending and the server on the other.
struct ReadsNeverCard: View {
  let banks: [SupportedBank]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Hasala reads").hType(.overline).foregroundStyle(HColor.statusSuccessForeground)
          .accessibilityAddTraits(.isHeader)
        item("Alerts from \(MailCopy.banks(banks)), and nothing else", reads: true)
        item("Downloaded and read here, on this iPhone", reads: true)
      }
      HColor.borderSubtle.frame(height: 1).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text("Never").hType(.overline).foregroundStyle(HColor.textSecondary)
          .accessibilityAddTraits(.isHeader)
        item("The rest of your inbox. It's never downloaded.", reads: false)
        item("Sending, deleting or changing your email", reads: false)
        item("Passing your emails to our server or an AI service", reads: false)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }

  private func item(_ text: String, reads: Bool) -> some View {
    // Paper's gap is 10, but Inter on iOS sets "Downloaded and read here, on this iPhone"
    // 0.6 pt wider than the 300 that leaves on a 402 screen: 9 keeps Paper's line breaks
    // (and the screen 20 pt shorter, so its caption isn't left under the dock).
    HStack(alignment: .top, spacing: 9) {
      Circle()
        .fill(reads ? HColor.statusSuccessSurface : HColor.surfaceSecondary)
        .frame(width: 20, height: 20)
        .overlay {
          PaperGlyph(reads ? PaperGlyph.tick : PaperGlyph.dash, size: 12,
                     color: reads ? HColor.statusSuccessForeground : HColor.textSecondary, lineWidth: 3)
        }
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

/// A sentence and its link in one wrapping row (Paper "TextLinkRow"): "Not your email?
/// Choose a different one." One button; VoiceOver reads both parts. While what it started
/// runs (`busy`), a spinner holds its place and further taps do nothing.
struct TextLinkRow: View {
  var lead: String?
  var link: String
  var identifier: String
  var busy = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      TextLinkLabel(lead: lead, link: link)
        .opacity(busy ? 0 : 1)
        .overlay { if busy { Spinner(size: 20) } }
    }
    .buttonStyle(.plain)
    .disabled(busy)
    .accessibilityLabel([lead, link].compactMap { $0 }.joined(separator: " "))
    .accessibilityValue(busy ? "In progress" : "")
    .accessibilityIdentifier(identifier)
  }
}

/// "Use a different email? Tell us which." (Paper, Choose your email): a mail to support
/// naming the provider Hasala doesn't read yet. A person reads it; nothing is sent from the
/// app.
struct TellUsWhichLink: View {
  /// The chooser's footnote: the whole sentence in link blue, 13/18 semibold, from the
  /// leading edge (Paper 1MZG, 1NW2). Otherwise the dock's text link row, 15/20, centred.
  var small = false
  var leading = false
  /// The small link's text height, so its 44 pt target can overhang it (see `body`).
  @State private var textHeight: CGFloat = 0

  static let mail: URL = {
    var parts = URLComponents()
    parts.scheme = "mailto"
    parts.path = BuildSurface.supportEmail
    parts.queryItems = [URLQueryItem(name: "subject", value: "Another email for my bank alerts")]
    return parts.url ?? BuildSurface.supportMail
  }()

  var body: some View {
    Link(destination: Self.mail) {
      if small {
        Text("Use a different email? Tell us which.")
          .hType(HType.footnote.weight(.semibold))
          .foregroundStyle(HColor.textLink)
          .multilineTextAlignment(leading ? .leading : .center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
      } else {
        TextLinkLabel(lead: "Use a different email?", link: "Tell us which.", leading: leading)
      }
    }
    .accessibilityLabel("Use a different email? Tell us which.")
    .accessibilityAddTraits(.isLink)
    .accessibilityIdentifier("mail.choose.other")
    // The chooser's footnote sits 6 above the link (Paper 1N2A): the 44 pt target
    // overhangs the text above and below instead of pushing it 13 pt down.
    .padding(.vertical, small && textHeight > 0 ? -max(0, HSpacing.targetMinimum - textHeight) / 2 : 0)
  }
}

/// The sentence and its link as one text of two runs, so it grows with Dynamic Type and
/// wraps as one sentence at every size (two texts side by side, or a fit switch between
/// layouts, left the accessibility audit reading text that stops growing). Paper's row
/// wraps the link as a whole ("flex-wrap"): up to the large sizes its words are held
/// together, so it moves to the next line in one piece, as on 1MRM; at the accessibility
/// sizes it wraps word by word, as its words may not fit one line.
private struct TextLinkLabel: View {
  let lead: String?
  let link: String
  var leading = false
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.legibilityWeight) private var legibilityWeight

  var body: some View {
    Self.text(lead: lead, link: link, wholeLink: !typeSize.isAccessibilitySize, boldText: legibilityWeight == .bold)
      .hType(.subheadline)
      .foregroundStyle(HColor.textSecondary)
      .multilineTextAlignment(leading ? .leading : .center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum, alignment: leading ? .leading : .center)
      .contentShape(Rectangle())
  }

  /// The lead in the secondary colour (the type the view sets), then the link at 600 in
  /// link blue (a weight up under Bold Text, as `hType` steps its own faces).
  static func text(lead: String?, link: String, wholeLink: Bool, boldText: Bool) -> Text {
    let weight: HWeight = boldText ? HWeight.semibold.bolder : .semibold
    let words = wholeLink ? link.replacingOccurrences(of: " ", with: "\u{00A0}") : link
    let run = Text(words).font(HType.subheadline.weight(weight).font).foregroundStyle(HColor.textLink)
    guard let lead else { return run }
    return Text("\(lead) \(run)")
  }
}

extension View {
  /// A pill in an account screen's dock takes the height its label needs at every text
  /// size. The dock doesn't scroll, so a label offered less height than it needs could be
  /// cut short at the larger sizes (the accessibility audit's "Text clipped" at AX3, where
  /// "Continue with Microsoft" takes two lines).
  func dockPill() -> some View { fixedSize(horizontal: false, vertical: true) }
}

// MARK: - The errors' card

/// "What you can do" / "Common reasons" (Paper 1MUP, 1NQF): numbered or "?" badges, a title
/// and a line each.
struct MailReasonsCard: View {
  struct Item: Hashable {
    let title: String
    let detail: String
  }

  let title: String
  let items: [Item]
  /// "1", "2"… or "?" on every badge.
  let numbered: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .hType(HType(size: 13, leading: 18, weight: .bold, trackingEm: 0.06, uppercase: true, textStyle: .footnote))
        .foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(items.enumerated()), id: \.element) { i, item in
        HStack(alignment: .top, spacing: 12) {
          Circle().fill(HColor.statusInfoSurface).frame(width: 24, height: 24)
            .overlay {
              Text(numbered ? "\(i + 1)" : "?")
                .font(.custom(HWeight.bold.interFace, size: 13))
                .foregroundStyle(HColor.statusInfoForeground)
            }
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            Text(item.detail).hType(HType(size: 14, leading: 20, weight: .regular, textStyle: .subheadline))
              .foregroundStyle(HColor.textSecondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

// MARK: - Bank alerts' rows

/// An accent action row at the end of a card (Paper "Add a mailbox", "Add a bank"): a 40
/// accent tile with a plus, the label in link blue.
struct MailActionRow: View {
  let title: String
  let identifier: String
  /// Add a mailbox's plus, or the envelope for "Use another email".
  var glyph = PaperGlyph.plus
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: HSpacing.listRowGap) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(HColor.actionAccentSubtle)
          .frame(width: 40, height: 40)
          .overlay { PaperGlyph(glyph, size: 18, color: HColor.textLink, lineWidth: 2.4) }
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textLink)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, HSpacing.listRowInsetInline)
      .padding(.vertical, 8)
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityIdentifier(identifier)
  }
}

/// A bank whose alerts are read (Paper "BankRow"): its plate, its name, where its alerts
/// come from, and a green tick.
struct BankAlertsBankRow: View {
  let bank: SupportedBank
  let detail: String

  var body: some View {
    ReflowingRow(spacing: HSpacing.listRowGap) {
      HStack(spacing: HSpacing.listRowGap) {
        BankPlate(initials: bank.monogram, hue: bank == .enbd ? .sky : .sand)
        VStack(alignment: .leading, spacing: 2) {
          Text(bank.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          Text(detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    } trailing: {
      Circle().fill(HColor.statusSuccessSurface).frame(width: 24, height: 24)
        .overlay { PaperGlyph(PaperGlyph.check, size: 14, color: HColor.statusSuccessForeground, lineWidth: 3) }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(bank.name), \(detail)")
    .accessibilityValue("Read")
  }
}

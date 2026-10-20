import HasalaDesign
import HasalaModels
import SwiftUI

struct RequestBankSheet: View {
  let setup: SetupAuthoring?
  let prober: OtherBankProbing?
  var onSent: (String) -> Void = { _ in }

  @State private var snapshot: BankRequestsSnapshot = .offline
  @State private var typed = ""
  @State private var busy: String?
  @State private var probe: OtherBankProbe?
  @State private var probing = false
  @State private var failure: SetupFailure?
  @Environment(\.dismiss) private var dismiss

  private func requested(_ slug: String) -> Bool { snapshot.requests.contains { $0.bank == slug } }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("Hasala reads only the banks it lists. Tell us yours and we'll show you here, and email you, when it works. We send only the bank's name.")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
          if let prober { lookInMail(prober) }
          catalogSection
          typedSection
          if !snapshot.requests.isEmpty { RequestedBanksCard(requests: snapshot.requests) }
          if let message = failure?.message { FailureBanner(failure: .badPhrase(message)) }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Ask for your bank")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("requestBank.done")
        }
      }
      .task { await load() }
    }
  }

  @ViewBuilder private var catalogSection: some View {
    let banks = snapshot.askable
    if !banks.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Banks people ask for")
        HListCard {
          ForEach(Array(banks.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            AskBankRow(
              name: bank.name, detail: requested(bank.slug) ? bank.state.detail(knownToThisBuild: false) : nil,
              asked: requested(bank.slug), busy: busy == bank.slug, identifier: "requestBank.bank.\(bank.slug)"
            ) { Task { await ask(slug: bank.slug, name: bank.name, domain: nil) } }
          }
        }
      }
    }
  }

  private var typedSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Another bank")
      HStack(spacing: 12) {
        TextField("Bank name", text: $typed)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
          .submitLabel(.send)
          .onSubmit { Task { await askTyped() } }
          .accessibilityIdentifier("requestBank.name")
        Button("Send") { Task { await askTyped() } }
          .buttonStyle(.pill(.secondary, size: .small, loading: busy == "other"))
          .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy != nil || setup == nil)
          .accessibilityIdentifier("requestBank.send")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(minHeight: 56)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    }
  }

  @ViewBuilder private func lookInMail(_ prober: OtherBankProbing) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Look in your mail")
      VStack(alignment: .leading, spacing: 12) {
        Text(lookNote)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if case .found(let hints) = probe, !hints.isEmpty {
          ForEach(hints) { hint in
            AskBankRow(
              name: hint.candidate.name,
              detail: requested(hint.candidate.slug) ? "Requested" : "Email from \(hint.domain). Ask sends the bank and \(hint.domain).",
              asked: requested(hint.candidate.slug), busy: busy == hint.candidate.slug,
              identifier: "requestBank.hint.\(hint.candidate.slug)"
            ) { Task { await ask(slug: hint.candidate.slug, name: hint.candidate.name, domain: hint.domain) } }
          }
        } else {
          Button("Look in my mail") { Task { await look(prober) } }
            .buttonStyle(.pill(.secondary, size: .small, loading: probing))
            .disabled(probing)
            .accessibilityIdentifier("requestBank.look")
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    }
  }

  private var lookNote: String {
    switch probe {
    case nil:
      "Your iPhone can check whether your mail has emails from the banks Hasala is adding. It doesn't open them, and nothing is sent unless you tap Ask."
    case .found(let hints) where hints.isEmpty: "No emails from those banks in the last 6 months."
    case .found: "Found on this iPhone. Nothing has been sent."
    case .notReading: "Connect your email first."
    case .signInAgain: "Sign in to your email again first."
    case .offline: "Couldn't check your mail just now. Try again later."
    }
  }

  private func load() async {
    guard let setup else { return }
    if let s = try? await setup.bankRequests() { snapshot = s }
  }

  private func look(_ prober: OtherBankProbing) async {
    probing = true
    defer { probing = false }
    let wanted = BankCandidate.all.filter { c in snapshot.askable.contains { $0.slug == c.slug } }
    probe = await prober.probeOtherBanks(wanted.isEmpty ? BankCandidate.all : wanted)
  }

  private func askTyped() async {
    let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let setup, busy == nil else { return }
    busy = "other"
    defer { busy = nil }
    do {
      try await setup.requestBank(String(name.prefix(64)))
      typed = ""
      failure = nil
      await load()
      onSent(name)
    } catch {
      failure = error
    }
  }

  private func ask(slug: String, name: String, domain: String?) async {
    guard let setup, busy == nil else { return }
    busy = slug
    defer { busy = nil }
    do {
      try await setup.requestBank(slug: slug, senderDomain: domain)
      failure = nil
      await load()
      if !requested(slug) {
        snapshot.requests.append(RequestedBank(bank: slug, name: name, state: .requested))
      }
      onSent(name)
    } catch {
      failure = error
    }
  }
}

private struct AskBankRow: View {
  let name: String
  let detail: String?
  let asked: Bool
  let busy: Bool
  let identifier: String
  var ask: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 12) {
        BankPlate(initials: BankInitials.of(name), hue: .sand)
        VStack(alignment: .leading, spacing: 0) {
          Text(name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          if let detail { Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(detail.map { "\(name), \($0)" } ?? name)
      if asked {
        HIconView(.check, size: 16, color: HColor.statusSuccessForeground, strokeWidth: 3)
          .accessibilityLabel("Requested")
      } else {
        Button("Ask", action: ask)
          .buttonStyle(.pill(.secondary, size: .small, loading: busy))
          .accessibilityLabel("Ask for \(name)")
          .accessibilityIdentifier(identifier)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(minHeight: 56)
  }
}

struct RequestedBanksCard: View {
  let requests: [RequestedBank]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Your requests")
      HListCard {
        ForEach(Array(requests.enumerated()), id: \.element) { i, request in
          if i > 0 { HDivider(inset: .disc68) }
          HStack(spacing: 12) {
            BankPlate(initials: BankInitials.of(request.name), hue: request.state == .supported ? .mint : .sand)
            VStack(alignment: .leading, spacing: 0) {
              Text(request.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              Text(request.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .frame(minHeight: 56)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(request.name), \(request.detail)")
          .accessibilityIdentifier("requestedBank.\(request.id)")
        }
      }
    }
  }
}

enum BankInitials {
  static func of(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
    if words.count == 1 {
      let w = String(words[0])
      return w.count <= 4 && w == w.uppercased() ? w : String(w.prefix(3)).uppercased()
    }
    return String(words.prefix(3).compactMap(\.first)).uppercased()
  }
}

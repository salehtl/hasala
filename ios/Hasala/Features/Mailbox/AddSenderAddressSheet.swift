import HasalaDesign
import SwiftUI

enum SenderAddressOutcome: Equatable, Sendable {
  case added(String)
  case refused(String)
  case offline
}

@MainActor
protocol SenderAddressAdding: AnyObject {
  var unlistedSenders: [String] { get }
  func addSenderAddress(_ typed: String, for domain: String) async -> SenderAddressOutcome
}

struct AddSenderAddressSheet: View {
  let domain: String
  let adder: SenderAddressAdding
  var onAdded: (String) -> Void = { _ in }

  @State private var typed = ""
  @State private var busy = false
  @State private var failure: String?
  @Environment(\.dismiss) private var dismiss

  static func note(_ domain: String) -> String {
    "Outlook finds bank alerts only by the exact address they come from. Open an alert from \(domain) and type the address it was sent from."
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(Self.note(domain))
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
          HStack(spacing: 12) {
            TextField("alerts@\(domain)", text: $typed)
              .keyboardType(.emailAddress)
              .textContentType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.done)
              .onSubmit { Task { await add() } }
              .accessibilityLabel("Sender address")
              .accessibilityIdentifier("addSender.address")
            Button("Add") { Task { await add() } }
              .buttonStyle(.pill(.secondary, size: .small, loading: busy))
              .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
              .accessibilityIdentifier("addSender.add")
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .frame(minHeight: 56)
          .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
          if let failure {
            InlineStatus(tone: .warning, text: failure, size: .regular)
              .accessibilityIdentifier("addSender.failure")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Add a sender")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .accessibilityIdentifier("addSender.cancel")
        }
      }
    }
  }

  private func add() async {
    guard !busy, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    busy = true
    defer { busy = false }
    switch await adder.addSenderAddress(typed, for: domain) {
    case .added(let address):
      onAdded(address)
      dismiss()
    case .refused(let line):
      failure = line
    case .offline:
      failure = "You're offline. Add it when you're back online."
    }
  }
}

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

struct SenderAddressForm: Equatable {
  static let offlineLine = "You're offline. Add it when you're back online."

  var typed = "" {
    didSet { if typed != oldValue { failure = nil } }
  }
  private(set) var busy = false
  private(set) var failure: String?

  var canAdd: Bool { !busy && !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  mutating func begin() -> String? {
    guard canAdd else { return nil }
    busy = true
    failure = nil
    return typed
  }

  mutating func finish(_ outcome: SenderAddressOutcome) {
    busy = false
    switch outcome {
    case .added: failure = nil
    case .refused(let line): failure = line
    case .offline: failure = Self.offlineLine
    }
  }
}

struct AddSenderAddressSheet: View {
  let domain: String
  let adder: SenderAddressAdding
  var onAdded: (String) -> Void = { _ in }

  @State private var form = SenderAddressForm()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  private var fieldLayout: AnyLayout {
    typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(spacing: 12))
  }

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
          fieldLayout {
            TextField("alerts@\(domain)", text: $form.typed)
              .keyboardType(.emailAddress)
              .textContentType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.done)
              .onSubmit { Task { await add() } }
              .accessibilityLabel("Sender address")
              .accessibilityIdentifier("addSender.address")
            Button("Add") { Task { await add() } }
              .buttonStyle(.pill(.secondary, size: .small, loading: form.busy))
              .disabled(!form.canAdd)
              .accessibilityIdentifier("addSender.add")
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .frame(minHeight: 56)
          .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
          if let failure = form.failure {
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
    guard let address = form.begin() else { return }
    let outcome = await adder.addSenderAddress(address, for: domain)
    form.finish(outcome)
    if case .added(let added) = outcome {
      onAdded(added)
      dismiss()
    }
  }
}

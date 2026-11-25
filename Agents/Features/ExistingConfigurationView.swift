import AgentsUpdates
import SwiftUI

struct ExistingConfigurationView: View {
  let model: AppModel

  var body: some View {
    if let session = model.existingConfigurationSession {
      VStack(alignment: .leading, spacing: 12) {
        Text("Use Existing Configuration")
          .font(.headline)
          .padding(.horizontal, 16)
          .padding(.top, 16)
        Form {
          if session.stage == .preparing {
            ProgressView("Preparing configuration preview…").controlSize(.small)
          }
          if let preview = session.preview {
            Section("Configuration Contents") {
              LabeledContent("Declared sources", value: String(preview.sourceCount))
              LabeledContent("Locked skills", value: String(preview.skillCount))
              LabeledContent(
                "Managed skill installations", value: String(preview.installationCount))
              LabeledContent("Instruction sections", value: String(preview.instructionCount))
              Text(
                "Shared installation paths count once. Instruction sections include saved prompts."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Section("Configuration Files") {
              LabeledContent("Keep existing declaration") {
                PathView(
                  url: ExistingConfigurationSession.existingDeclaration(
                    in: preview.declarationURL.deletingLastPathComponent()), scope: session.scope)
              }
              LabeledContent("Create declaration") {
                PathView(url: preview.declarationURL, scope: session.scope)
              }
              LabeledContent("Update resolved state") {
                PathView(url: preview.ledgerURL, scope: session.scope)
              }
              LabeledContent("Save original resolved state") {
                PathView(url: preview.originalLedgerURL, scope: session.scope)
              }
              Text("The backup keeps the original resolved state. Existing backups are preserved.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          if session.stale && session.stage == .review {
            Label(
              "Configuration changed since this preview.",
              systemImage: "exclamationmark.triangle")
          }
          if !session.messages.isEmpty {
            Section("Unable to Use Existing Configuration") {
              ForEach(session.messages) { diagnostic in
                Text(verbatim: diagnostic.message).textSelection(.enabled)
              }
            }
          }
          Label("Native client files stay as they are.", systemImage: "lock.shield")
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)

        Divider()
        HStack {
          Button("Cancel") { model.cancelExistingConfiguration() }
            .keyboardShortcut(.cancelAction)
            .disabled(session.stage == .applying)
            .accessibilityIdentifier("existingConfiguration.cancel")
          Spacer()
          if session.stage == .applying {
            ProgressView("Applying…").controlSize(.small)
          } else if session.stage == .failed || (session.stage == .review && session.stale) {
            Button("Refresh Preview") { model.previewExistingConfiguration() }
              .disabled(model.isApplying || model.isTerminating)
          }
          Button("Apply") { model.applyExistingConfiguration() }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApplyExistingConfiguration)
            .accessibilityIdentifier("existingConfiguration.apply")
        }
        .padding([.horizontal, .bottom], 16)
      }
      .frame(width: 520, height: 520)
      .interactiveDismissDisabled(session.stage == .applying)
    }
  }
}

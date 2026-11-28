import AgentsUpdates
import SwiftUI

struct ExistingConfigurationView: View {
  let model: AppModel

  var body: some View {
    if let session = model.existingConfigurationSession {
      VStack(alignment: .leading, spacing: 12) {
        Text("Review Configuration Import")
          .font(.headline)
          .padding(.horizontal, 16)
          .padding(.top, 16)
        Form {
          if session.stage == .preparing {
            ProgressView("Reading the configuration to import…").controlSize(.small)
          }
          if let preview = session.preview {
            Section("Import Summary") {
              LabeledContent("Sources", value: String(preview.sourceCount))
              LabeledContent("Skills", value: String(preview.skillCount))
              LabeledContent(
                "Skill installations", value: String(preview.installationCount))
              LabeledContent("Instruction sections", value: String(preview.instructionCount))
            }
            Section("Files to Write") {
              LabeledContent("New YAML configuration") {
                PathView(url: preview.declarationURL, scope: session.scope)
              }
              LabeledContent("Installation lock") {
                PathView(url: preview.ledgerURL, scope: session.scope)
              }
              LabeledContent("Backup of original lock") {
                PathView(url: preview.originalLedgerURL, scope: session.scope)
              }
            }
            DisclosureGroup("Import Source") {
              PathView(
                url: ExistingConfigurationSession.existingDeclaration(
                  in: preview.declarationURL.deletingLastPathComponent()), scope: session.scope)
            }
          }
          if session.stale && session.stage == .review {
            Label(
              "Configuration changed since this preview.",
              systemImage: "exclamationmark.triangle")
          }
          if !session.messages.isEmpty {
            Section("Import Unavailable") {
              ForEach(session.messages) { diagnostic in
                Text(verbatim: diagnostic.message).textSelection(.enabled)
              }
            }
          }
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
            ProgressView("Importing…").controlSize(.small)
          } else if session.stage == .failed || (session.stage == .review && session.stale) {
            Button("Refresh Preview") { model.previewExistingConfiguration() }
              .disabled(model.isApplying || model.isTerminating)
          }
          Button("Import Configuration") { model.applyExistingConfiguration() }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApplyExistingConfiguration)
            .accessibilityIdentifier("existingConfiguration.apply")
        }
        .padding([.horizontal, .bottom], 16)
      }
      .frame(width: 520, height: session.stage == .preparing ? 185 : 520)
      .interactiveDismissDisabled(session.stage == .applying)
    }
  }
}

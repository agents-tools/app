import AgentsUpdates
import SwiftUI

struct GlobalMigrationView: View {
  let model: AppModel

  var body: some View {
    if let session = model.migrationSession {
      VStack(alignment: .leading, spacing: 12) {
        Text("Migrate User Configuration")
          .font(.headline)
          .padding(.horizontal, 16)
          .padding(.top, 16)
        Form {
          if session.stage == .preparing {
            ProgressView("Preparing migration preview…").controlSize(.small)
          }
          if let preview = session.preview {
            Section("Configuration to Carry Forward") {
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
              LabeledContent("Keep previous declaration") {
                PathView(
                  url: GlobalMigrationSession.previousDeclaration(
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
            Section("Migration Couldn’t Continue") {
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
          Button("Cancel") { model.cancelGlobalMigration() }
            .keyboardShortcut(.cancelAction)
            .disabled(session.stage == .applying)
            .accessibilityIdentifier("migration.cancel")
          Spacer()
          if session.stage == .applying {
            ProgressView("Migrating…").controlSize(.small)
          } else if session.stage == .failed || (session.stage == .review && session.stale) {
            Button("Refresh Preview") { model.previewGlobalMigration() }
              .disabled(model.isApplying || model.isTerminating)
          }
          Button("Migrate") { model.confirmGlobalMigration() }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canConfirmGlobalMigration)
            .accessibilityIdentifier("migration.confirm")
        }
        .padding([.horizontal, .bottom], 16)
      }
      .frame(width: 520, height: 520)
      .interactiveDismissDisabled(session.stage == .applying)
    }
  }
}

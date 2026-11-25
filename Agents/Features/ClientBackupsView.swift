import AgentsCore
import AppKit
import SwiftUI

struct ClientBackupsView: View {
  @Bindable var model: AppModel
  @State private var panelAnchor = NSView()

  var body: some View {
    Form {
      Section {
        ForEach(BackupClient.allCases, id: \.self) { client in
          Toggle(
            client.displayName,
            isOn: selection(client, in: $model.backupClients)
          )
          .accessibilityIdentifier("backup.client.\(client.rawValue)")
        }
      } header: {
        Text("Clients")
      } footer: {
        Text("Each package includes one client’s local sessions and user configuration.")
      }

      Section("Projects (Optional)") {
        if model.preferences.projects.isEmpty {
          Text("Add projects in the sidebar to include their configuration.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.preferences.projects, id: \.self) { url in
            Toggle(isOn: selection(url, in: $model.backupProjects)) {
              PathView(url: url)
            }
          }
        }
      }

      Section("Output Folder") {
        if let directory = model.backupDirectory { PathView(url: directory) }
        Button(model.backupDirectory == nil ? "Choose Folder…" : "Change Folder…") {
          chooseBackupLocation(
            from: panelAnchor, title: "Choose Backup Folder", folder: true, canCreate: true
          ) { model.backupDirectory = $0 }
        }
        .accessibilityIdentifier("backup.chooseFolder")
      }

      if !model.backupOutcomes.isEmpty {
        Section("Backup Results") {
          ForEach(model.backupOutcomes) { outcome in
            LabeledContent(outcome.client.displayName) {
              if let package = outcome.package {
                PathView(url: package)
              } else {
                Label("Backup failed", systemImage: "exclamationmark.triangle")
              }
            }
          }
        }
      }
    }
    .toggleStyle(.checkbox)
    .formStyle(.grouped)
    .disabled(!model.canStartBackup)
    .background(OpenPanelAnchor(view: panelAnchor))
    .toolbar {
      ToolbarItemGroup {
        Button("Restore Package…") {
          chooseBackupLocation(from: panelAnchor, title: "Open Backup Package", folder: false) {
            model.openBackupPackage($0)
          }
        }
        .accessibilityIdentifier("backup.openPackage")
        .disabled(!model.canStartBackup)

        Button("Back Up") { model.backUpSelectedClients() }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("backup.create")
          .disabled(
            !model.canStartBackup || model.backupClients.isEmpty || model.backupDirectory == nil)
      }
    }
    .sheet(item: $model.restoreSession) { _ in ClientRestoreView(model: model) }
  }

  private func selection<Value: Hashable>(_ value: Value, in values: Binding<Set<Value>>)
    -> Binding<Bool>
  {
    Binding(
      get: { values.wrappedValue.contains(value) },
      set: { isSelected in
        if isSelected {
          values.wrappedValue.insert(value)
        } else {
          values.wrappedValue.remove(value)
        }
      })
  }
}

private struct ClientRestoreView: View {
  @Bindable var model: AppModel
  @State private var panelAnchor = NSView()

  var body: some View {
    if let session = model.restoreSession {
      VStack(alignment: .leading, spacing: 16) {
        Text(session.client.map { "Restore \($0.displayName)" } ?? "Restore Package")
          .font(.headline)
        PathView(url: session.package).foregroundStyle(.secondary)
        content(for: session)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if let message = session.message {
          Label(message, systemImage: "exclamationmark.triangle")
        }
        controls(for: session)
      }
      .padding(24)
      .frame(width: 700, height: 520)
      .background(OpenPanelAnchor(view: panelAnchor))
      .interactiveDismissDisabled(session.isBusy)
    }
  }

  @ViewBuilder private func content(for session: ClientRestoreSession) -> some View {
    switch session.stage {
    case .inspecting:
      ProgressView("Reading the backup package…")
    case .mapping:
      if session.projects.isEmpty {
        Text("Ready to review file changes.")
          .foregroundStyle(.secondary)
      } else {
        Form {
          Section("Project Destinations") {
            ForEach(session.projects, id: \.self) { original in
              LabeledContent {
                HStack {
                  if let destination = session.destinations[original] {
                    PathView(url: destination)
                  }
                  Button(session.destinations[original] == nil ? "Choose Folder…" : "Change…") {
                    chooseBackupLocation(
                      from: panelAnchor, title: "Choose Project Destination", folder: true
                    ) { model.mapBackupProject(original, to: $0, sessionID: session.id) }
                  }
                  .accessibilityLabel("Choose destination for \(original)")
                }
              } label: {
                CompactText(text: original)
              }
            }
          }
        }
        .formStyle(.grouped)
      }
    case .previewing:
      ProgressView("Comparing files…")
    case .review(let review):
      VStack(alignment: .leading, spacing: 8) {
        if review.hasReplacements {
          Label(
            "Restore will overwrite the files marked Replace.",
            systemImage: "exclamationmark.triangle")
        }
        if review.rows.isEmpty {
          Text("The package has no file changes to show.").foregroundStyle(.secondary)
        } else {
          Table(review.rows) {
            TableColumn("Change") { row in
              switch row.kind {
              case .add: Text("Add")
              case .replace: Text("Replace").fontWeight(.semibold)
              case .unchanged: Text("Unchanged").foregroundStyle(.secondary)
              }
            }
            .width(100)
            TableColumn("Path") { row in CompactText(text: row.path).monospaced() }
          }
          .accessibilityIdentifier("restore.files")
        }
      }
    case .restoring:
      ProgressView("Restoring files…")
    case .restored:
      Label("Backup restored", systemImage: "checkmark.circle")
    case .failed:
      Color.clear
    }
  }

  private func controls(for session: ClientRestoreSession) -> some View {
    HStack {
      if case .review = session.stage, !session.projects.isEmpty {
        Button("Change Destinations…") { model.editBackupDestinations() }
      }
      Spacer()
      switch session.stage {
      case .restored, .failed:
        Button("Done") { model.restoreSession = nil }
          .keyboardShortcut(.defaultAction)
      default:
        Button("Cancel", role: .cancel) { model.restoreSession = nil }
          .keyboardShortcut(.cancelAction)
          .disabled(session.isBusy)
      }
      switch session.stage {
      case .mapping:
        Button("Review Restore") { model.reviewBackupRestore() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("restore.review")
          .disabled(!session.hasAllDestinations || model.isApplying || model.isTerminating)
      case .review(let review):
        Button("Restore", role: review.hasReplacements ? .destructive : nil) {
          model.confirmBackupRestore()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("restore.confirm")
        .disabled(model.isApplying || model.isTerminating)
      default:
        EmptyView()
      }
    }
  }
}

@MainActor
private func chooseBackupLocation(
  from anchor: NSView, title: String, folder: Bool, canCreate: Bool = false,
  onChoice: @escaping (URL) -> Void
) {
  guard let window = anchor.window else { return }
  let panel = NSOpenPanel()
  panel.title = title
  panel.canChooseDirectories = folder
  panel.canChooseFiles = !folder
  panel.canCreateDirectories = canCreate
  panel.prompt = folder ? "Choose" : "Open"
  panel.beginSheetModal(for: window) { [panel] response in
    if response == .OK, let url = panel.url { onChoice(url) }
  }
}

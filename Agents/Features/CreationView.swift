import AppKit
import SwiftUI

struct CreationView: View {
  @Bindable var model: AppModel

  var body: some View {
    if let session = model.creationSession {
      VStack(alignment: .leading, spacing: 16) {
        Text("New " + session.kind.title).font(.headline)
        switch session.stage {
        case .input:
          Form {
            LabeledContent("Scope", value: session.scope.title)
            if session.kind == .skill {
              LabeledContent("Directory") {
                if session.directorySelected {
                  PathView(url: session.directory, scope: session.scope)
                } else {
                  Text("Choose a directory").foregroundStyle(.secondary)
                }
              }
              Button("Choose Directory…") { chooseDirectory() }
              TextField("Name (optional)", text: name)
              Text("Leave the name empty to create the skill in the selected directory.")
                .font(.caption).foregroundStyle(.secondary)
            } else {
              TextField("Name", text: name)
              LabeledContent("Project") { PathView(url: session.scope.root, scope: session.scope) }
            }
          }
          .formStyle(.grouped)
          HStack {
            Button("Cancel") { model.creationSession = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Continue") { model.creationSession?.stage = .confirmation }
              .keyboardShortcut(.defaultAction)
              .disabled(
                session.kind == .instructions ? session.name.isEmpty : !session.directorySelected)
          }
        case .confirmation:
          Form {
            LabeledContent("Scope", value: session.scope.title)
            LabeledContent("Directory") { PathView(url: session.directory, scope: session.scope) }
            if !session.name.isEmpty { LabeledContent("Requested name", value: session.name) }
            Text(
              "Creates a starter document. Existing content will not be replaced. Adding it to configuration is a separate action."
            )
            .foregroundStyle(.secondary)
          }.formStyle(.grouped)
          HStack {
            Button("Back") { model.creationSession?.stage = .input }
            Spacer()
            Button("Create") { model.confirmCreation() }.keyboardShortcut(.defaultAction)
              .disabled(model.isTerminating)
          }
        case .running:
          HStack {
            ProgressView().controlSize(.small)
            Text("Creating starter content…")
          }
          Text("Waiting for the operation to finish.").foregroundStyle(.secondary)
        case .created(let url):
          Label("Starter content created", systemImage: "checkmark.circle")
          PathView(url: url, scope: session.scope)
          Text("You can edit the document now. It has not been added to configuration.")
            .foregroundStyle(.secondary)
          HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open") { NSWorkspace.shared.open(url) }
            Spacer()
            Button("Done") { closeAndRefresh(session) }.keyboardShortcut(.defaultAction)
          }
        case .failed, .unconfirmed, .cancelled:
          if case .unconfirmed = session.stage {
            Text(
              "Creation returned an error without a confirmed outcome. Content may already exist. Inspect the directory before retrying."
            )
            .foregroundStyle(.secondary)
            Button("Show Directory in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            }
          }
          ForEach(session.messages) { Text($0.message).textSelection(.enabled) }
          if case .cancelled = session.stage { Text("Creation was cancelled before it started.") }
          HStack {
            Button("Edit Request") { model.creationSession?.stage = .input }
            Spacer()
            Button("Done") { model.creationSession = nil }.keyboardShortcut(.defaultAction)
          }
        }
      }
      .padding(24)
      .frame(width: 520)
      .frame(minHeight: 220)
      .interactiveDismissDisabled(isRunning(session))
    }
  }

  private var name: Binding<String> {
    Binding(get: { model.creationSession?.name ?? "" }, set: { model.creationSession?.name = $0 })
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url { model.selectCreationDirectory(url) }
  }

  private func isRunning(_ session: CreationSession) -> Bool {
    if case .running = session.stage { return true }
    return false
  }

  private func closeAndRefresh(_ session: CreationSession) {
    model.creationSession = nil
    if model.scope == session.scope { model.refresh() }
  }
}

import AppKit
import SwiftUI

struct CreationView: View {
  @Bindable var model: AppModel
  @State private var pickerAnchor = NSView()

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
            Button("Review Creation…") { model.reviewCreation() }
              .keyboardShortcut(.defaultAction)
              .disabled(
                session.kind == .instructions ? session.name.isEmpty : !session.directorySelected)
          }
        case .describing:
          ProgressView("Checking which starter files to create…")
        case .confirmation:
          Form {
            LabeledContent("Scope", value: session.scope.title)
            LabeledContent("Directory") { PathView(url: session.directory, scope: session.scope) }
            if !session.name.isEmpty { LabeledContent("Requested name", value: session.name) }
            if let description = session.description {
              LabeledContent("File") { PathView(url: description.file, scope: session.scope) }
              DetailsGroup("Starter Content") {
                Text(verbatim: description.template).font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
              }
            }
            if session.stale { Text("Inputs changed. Go back and review creation again.") }
            Text(
              "Creates a starter document. Existing content will not be replaced. Adding it to configuration is a separate action."
            )
            .foregroundStyle(.secondary)
          }.formStyle(.grouped)
          HStack {
            Button("Back") { model.creationSession?.stage = .input }
            Spacer()
            Button("Create") { model.confirmCreation() }.keyboardShortcut(.defaultAction)
              .disabled(model.isTerminating || session.stale || session.scope != model.scope)
          }
        case .running:
          HStack {
            ProgressView().controlSize(.small)
            Text("Creating starter content…")
          }
        case .created(let url):
          Label("Starter content created", systemImage: "checkmark.circle")
          if let terminal = session.terminal, terminal.recovery.pending {
            Text(terminal.message)
            ForEach(session.messages.filter { $0.message != terminal.message }) { Text($0.message) }
          }
          PathView(url: url, scope: session.scope)
          Text("You can edit the document now. It has not been added to configuration.")
            .foregroundStyle(.secondary)
          HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open") { NSWorkspace.shared.open(url) }
            Spacer()
            Button("Done") { closeAndRefresh(session) }.keyboardShortcut(.defaultAction)
          }
        case .failed, .cancelled:
          if let terminal = session.terminal {
            Text(terminal.message)
            if let description = session.description {
              PathView(url: description.file, scope: session.scope)
            }
          }
          ForEach(session.messages.filter { $0.message != session.terminal?.message }) {
            Text($0.message).textSelection(.enabled)
          }
          if case .cancelled = session.stage { Text("Creation was cancelled before it started.") }
          HStack {
            Button("Edit Request") { model.creationSession?.stage = .input }
            Spacer()
            Button("Done") { model.creationSession = nil }.keyboardShortcut(.defaultAction)
          }
        }
      }
      .background(OpenPanelAnchor(view: pickerAnchor))
      .padding(24)
      .frame(width: 520)
      .frame(minHeight: isRunning(session) ? nil : 220)
      .interactiveDismissDisabled(isRunning(session))
    }
  }

  private var name: Binding<String> {
    Binding(get: { model.creationSession?.name ?? "" }, set: { model.creationSession?.name = $0 })
  }

  private func chooseDirectory() {
    guard let session = model.creationSession, let window = pickerAnchor.window else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    panel.prompt = "Choose"
    panel.beginSheetModal(for: window) { [panel] response in
      if response == .OK, let url = panel.url {
        model.selectCreationDirectory(url, for: session)
      }
    }
  }

  private func isRunning(_ session: CreationSession) -> Bool {
    if case .running = session.stage { return true }
    if case .describing = session.stage { return true }
    return false
  }

  private func closeAndRefresh(_ session: CreationSession) {
    model.creationSession = nil
    if model.scope == session.scope { model.refresh() }
  }
}

struct OpenPanelAnchor: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

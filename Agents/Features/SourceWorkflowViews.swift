import AgentsCore
import SwiftUI

struct ImportResolutionEditor: View {
  @Binding var value: ImportResolution
  var body: some View {
    DetailsGroup("Resolve Import Inputs") {
      Toggle(
        "Specify producer selection keys",
        isOn: Binding(get: { value.selection != nil }, set: { value.selection = $0 ? [] : nil }))
      if value.selection != nil {
        DraftRows(values: Binding(get: { value.selection ?? [] }, set: { value.selection = $0 })) {
          row, actions in
          TextField("Selection key", text: row)
          DraftRowButtons(actions: actions)
        }
        Button("Add Selection Key") { value.selection?.append("") }
        Text(
          "Use exact keys from the producer document. An empty selection explicitly selects no entries."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      DetailsGroup("Source Coordinates") {
        DraftRows(values: $value.sources) { row, actions in
          TextField("Producer source key", text: row.key)
          SourceDeclarationEditor(value: row.declaration)
          DraftRowButtons(actions: actions)
        }
        Button("Add Source Coordinates") { value.sources.append(.init()) }
      }
      DetailsGroup("Captured Installed Skills") {
        DraftRows(values: $value.skills) { row, actions in
          TextField("Skill name", text: row.name)
          TextField("Path relative to input directory", text: row.path)
          DraftRowButtons(actions: actions)
        }
        Button("Add Installed Skill") { value.skills.append(.init()) }
        Text("Select independent authoring content. Deployment claims do not grant ownership.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if value.hasDuplicateKeys { Text("Each source key and skill name must be unique.") }
      Text("Inspect again after changing inputs. Conversion diagnostics remain authoritative.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct SourceDeclarationEditor: View {
  @Binding var value: SourceDeclaration
  var body: some View {
    Picker("Source", selection: $value.kind) {
      Text("Local Directory").tag(SourceKind.local)
      Text("Git Repository").tag(SourceKind.git)
      Text("Skill Index").tag(SourceKind.wellKnown)
    }
    TextField("Location", text: $value.location)
    OptionalText(title: "search path", value: $value.path)
    RequirementEditor(value: $value.requirement)
  }
}

struct WatchStatusView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.watchStatusSession {
      VStack(alignment: .leading, spacing: 16) {
        Text("Subscription Changes").font(.headline)
        PathView(url: session.scope.root, scope: session.scope)
        Text("Review source changes, then explicitly mark the displayed content as read.")
          .foregroundStyle(.secondary)
        if session.busy { ProgressView("Checking source content…") }
        if session.stale { Text("Inputs changed. Check again for current results.") }
        Form {
          ForEach(Array(session.statuses.enumerated()), id: \.offset) { _, status in
            Section(status.alias) {
              WatchBaselineView(title: "Recorded baseline", value: status.seen)
              WatchBaselineView(title: "Current content", value: status.current)
              if let commits = status.commitCount {
                LabeledContent("New commits", value: String(commits))
              }
              if status.changes.isEmpty { Text("No content changes found.") }
              Button("Mark Displayed Content as Read") { model.markSubscriptionRead(status) }
                .disabled(
                  session.busy || session.stale || session.terminal != nil
                    || session.scope != model.scope || !model.canModify)
              ForEach(Array(status.changes.enumerated()), id: \.offset) { _, change in
                DetailsGroup(change.name + " · " + change.change.rawValue) {
                  LabeledContent("Kind", value: DeclarationLabels.kind(change.kind.rawValue))
                  ForEach(Array(change.files.enumerated()), id: \.offset) { _, file in
                    DetailsGroup(file.path) {
                      WatchEntryView(title: "Before", entry: file.before)
                      WatchEntryView(title: "After", entry: file.after)
                    }
                  }
                }
              }
            }
          }
          if session.hasResult && session.statuses.isEmpty && session.messages.isEmpty {
            Text("No subscribed sources.")
          }
          if let terminal = session.terminal { Text(terminal.message) }
          ForEach(session.messages.filter { $0.message != session.terminal?.message }) {
            Text($0.message)
          }
        }.formStyle(.grouped)
        HStack {
          Button(session.busy ? "Cancel" : "Done") {
            if session.busy {
              model.cancelQueuedOperations()
            } else {
              model.watchStatusSession = nil
            }
          }.keyboardShortcut(.cancelAction)
          Spacer()
          Button("Check Again") { model.checkSubscriptions(source: session.source) }
            .disabled(session.busy || session.scope != model.scope || !model.canModify)
        }
      }.padding(24).frame(width: 680, height: 620).interactiveDismissDisabled(session.busy)
    }
  }
}

private struct WatchBaselineView: View {
  let title: String
  let value: WatchSeen
  var body: some View {
    DetailsGroup(title) {
      switch value {
      case .revision(let revision): CompactText(text: revision)
      case .artifacts(let values):
        ForEach(values.keys.sorted(), id: \.self) { key in
          LabeledContent(key) { CompactText(text: values[key] ?? "") }
        }
      }
    }
  }
}

private struct WatchEntryView: View {
  let title: String
  let entry: WatchFileEntry?
  var body: some View {
    DetailsGroup(title) {
      switch entry {
      case .none: Text("Absent")
      case .directory: Text("Directory")
      case .symbolicLink(let destination):
        LabeledContent("Link destination") { CompactText(text: destination) }
      case .file(let data, let executable):
        LabeledContent("Executable", value: executable ? "Yes" : "No")
        if let text = String(data: data, encoding: .utf8) {
          ScrollView {
            Text(verbatim: text).font(.system(.body, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
          }.frame(maxHeight: 220)
          Button("Copy Content") { copyText(text) }
        } else {
          LabeledContent("Binary content", value: "\(data.count) bytes")
        }
      }
    }
  }
}

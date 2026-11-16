import AgentsCore
import SwiftUI

struct DeclarationListView: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      if model.filteredItems.isEmpty {
        if model.search.isEmpty {
          ContentUnavailableView(
            "No \(model.page.title)", systemImage: model.page.symbol,
            description: Text("No matching entries are declared in this scope."))
        } else {
          ContentUnavailableView.search(text: model.search)
        }
      } else {
        Table(model.filteredItems, selection: $model.selectedItem) {
          TableColumn("Name", value: \.title)
          TableColumn("Kind") { item in Text(item.record.kind) }
          TableColumn("Container", value: \.container)
        }
        .accessibilityIdentifier("declaration.table")
      }
      if model.page == .sources, let snapshot = model.snapshot {
        SourceStateView(snapshot: snapshot).frame(maxHeight: 260)
      }
      if model.page == .components, let inventory = model.snapshot?.inventory, !inventory.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("Skill Inventory").font(.headline)
          Text("Managed, missing, drifted, and installed-only entries reported by Core.")
            .font(.caption).foregroundStyle(.secondary)
          Table(inventory) {
            TableColumn("Skill") { Text($0.id.name) }
            TableColumn("Agent") { Text($0.id.agent.displayName) }
            TableColumn("Status", value: \.status)
            TableColumn("Mode") { Text($0.mode ?? "Unmanaged") }
            TableColumn("Location") { Text($0.id.path).help($0.id.path) }
          }.frame(minHeight: 120, maxHeight: 240)
        }.padding(16)
      }
    }
    .searchable(text: $model.search, prompt: "Search \(model.page.title.lowercased())")
    .toolbar {
      ToolbarItem {
        Button(model.page == .sources ? "Add Source…" : "Add Component…", systemImage: "plus") {
          model.presentedIntent = model.page == .sources ? .addSource : .addComponent
        }
      }
      ToolbarItem {
        Button("Edit Structure…") { model.presentedIntent = .editStructure }
      }
    }
  }
}

struct InspectorView: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      if let item = model.selectedDeclaration {
        Section(item.title) {
          LabeledContent("Kind", value: item.record.kind)
          LabeledContent("Container", value: item.container)
          LabeledContent("Declaration node", value: item.pointer)
        }
        Section("Declared Values") {
          RecordFields(record: item.record)
        }
        if item.record.kind == "mcpServer" {
          Section("Connection") {
            Text("Viewing this declaration does not start a process or connect to a server.")
              .foregroundStyle(.secondary)
            Button("Test Connection…") { model.presentedIntent = .testConnection }
          }
        }
        Section {
          Button("Edit Declaration…") { model.presentedIntent = .editStructure }
        }
      } else {
        Section("Scope") {
          LabeledContent("Name", value: model.scope.title)
          LabeledContent("Location", value: model.scope.root.path)
          LabeledContent("Kind", value: model.scope.kind.rawValue)
        }
        if let snapshot = model.snapshot {
          Section("Configuration Files") {
            LabeledContent("Declaration", value: snapshot.manifestURL.path)
            LabeledContent("Resolved", value: snapshot.resolvedURL.path)
            LabeledContent("Subscriptions", value: snapshot.watchURL.path)
          }
          if let digest = snapshot.document?.digest {
            Section("Read Identity") {
              Text(digest).font(.caption).textSelection(.enabled)
            }
          }
        }
        Section {
          Text("Select a declaration to inspect its authored values and conditions.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .textSelection(.enabled)
    .accessibilityIdentifier("workspace.inspector")
  }
}

struct RecordFields: View {
  let record: DeclarationRecord
  var sensitive = false

  var body: some View {
    ForEach(record.fields.keys.sorted(), id: \.self) { key in
      if let value = record[key] {
        DeclarationField(
          name: key, value: value,
          sensitive: sensitive || key == "environment" || key == "headers")
      }
    }
  }
}

struct DeclarationField: View {
  let name: String
  let value: DeclarationValue
  var sensitive = false

  var body: some View {
    switch value {
    case .string(let text):
      LabeledContent(name, value: sensitive ? "Value hidden" : text)
    case .integer(let number):
      LabeledContent(name, value: String(number))
    case .boolean(let enabled):
      LabeledContent(name, value: enabled ? "true" : "false")
    case .null:
      LabeledContent(name, value: "null")
    case .requirement(let requirement):
      LabeledContent(name, value: String(describing: requirement))
    case .array(let values):
      DisclosureGroup(name + " (\(values.count))") {
        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
          DeclarationField(name: String(index + 1), value: value, sensitive: sensitive)
        }
      }
    case .dictionary(let values):
      DisclosureGroup(name) {
        ForEach(values.keys.sorted(), id: \.self) { key in
          if let value = values[key] {
            DeclarationField(name: key, value: value, sensitive: sensitive)
          }
        }
      }
    case .record(let record):
      DisclosureGroup(name + " · " + record.kind) {
        RecordFields(record: record, sensitive: sensitive)
      }
    }
  }
}

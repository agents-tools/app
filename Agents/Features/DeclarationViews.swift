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
          TableColumn("Kind") { item in Text(DeclarationLabels.kind(item.record.kind)) }
          TableColumn("Container", value: \.container)
        }
        .accessibilityIdentifier("declaration.table")
      }
      if model.page == .sources, let snapshot = model.snapshot {
        SourceStateView(snapshot: snapshot, model: model).frame(maxHeight: 260)
      }
      if model.page == .components, let inventory = model.snapshot?.inventory, !inventory.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("Skill Inventory").font(.headline)
          Text("Managed skill deployments and their current disk status.")
            .font(.caption).foregroundStyle(.secondary)
          Table(inventory) {
            TableColumn("Skill") { Text($0.id.name) }
            TableColumn("Agent") { Text($0.id.agent.displayName) }
            TableColumn("Status", value: \.status)
            TableColumn("Mode") { Text($0.mode?.rawValue ?? "Unavailable") }
            TableColumn("Location") {
              PathView(url: URL(fileURLWithPath: $0.id.path), scope: model.scope)
            }
          }.frame(minHeight: 120, maxHeight: 240)
        }.padding(16)
      }
    }
    .searchable(text: $model.search, prompt: "Search \(model.page.title.lowercased())")
    .toolbar {
      ToolbarItem {
        Button(model.page == .sources ? "Add Source…" : "Add Component…", systemImage: "plus") {
          model.beginDraft(model.page == .sources ? .source : .component)
        }
      }
      ToolbarItem {
        if model.page == .sources {
          Button("Add from Source…") { model.beginCatalog() }.disabled(!model.canModify)
        }
      }
      ToolbarItem {
        Button("Edit Configuration…") { model.editConfigurationYAML() }
          .disabled(!model.canModify)
      }
    }
  }
}

struct InspectorView: View {
  @Bindable var model: AppModel

  var body: some View {
    let sourceAccess = model.sourceAccessSelection
    Form {
      if let item = model.selectedDeclaration {
        Section(item.title) {
          LabeledContent("Kind", value: DeclarationLabels.kind(item.record.kind))
          LabeledContent("Container", value: item.container)
        }
        if let sourceAccess {
          SourceAccessSection(model: model, selection: sourceAccess)
        }
        Section("Declared Values") {
          RecordFields(
            record: item.record, pointer: item.pointer,
            authored: model.snapshot?.document.map { AuthoredFields(sourceMap: $0.sourceMap) })
        }
        if item.record.kind == "mcpServer" {
          Section("Connection") {
            Text("Viewing this declaration does not start a process or connect to a server.")
              .foregroundStyle(.secondary)
            ForEach(
              model.availableComponentSelection.filter { $0.kind == .mcpServer }, id: \.record
            ) { component in
              Button("Test Managed “" + component.name + "”…") { model.beginConnection(component) }
            }
          }
        }
        Section {
          if ["Component", "Source", "Group", "Group Reference"].contains(item.category) {
            Button("Edit…") { model.editSelectedDeclaration() }.disabled(!model.canModify)
          }
          if ["Component", "Source", "Group", "Group Reference"].contains(item.category) {
            Button("Move or Remove…") {
              model.beginDraft(.structure)
              model.manifestDraft?.structuralNode = item.id
              if ["Source", "Group"].contains(item.category) {
                model.manifestDraft?.structuralAction = .remove
              }
            }
          }
        }
      } else {
        Section("Scope") {
          LabeledContent("Name", value: model.scope.title)
          LabeledContent("Location") { PathView(url: model.scope.root, scope: model.scope) }
          LabeledContent("Kind", value: model.scope.kind == .user ? "User" : "Project")
        }
        if let snapshot = model.snapshot {
          Section("Configuration Files") {
            LabeledContent("Declaration") {
              PathView(url: snapshot.manifestURL, scope: model.scope)
            }
            LabeledContent("Resolved") { PathView(url: snapshot.resolvedURL, scope: model.scope) }
            LabeledContent("Subscriptions") { PathView(url: snapshot.watchURL, scope: model.scope) }
            if model.page == .components, let document = snapshot.document {
              DetailsGroup("Declaration YAML") {
                ScrollView {
                  Text(verbatim: String(decoding: document.bytes, as: UTF8.self))
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
              }
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
    .accessibilityIdentifier("workspace.inspector")
    .onChange(of: sourceAccess?.id, initial: true) {
      if let sourceAccess { model.inspectSourceAccess(sourceAccess) }
    }
    .onDisappear {
      if let sourceAccess, model.sourceAccessSelection?.id == sourceAccess.id {
        model.discardSourceAccess()
      }
    }
    .contextMenu {
      if let snapshot = model.snapshot, let digest = snapshot.document?.digest {
        Button("Copy Manifest Digest") { copyText(digest) }
        if let item = model.selectedDeclaration {
          Button("Copy Declaration Location") {
            copyText(snapshot.manifestURL.path + "#" + item.pointer)
          }
        }
      }
    }
  }
}

struct RecordFields: View {
  let record: DeclarationRecord
  var sensitive = false
  var pointer = ""
  var authored: AuthoredFields?

  var body: some View {
    ForEach(record.fields.keys.sorted(), id: \.self) { key in
      let child = AuthoredFields.child(key, of: pointer)
      if let value = record[key], authored?.contains(child) ?? true {
        DeclarationField(
          name: DeclarationLabels.field(key), value: value,
          sensitive: sensitive || key == "environment" || key == "headers",
          pointer: child, authored: authored)
      }
    }
  }
}

struct DeclarationField: View {
  let name: String
  let value: DeclarationValue
  var sensitive = false
  var pointer = ""
  var authored: AuthoredFields?

  var body: some View {
    switch value {
    case .string(let text):
      if ["Path", "URL", "Executable", "Search Path"].contains(name), !sensitive {
        LabeledContent(name) {
          CompactText(text: text)
        }
      } else {
        LabeledContent(name, value: sensitive ? "Value hidden" : text)
      }
    case .integer(let number):
      LabeledContent(name, value: String(number))
    case .boolean(let enabled):
      LabeledContent(name, value: enabled ? "true" : "false")
    case .null:
      LabeledContent(name, value: "Explicit null")
    case .requirement(let requirement):
      LabeledContent(name, value: DeclarationLabels.requirement(requirement))
    case .array(let values):
      DetailsGroup(name + " (\(values.count))") {
        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
          DeclarationField(
            name: String(index + 1), value: value, sensitive: sensitive,
            pointer: pointer + "/\(index)", authored: authored)
        }
      }
    case .dictionary(let values):
      DetailsGroup(name) {
        ForEach(values.keys.sorted(), id: \.self) { key in
          if let value = values[key] {
            DeclarationField(
              name: key, value: value, sensitive: sensitive,
              pointer: AuthoredFields.child(key, of: pointer), authored: authored)
          }
        }
      }
    case .record(let record):
      if record.kind == "null" {
        LabeledContent(name, value: "Explicit null")
      } else {
        DetailsGroup(name + " · " + DeclarationLabels.kind(record.kind)) {
          RecordFields(record: record, sensitive: sensitive, pointer: pointer, authored: authored)
        }
      }
    }
  }
}

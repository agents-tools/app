import AgentsCore
import AgentsManifest
import SwiftUI

struct ManifestDraftView: View {
  @Bindable var model: AppModel
  let fallback: ManifestDraft
  @State private var groupChild = ComponentDraft()

  var body: some View {
    if let draft = model.manifestDraft {
      VStack(alignment: .leading, spacing: 16) {
        Text("Declaration Draft").font(.headline)
        Text(
          "This draft stays in memory. Applying configuration changes is not available in this build."
        )
        .foregroundStyle(.secondary)
        Form {
          Picker("Draft", selection: binding(\.kind)) {
            Text("Default Agents").tag(ManifestDraft.Kind.defaults)
            Text("Source").tag(ManifestDraft.Kind.source)
            Text("Component").tag(ManifestDraft.Kind.component)
            Text("Group").tag(ManifestDraft.Kind.group)
            Text("Group Reference").tag(ManifestDraft.Kind.reference)
            Text("Exports").tag(ManifestDraft.Kind.exports)
            Text("Move or Remove Component").tag(ManifestDraft.Kind.structure)
          }
          switch draft.kind {
          case .defaults: AgentsEditor(value: binding(\.defaultAgents))
          case .source:
            TextField("Alias", text: binding(\.sourceAlias))
            Picker("Source", selection: binding(\.sourceKind)) {
              Text("Local Directory").tag(SourceKind.local)
              Text("Git Repository").tag(SourceKind.git)
              Text("Skill Index").tag(SourceKind.wellKnown)
            }
            TextField("Location", text: binding(\.sourceLocation))
            OptionalText(title: "search path", value: binding(\.sourcePath))
            RequirementEditor(value: binding(\.requirement))
          case .component: ComponentDraftEditor(value: binding(\.component))
          case .group:
            TextField("Name", text: binding(\.groupName))
            ConditionEditor(value: binding(\.groupCondition))
            DisclosureGroup("Components") {
              DraftRows(values: binding(\.groupComponents)) { row, actions in
                Text(DeclarationLabels.kind(row.wrappedValue.kind.rawValue))
                DraftRowButtons(actions: actions)
              }
              DisclosureGroup("Add Component") {
                ComponentDraftEditor(value: $groupChild)
                Button("Add to Group") {
                  model.manifestDraft?.groupComponents.append(groupChild.value)
                  model.manifestDraft?.validation = nil
                }
              }
            }
            GroupUsesEditor(values: binding(\.groupUses))
          case .reference:
            TextField("Group", text: binding(\.referenceName))
            OptionalText(title: "source", value: binding(\.referenceSource))
            ConditionEditor(value: binding(\.referenceCondition))
          case .exports: LinesEditor(title: "Exported groups", values: binding(\.exports))
          case .structure:
            if let document = draft.document {
              let items = CoreReader.items(document)
              Picker("Component", selection: binding(\.structuralNode)) {
                Text("Choose a component").tag(nil as NodeID?)
                ForEach(items.filter { $0.category == "Component" }) { item in
                  Text(item.container + " · " + item.title).tag(Optional(item.id))
                }
              }
              Picker("Action", selection: binding(\.structuralAction)) {
                Text("Move").tag(ManifestDraft.StructuralAction.move)
                Text("Remove").tag(ManifestDraft.StructuralAction.remove)
              }
              if draft.structuralAction == .move {
                Picker("Destination", selection: binding(\.destinationGroup)) {
                  Text("Scope").tag(nil as NodeID?)
                  ForEach(items.filter { $0.category == "Group" }) {
                    Text($0.title).tag(Optional($0.id))
                  }
                }
                Picker("Position", selection: binding(\.insertFirst)) {
                  Text("First").tag(true)
                  Text("Last").tag(false)
                }
              }
            }
          }
        }
        .formStyle(.grouped)
        .disabled(draft.isValidating)
        if draft.document == nil {
          Text(
            "This scope has no declaration. First-configuration validation and publishing are not available yet."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if let message = draft.validation { Text(message).textSelection(.enabled) }
        HStack {
          Button("Done") { model.manifestDraft = nil }.keyboardShortcut(.cancelAction)
          Spacer()
          if draft.isValidating { ProgressView().controlSize(.small) }
          Button("Validate Draft") { model.validateDraft() }
            .disabled(
              draft.document == nil || draft.isValidating || model.isTerminating
                || (draft.kind == .structure && draft.structuralNode == nil))
        }
      }
      .padding(24)
      .frame(width: 640, height: 680)
    }
  }

  private func binding<Value>(_ path: WritableKeyPath<ManifestDraft, Value>) -> Binding<Value> {
    Binding(
      get: { model.manifestDraft.map { $0[keyPath: path] } ?? fallback[keyPath: path] },
      set: {
        model.manifestDraft?[keyPath: path] = $0
        model.manifestDraft?.validation = nil
      })
  }
}

struct GroupUsesEditor: View {
  @Binding var values: [GroupUseDeclaration]
  var body: some View {
    DisclosureGroup("Group References") {
      DraftRows(values: $values) { row, actions in
        TextField("Group", text: row.name)
        OptionalText(title: "source", value: row.source)
        ConditionEditor(value: row.condition)
        DraftRowButtons(actions: actions)
      }
      Button("Add Reference") { values.append(.init(name: "")) }
    }
  }
}

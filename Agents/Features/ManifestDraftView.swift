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
        LabeledContent("Scope") { PathView(url: draft.scope.root, scope: draft.scope) }
        if draft.scope != model.scope {
          Text("This draft belongs to another scope. Return to that scope or close this draft.")
            .foregroundStyle(.secondary)
        }
        Text(
          "Edit configuration here, then review Core’s proposed changes before applying."
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
                ComponentDraftEditor(
                  value: Binding(
                    get: { ComponentDraft(row.wrappedValue) }, set: { row.wrappedValue = $0.value })
                )
                DraftRowButtons(actions: actions)
              }
              DisclosureGroup("Add Component") {
                ComponentDraftEditor(value: $groupChild)
                Button("Add to Group") {
                  model.manifestDraft?.groupComponents.append(groupChild.value)
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
        .disabled(model.isApplying)
        HStack {
          Button("Done") { model.manifestDraft = nil }.keyboardShortcut(.cancelAction)
          Spacer()

          Button("Review Changes…") { model.previewDraft() }
            .disabled(
              !model.canModify || draft.scope != model.scope
                || (draft.kind == .structure && draft.structuralNode == nil))
        }
      }
      .padding(24)
      .frame(width: 640, height: 680)
      .interactiveDismissDisabled(model.isApplying)
      .sheet(item: $model.updateSession) { _ in UpdateReviewView(model: model) }
    }
  }

  private func binding<Value>(_ path: WritableKeyPath<ManifestDraft, Value>) -> Binding<Value> {
    Binding(
      get: { model.manifestDraft.map { $0[keyPath: path] } ?? fallback[keyPath: path] },
      set: {
        model.manifestDraft?[keyPath: path] = $0
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

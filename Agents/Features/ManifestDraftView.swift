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
        Text(
          draft.replacingNode == nil && draft.kind == .component
            ? "Add Component" : "Edit Configuration"
        ).font(.headline)
        LabeledContent("Scope") { PathView(url: draft.scope.root, scope: draft.scope) }
        if draft.scope != model.scope {
          Text("These edits belong to another scope. Return to that scope or cancel.")
            .foregroundStyle(.secondary)
        }
        if draft.isStale {
          Text(
            draft.canReview(against: model.snapshot)
              ? "Inputs changed. Your edits are retained. Review again before applying."
              : "Configuration changed outside this window. Your edits are retained. Cancel and reopen the refreshed configuration before applying."
          )
          .foregroundStyle(.secondary)
        }
        Text(
          "Review your changes before applying them."
        )
        .foregroundStyle(.secondary)
        Form {
          Picker("Change", selection: binding(\.kind)) {
            Text("Default Agents").tag(ManifestDraft.Kind.defaults)
            Text("Source").tag(ManifestDraft.Kind.source)
            Text("Component").tag(ManifestDraft.Kind.component)
            Text("Group").tag(ManifestDraft.Kind.group)
            Text("Group Reference").tag(ManifestDraft.Kind.reference)
            Text("Exports").tag(ManifestDraft.Kind.exports)
            Text("Move or Remove Declaration").tag(ManifestDraft.Kind.structure)
          }
          switch draft.kind {
          case .defaults: AgentsEditor(value: binding(\.defaultAgents))
          case .source:
            TextField("Alias", text: binding(\.sourceAlias))
            SourceDeclarationEditor(
              value: Binding(
                get: {
                  let current = model.manifestDraft ?? draft
                  return .init(
                    kind: current.sourceKind, location: current.sourceLocation,
                    requirement: current.requirement, path: current.sourcePath)
                },
                set: {
                  model.manifestDraft?.sourceKind = $0.kind
                  model.manifestDraft?.sourceLocation = $0.location
                  model.manifestDraft?.requirement = $0.requirement
                  model.manifestDraft?.sourcePath = $0.path
                }))
          case .component:
            ComponentDraftEditor(value: binding(\.component), scope: draft.scope.installScope)
            if draft.replacingNode == nil, let document = draft.document {
              Picker("Container", selection: binding(\.destinationGroup)) {
                Text("Scope").tag(nil as NodeID?)
                ForEach(CoreReader.items(document).filter { $0.category == "Group" }) {
                  Text($0.title).tag(Optional($0.id))
                }
              }
            }
          case .group:
            TextField("Name", text: binding(\.groupName))
            ConditionEditor(value: binding(\.groupCondition))
            DisclosureGroup("Components") {
              DraftRows(values: binding(\.groupComponents)) { row, actions in
                ComponentDraftEditor(
                  value: Binding(
                    get: { ComponentDraft(row.wrappedValue) }, set: { row.wrappedValue = $0.value }),
                  scope: draft.scope.installScope
                )
                DraftRowButtons(actions: actions)
              }
              DisclosureGroup("Add Component") {
                ComponentDraftEditor(value: $groupChild, scope: draft.scope.installScope)
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
            if let document = draft.document {
              Picker("Container", selection: binding(\.destinationGroup)) {
                Text("Scope").tag(nil as NodeID?)
                ForEach(CoreReader.items(document).filter { $0.category == "Group" }) {
                  Text($0.title).tag(Optional($0.id))
                }
              }
            }
          case .exports:
            DraftRows(values: binding(\.exports)) { row, actions in
              TextField("Exported group", text: row)
              DraftRowButtons(actions: actions)
            }
            Button("Add Export") { model.manifestDraft?.exports.append("") }
          case .structure:
            if draft.document != nil {
              let items = draft.structuralItems
              Picker("Declaration", selection: binding(\.structuralNode)) {
                Text("Choose a declaration").tag(nil as NodeID?)
                ForEach(items) { item in
                  Text(item.category + " · " + item.container + " · " + item.title).tag(
                    Optional(item.id))
                }
              }
              Picker("Action", selection: binding(\.structuralAction)) {
                Text("Move").tag(ManifestDraft.StructuralAction.move).disabled(
                  !draft.structuralCanMove)
                Text("Remove").tag(ManifestDraft.StructuralAction.remove)
              }
              if let item = items.first(where: { $0.id == draft.structuralNode }),
                ["Source", "Group"].contains(item.category)
              {
                Text("This declaration supports removal. Edit its contents using its native form.")
                Button("Choose Removal") { model.manifestDraft?.structuralAction = .remove }
              }
              if draft.structuralAction == .move && draft.structuralCanMove {
                Picker("Destination", selection: binding(\.destinationGroup)) {
                  Text("Scope").tag(nil as NodeID?)
                  ForEach(items.filter { $0.category == "Group" }) {
                    Text($0.title).tag(Optional($0.id))
                  }
                }
                Picker("Relative to", selection: binding(\.destinationNode)) {
                  Text("Container boundary").tag(nil as NodeID?)
                  ForEach(draft.positionItems) {
                    Text($0.container + " · " + $0.title).tag(Optional($0.id))
                  }
                }
                Picker("Position", selection: binding(\.insertFirst)) {
                  Text(draft.destinationNode == nil ? "First" : "Before").tag(true)
                  Text(draft.destinationNode == nil ? "Last" : "After").tag(false)
                }
              }
            }
          }
        }
        .formStyle(.grouped)
        .disabled(model.isApplying)
        HStack {
          Button("Cancel") { model.manifestDraft = nil }.keyboardShortcut(.cancelAction)
          Spacer()

          Button("Review Changes…") { model.previewDraft() }
            .disabled(
              !model.canModify || !draft.canReview(against: model.snapshot)
                || draft.scope != model.scope
                || (draft.kind == .structure && !draft.structuralReady))
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

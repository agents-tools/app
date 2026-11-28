import AgentsCore
import AgentsUpdates
import SwiftUI

struct ManagedStateView: View {
  let model: AppModel
  let snapshot: WorkspaceSnapshot
  private enum Grouping: String, CaseIterable {
    case components = "Components"
    case deployments = "Installed Files"
    case resources = "Resources"
  }
  private struct Record: Identifiable {
    let id: String
    let name: String
    let kind: String
    let summary: String
  }
  @State private var grouping = Grouping.components
  @State private var selection: String?

  private var records: [Record] {
    switch grouping {
    case .components:
      snapshot.inspection.components.map {
        Record(
          id: $0.record, name: $0.name, kind: groupTitle($0.kind),
          summary: $0.recipients.map(\.displayName).joined(separator: ", "))
      }
    case .deployments:
      snapshot.inspection.deployments.map {
        Record(
          id: $0.identity, name: $0.location.lastPathComponent,
          kind: $0.status.rawValue.capitalized,
          summary: $0.location.path)
      }
    case .resources:
      snapshot.inspection.resources.map {
        Record(id: $0.identity, name: $0.path, kind: $0.kind, summary: $0.source)
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Records", selection: $grouping) {
        ForEach(Grouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .labelsHidden().pickerStyle(.segmented).fixedSize().padding(8)
      VSplitView {
        Table(records, selection: $selection) {
          TableColumn("Name", value: \.name)
          TableColumn(grouping == .deployments ? "Status" : "Kind", value: \.kind)
          TableColumn(
            grouping == .components ? "Clients" : grouping == .resources ? "Source" : "Location",
            value: \.summary)
        }
        .accessibilityIdentifier("overview.records")
        .frame(minHeight: 160)
        if let selection {
          Form { details(selection) }.formStyle(.grouped).frame(minHeight: 100, idealHeight: 190)
        }
      }
    }
    .onChange(of: grouping) { selection = nil }
  }

  @ViewBuilder private func details(_ id: String) -> some View {
    switch grouping {
    case .components:
      if let component = snapshot.inspection.components.first(where: { $0.record == id }) {
        componentRow(component)
      }
    case .deployments:
      if let deployment = snapshot.inspection.deployments.first(where: { $0.identity == id }) {
        Section(deployment.location.lastPathComponent) {
          LabeledContent("Target") { PathView(url: deployment.location, scope: snapshot.scope) }
          LabeledContent("Status", value: deployment.status.rawValue.capitalized)
          LabeledContent("Format", value: deployment.format)
          LabeledContent("Ownership", value: deployment.ownership)
          LabeledContent(
            "Agents", value: deployment.recipients.map(\.displayName).joined(separator: ", "))
          if let readers = deployment.effectiveReaders {
            LabeledContent("Readers", value: readers.map(\.displayName).joined(separator: ", "))
          }
          if deployment.privateMaterialization {
            Label("Contains private material", systemImage: "lock")
          }
          if let message = deployment.diagnostic { Text(message) }
        }
      }
    case .resources:
      if let resource = snapshot.inspection.resources.first(where: { $0.identity == id }) {
        Section(resource.path) {
          LabeledContent("Kind", value: resource.kind)
          LabeledContent("Source") { CompactText(text: resource.source) }
          if let url = resource.location {
            LabeledContent("Location") { PathView(url: url, scope: snapshot.scope) }
          }
          ForEach(Array((resource.entries + resource.support).enumerated()), id: \.offset) {
            _, entry in
            LabeledContent(
              entry.path, value: entry.kind + (entry.executable ? " · executable" : ""))
          }
        }
      }
    }
  }
  private func groupTitle(_ kind: DeclaredComponentKind) -> String {
    switch kind {
    case .mcpServer: "MCP Servers"
    case .lspServer: "Language Servers"
    case .command: "Commands"
    case .hook: "Hooks"
    case .plugin: "Plugins"
    case .subagent: "Subagents"
    default: DeclarationLabels.kind(kind.rawValue)
    }
  }

  private func componentRow(_ component: ComponentInspection) -> some View {
    Section(component.name) {
      if component.kind == .mcpServer {
        Button("Test Connection…") { model.beginConnection(component) }
      }
      if model.assistanceAvailable {
        if let input = AssistanceInput.skill(component, action: .explainSkill) {
          Button("Explain This Skill…") { model.reviewAssistance(input) }
        }
        if let input = AssistanceInput.skill(component, action: .translateDescription) {
          Button("Translate Description…") { model.reviewAssistance(input) }
        }
      }
      LabeledContent("Source") { CompactText(text: component.source) }
      if let revision = component.revision {
        LabeledContent("Revision") { CompactText(text: revision) }
      }
      LabeledContent(
        "Agents", value: component.recipients.map(\.displayName).joined(separator: ", "))
      if component.chatGPT { Label("Included in named prompts", systemImage: "text.quote") }
      DetailsGroup("Symbolic Configuration") {
        NativeInspectionValue(name: "Configuration", value: component.configuration)
      }
      ForEach(Array(component.occurrences.enumerated()), id: \.offset) { _, occurrence in
        DetailsGroup("Declared in " + occurrence.manifestPath) {
          LabeledContent("Source") { CompactText(text: occurrence.declaringSource) }
          LabeledContent(
            "Editing",
            value: occurrence.consumerEditable ? "Consumer declaration" : "Producer declaration"
          )
          if let agents = occurrence.condition.agents {
            LabeledContent(
              "Condition agents", value: agents.map(\.displayName).joined(separator: ", "))
          }
          if let scopes = occurrence.condition.scopes {
            LabeledContent(
              "Condition scopes", value: scopes.map(\.rawValue).joined(separator: ", "))
          }
          if let platforms = occurrence.condition.platforms {
            LabeledContent(
              "Condition platforms", value: platforms.map(\.rawValue).joined(separator: ", "))
          }
        }
      }
    }
  }

}

private struct NativeInspectionValue: View {
  let name: String
  let value: NativeValue
  var body: some View {
    switch value {
    case .string(let text): LabeledContent(name) { CompactText(text: text) }
    case .integer(let number): LabeledContent(name, value: String(number))
    case .decimal(let text): LabeledContent(name, value: text)
    case .boolean(let enabled): LabeledContent(name, value: enabled ? "true" : "false")
    case .null: LabeledContent(name, value: "Explicit null")
    case .array(let values):
      DetailsGroup(name) {
        ForEach(Array(values.enumerated()), id: \.offset) { index, item in
          NativeInspectionValue(name: String(index + 1), value: item)
        }
      }
    case .object(let values):
      DetailsGroup(name) {
        ForEach(values.keys.sorted(), id: \.self) { key in
          if let item = values[key] {
            NativeInspectionValue(name: key.isEmpty ? "Empty key" : key, value: item)
          }
        }
      }
    }
  }
}

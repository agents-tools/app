import AgentsCore
import AgentsUpdates
import SwiftUI

struct ManagedStateView: View {
  let model: AppModel
  let snapshot: WorkspaceSnapshot
  var body: some View {
    Section("Managed State") {
      ForEach(snapshot.inspection.components, id: \.record) { component in
        DisclosureGroup(DeclarationLabels.kind(component.kind.rawValue) + " · " + component.name) {
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
          DisclosureGroup("Symbolic Configuration") {
            NativeInspectionValue(name: "Configuration", value: component.configuration)
          }
          ForEach(Array(component.occurrences.enumerated()), id: \.offset) { _, occurrence in
            DisclosureGroup("Declared in " + occurrence.manifestPath) {
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
      ForEach(snapshot.inspection.deployments, id: \.identity) { deployment in
        DisclosureGroup(deployment.location.lastPathComponent) {
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
      DisclosureGroup("Retained Resources") {
        ForEach(snapshot.inspection.resources, id: \.identity) { resource in
          DisclosureGroup(resource.path) {
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
  }
}

private struct NativeInspectionValue: View {
  let name: String
  let value: NativeValue
  var body: some View {
    switch value {
    case .string(let text): LabeledContent(name, value: text)
    case .integer(let number): LabeledContent(name, value: String(number))
    case .decimal(let text): LabeledContent(name, value: text)
    case .boolean(let enabled): LabeledContent(name, value: enabled ? "true" : "false")
    case .null: LabeledContent(name, value: "Explicit null")
    case .array(let values):
      DisclosureGroup(name) {
        ForEach(Array(values.enumerated()), id: \.offset) { index, item in
          NativeInspectionValue(name: String(index + 1), value: item)
        }
      }
    case .object(let values):
      DisclosureGroup(name) {
        ForEach(values.keys.sorted(), id: \.self) { key in
          if let item = values[key] {
            NativeInspectionValue(name: key.isEmpty ? "Empty key" : key, value: item)
          }
        }
      }
    }
  }
}

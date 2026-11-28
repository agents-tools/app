import AgentsCore
import AgentsSkills
import AgentsUpdates
import SwiftUI

struct SkillTargetEffectsView: View {
  let report: CombinedUpdateReport
  let scope: WorkspaceScope

  var body: some View {
    let skills = report.skills.filter(\.changed)
    let files = Dictionary(grouping: skills.flatMap(\.changes), by: \.path)
    let targets = report.skills.flatMap(\.membership)
    let retainedByPath = Dictionary(grouping: targets.filter { $0.after != .absent }, by: \.path)
    let changedComponents = report.components.filter(\.changed)
    let changedInstructions = report.instructions.targets.map(InstructionFileReviewRow.init)
      .filter { $0.action != "Unchanged" || $0.target.foreign }
    let membershipChanged = skills.contains { $0.membership.contains { $0.before != $0.after } }
    ForEach(AgentID.allCases, id: \.self) { agent in
      let memberships = skills.flatMap { result in
        result.membership.filter { member in
          member.agent == agent
            && (member.before != member.after
              || result.changes.contains { Self.contains(member.path, $0.path) })
        }.map { (result.skill, $0) }
      }
      let native = changedComponents.filter {
        $0.agents.contains(agent) || $0.effectiveReaders.contains(agent)
      }
      let instructions = changedInstructions.filter {
        $0.target.afterAgents.contains(agent) || $0.target.beforeAgents?.contains(agent) == true
      }
      if !memberships.isEmpty || !native.isEmpty || !instructions.isEmpty {
        Section(agent.displayName) {
          ForEach(Array(memberships.enumerated()), id: \.offset) { _, row in
            LabeledContent(Self.action(row.1) + " " + row.0) {
              VStack(alignment: .trailing) {
                PathView(url: URL(fileURLWithPath: row.1.path), scope: scope)
                let otherRecipients = Set(retainedByPath[row.1.path, default: []].map(\.agent))
                  .subtracting([agent])
                if !otherRecipients.isEmpty {
                  Text("Shared with " + Self.clientNames(otherRecipients))
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
          ForEach(Array(native.enumerated()), id: \.offset) { _, component in
            LabeledContent(component.name) {
              PathView(url: URL(fileURLWithPath: component.path), scope: scope)
            }
          }
          ForEach(instructions) { row in
            LabeledContent(row.action + " Instruction File") {
              PathView(url: row.target.url, scope: scope)
            }
          }
        }
      }
    }
    if !files.isEmpty {
      Section("Skill Files") {
        ForEach(files.keys.sorted(), id: \.self) { path in
          let changes = files[path] ?? []
          let actions = Set(
            changes.map { change in
              change.before == nil ? "Add" : (change.after == nil ? "Remove" : "Update")
            })
          let readers = Set(
            targets.filter { $0.after != .absent && Self.contains($0.path, path) }
              .map(\.agent))
          LabeledContent(actions.count == 1 ? actions.first ?? "Change" : "Change") {
            VStack(alignment: .trailing) {
              PathView(url: URL(fileURLWithPath: path), scope: scope)
              if readers.count > 1 {
                Text(Self.clientNames(readers)).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    } else if !membershipChanged && changedComponents.isEmpty && changedInstructions.isEmpty {
      Text("No changes to deployed skill files or recipients.")
        .foregroundStyle(.secondary)
    }
    if !report.instructions.conflicts.isEmpty || !report.instructions.advisories.isEmpty {
      Section("Instruction Diagnostics") {
        ForEach(Array(report.instructions.conflicts.enumerated()), id: \.offset) { _, conflict in
          Text(verbatim: conflict).foregroundStyle(.red).textSelection(.enabled)
        }
        ForEach(report.instructions.advisories, id: \.self) { advisory in
          Text(verbatim: advisory).foregroundStyle(.secondary)
        }
      }
    }
    if let change = report.marketplaceGraphChange {
      MarketplaceGraphReview(change: change)
    }
    if !report.instructions.changedPrompts.isEmpty || report.marketplaceChanges?.isEmpty == false {
      Section("Other Changes") {
        ForEach(report.instructions.changedPrompts, id: \.self) { prompt in
          LabeledContent("Named Prompt", value: prompt)
        }
        ForEach(Array((report.marketplaceChanges ?? []).enumerated()), id: \.offset) { _, change in
          if let pin = change.after ?? change.before {
            LabeledContent("Package", value: pin.dependency.name)
          }
        }
      }
    }
  }

  private static func contains(_ parent: String, _ path: String) -> Bool {
    path == parent || path.hasPrefix(parent + "/")
  }

  private static func clientNames(_ recipients: Set<AgentID>) -> String {
    AgentID.allCases.filter(recipients.contains).map(\.displayName).joined(separator: ", ")
  }

  private static func action(_ membership: SkillMembershipChange) -> String {
    if membership.before == .absent { return "Add" }
    if membership.after == .absent { return "Remove" }
    return "Update"
  }
}

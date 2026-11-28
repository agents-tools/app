import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation

struct SkillWorkspaceItem: Identifiable, Sendable {
  let id: String
  let name: String
  let title: String
  let summary: String
  let scope: WorkspaceScope
  let source: String
  let sourceURL: URL?
  let iconURL: URL?
  var iconRevision: String? = nil
  let recipients: [AgentID]
  let installations: [InventoryItem]
  let occurrences: [OccurrenceInspection]
  var componentRecords: Set<String> = []
  let isResolved: Bool
  let targetOwner: SkillTargetOwner?
  var resolvedModes: Set<InstallMode> = []
  var liveSource: SkillSourceFile? = nil

  func isUsed(by client: AgentID, in visibleScope: WorkspaceScope) -> Bool {
    isResolved && scope == visibleScope && recipients.contains(client)
  }

  var canEditTargets: Bool { targetOwner != nil }
  var canEditInstallMode: Bool { targetOwner?.canEditInstallMode == true }
}

struct SkillTargetOwner: Equatable, Sendable {
  let documentDigest: String
  let node: NodeID
  let name: String
  let declarationPointer: String
  let requestedRecipients: Set<AgentID>
  let skillOverride: SkillOverride
  let inheritedMode: InstallMode
  let canEditInstallMode: Bool

  var effectiveMode: InstallMode { skillOverride.mode ?? inheritedMode }

  func request(recipients: Set<AgentID>) -> UpdateRequest {
    request(
      override: .init(
        agents: AgentID.allCases.filter(recipients.contains), mode: skillOverride.mode))
  }

  func request(mode: InstallMode?) -> UpdateRequest {
    request(override: .init(agents: skillOverride.agents, mode: mode))
  }

  private func request(override: SkillOverride) -> UpdateRequest {
    let edit: ManifestEdit =
      override.agents == nil && override.mode == nil
      ? .removeSkillOverride(node, name: name)
      : .upsertSkillOverride(node, .init(name: name, override: override))
    return UpdateRequest(
      operation: .edit([edit]),
      expectedDeclarationDigest: documentDigest)
  }
}

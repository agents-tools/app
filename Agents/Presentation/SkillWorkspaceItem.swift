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

  func isUsed(by client: AgentID, in visibleScope: WorkspaceScope) -> Bool {
    isResolved && scope == visibleScope && recipients.contains(client)
  }

  var canEditTargets: Bool { targetOwner != nil }
}

struct SkillTargetOwner: Equatable, Sendable {
  let documentDigest: String
  let node: NodeID
  let name: String
  let declarationPointer: String
  let requestedRecipients: Set<AgentID>
  let mode: InstallMode?

  func request(recipients: Set<AgentID>) -> UpdateRequest {
    UpdateRequest(
      operation: .edit([
        .upsertSkillOverride(
          node,
          .init(
            name: name,
            override: .init(agents: AgentID.allCases.filter(recipients.contains), mode: mode)))
      ]),
      expectedDeclarationDigest: documentDigest)
  }
}

import AgentsCore
import Foundation

extension AppModel {
  func currentSkillTargetOwner(for item: SkillWorkspaceItem) -> SkillTargetOwner? {
    guard item.scope == scope, let owner = item.targetOwner,
      snapshot?.skillWorkspaceItems.first(where: { $0.id == item.id })?.targetOwner == owner
    else { return nil }
    return owner
  }

  func previewSkillTargets(
    for item: SkillWorkspaceItem, recipients: Set<AgentID>
  ) -> UUID? {
    guard canModify, manifestDraft == nil, updateSession == nil, skillTargetsUpdateSession == nil,
      let owner = currentSkillTargetOwner(for: item), recipients != owner.requestedRecipients
    else { return nil }
    var proposal = UpdateProposal(
      id: UUID(), scope: item.scope, title: "Edit Skill Targets",
      request: owner.request(recipients: recipients))
    proposal.presentation = .skillTargets
    previewUpdate(proposal)
    return proposal.id
  }
}

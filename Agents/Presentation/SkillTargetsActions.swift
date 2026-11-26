import AgentsCore
import AgentsUpdates
import Foundation

extension AppModel {
  var canPreviewSkillChanges: Bool {
    canModify && manifestDraft == nil && updateSession == nil && skillTargetsUpdateSession == nil
  }

  func currentSkillTargetOwner(for item: SkillWorkspaceItem) -> SkillTargetOwner? {
    guard item.scope == scope, let owner = item.targetOwner,
      snapshot?.skillWorkspaceItems.first(where: { $0.id == item.id })?.targetOwner == owner
    else { return nil }
    return owner
  }

  func currentSkillSourceURL(for item: SkillWorkspaceItem) -> URL? {
    guard !readsStale, currentSkillTargetOwner(for: item) != nil, let source = item.liveSource,
      snapshot?.skillWorkspaceItems.first(where: { $0.id == item.id })?.liveSource == source
    else { return nil }
    return source.fileURL()
  }

  func previewSkillTargets(
    for item: SkillWorkspaceItem, recipients: Set<AgentID>
  ) -> UUID? {
    guard canPreviewSkillChanges,
      let owner = currentSkillTargetOwner(for: item), recipients != owner.requestedRecipients
    else { return nil }
    return previewSkillChange(
      item, title: "Edit Skill Targets", request: owner.request(recipients: recipients))
  }

  func previewSkillInstallMode(for item: SkillWorkspaceItem, mode: InstallMode?) -> UUID? {
    guard canPreviewSkillChanges, let owner = currentSkillTargetOwner(for: item),
      owner.canEditInstallMode, mode != owner.skillOverride.mode
    else { return nil }
    return previewSkillChange(
      item, title: "Change Skill Install Mode", request: owner.request(mode: mode))
  }

  private func previewSkillChange(
    _ item: SkillWorkspaceItem, title: String, request: UpdateRequest
  ) -> UUID {
    var proposal = UpdateProposal(
      id: UUID(), scope: item.scope, title: title, request: request)
    proposal.presentation = .skillTargets
    previewUpdate(proposal)
    return proposal.id
  }
}

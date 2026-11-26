import AgentsCore
import AgentsInstructions
import AgentsUpdates
import Foundation

enum InstructionOutputFocus: Sendable {
  case app(InstructionRecipient)
  case local(file: URL? = nil, recipient: AgentID? = nil)

  var title: String {
    switch self {
    case .app(let recipient): "Preview " + recipient.displayName
    case .local: "Preview Local Instructions"
    }
  }

  var emptyMessage: String {
    switch self {
    case .app(let recipient):
      "No instructions for \(recipient.displayName). Choose this app in a section’s Recipients picker."
    case .local:
      "No instructions were built for this local output. Review the recipients in your instruction declarations."
    }
  }

  func includes(_ output: InstructionBuildOutput) -> Bool {
    switch self {
    case .app(let recipient):
      return output.fileURL == nil && output.recipient == recipient
    case .local(let file, let recipient):
      guard let outputFile = output.fileURL else { return false }
      return
        (file.map { $0.standardizedFileURL.path == outputFile.standardizedFileURL.path } ?? true)
        && (recipient.map { output.recipient == .local($0) } ?? true)
    }
  }
}

struct UpdateProposal: Sendable {
  enum Presentation: Sendable { case workspace, skillTargets }

  let id: UUID
  let scope: WorkspaceScope
  let title: String
  var presentation: Presentation = .workspace
  enum Contents: Sendable {
    case update(UpdateRequest)
    case packageRequest(UpdateRequest, LifecycleOperationIntent)
    case instructionOutputs(InstructionOutputFocus?)
    case localInstructionChanges
    case packageReview(PackageUpdateReview)
  }
  let contents: Contents

  init(
    id: UUID, scope: WorkspaceScope, title: String, request: UpdateRequest,
    intent: LifecycleOperationIntent? = nil
  ) {
    self.id = id
    self.scope = scope
    self.title = title
    contents = intent.map { .packageRequest(request, $0) } ?? .update(request)
  }

  init(previewingInstructionOutputsIn scope: WorkspaceScope, focus: InstructionOutputFocus? = nil) {
    id = UUID()
    self.scope = scope
    title = focus?.title ?? "Build Instructions"
    contents = .instructionOutputs(focus)
  }

  init(reviewingLocalInstructionsIn scope: WorkspaceScope) {
    id = UUID()
    self.scope = scope
    title = "Review Local Changes"
    contents = .localInstructionChanges
  }

  init(scope: WorkspaceScope, title: String, packageReview: PackageUpdateReview) {
    id = UUID()
    self.scope = scope
    self.title = title
    contents = .packageReview(packageReview)
  }

}

struct PackageUpdateReview: Sendable {
  let scope: WorkspaceScope
  let report: CombinedUpdateReport
  let lifecycle: LifecycleInspection
  let ownershipConflict: String?
  let apply: @Sendable (String, EphemeralBindings) async -> CoreCompletion

  init<Report: Sendable>(
    _ review: LifecyclePackageReview<Report, UpdateApplyResult>,
    scope: WorkspaceScope, report: KeyPath<Report, CombinedUpdateReport>
  ) {
    self.scope = scope
    self.report = review.report[keyPath: report]
    lifecycle = review.lifecycle
    ownershipConflict = review.ownershipConflict
    apply = { title, bindings in
      await CoreActions.performPackage(review, scope: scope, title: title, bindings: bindings)
    }
  }
}

struct UpdateTerminal: Sendable {
  let disposition: UpdateTerminalDisposition
  let recoveredBeforePreparation: Bool
  let recovery: RecoveryInspection
  let succeeded: Bool
  let cancelledBeforeApply: Bool
  var packageActions: [LifecycleActionResult] = []

  var message: String {
    if recoveredBeforePreparation {
      return "An earlier transaction was recovered. Refresh and prepare again."
    }
    switch disposition {
    case .committed:
      if recovery.pending {
        return
          "Changes were committed. Recovery or cleanup still needs attention before continuing."
      }
      return succeeded
        ? "Changes applied."
        : "Changes were committed, but the operation reported an error. Refresh before continuing."
    case .rolledBack: return "The attempted changes were rolled back."
    case .recoveryRequired: return "Recovery is required before further changes."
    case .unchanged:
      return cancelledBeforeApply
        ? "Cancelled before apply. No new changes were applied."
        : succeeded && !packageActions.isEmpty
          ? "Finished. No package changes were needed."
          : "This operation did not commit changes."
    }
  }
}

struct UpdateSession: Identifiable {
  enum Stage { case preparing, review, applying, finished, failed, stale, cancelled }
  let proposal: UpdateProposal
  var id: UUID { proposal.id }
  var stage: Stage = .preparing
  var report: CombinedUpdateReport?
  var packageReview: PackageUpdateReview?
  var terminal: UpdateTerminal?
  var messages: [AppDiagnostic] = []
  var bindingInputs: [String: String] = [:]
  var requiredBindings: [String] {
    Array(Set(report?.components.flatMap(\.requiredBindings) ?? [])).sorted()
  }
  var closeTitle: String {
    switch stage {
    case .review where !offersApply: "Done"
    case .preparing, .review, .stale, .applying: "Cancel"
    case .finished, .failed, .cancelled: "Done"
    }
  }
  var bindingsReady: Bool { requiredBindings.allSatisfy { bindingInputs[$0] != nil } }
  var applyingCancelTitle: String {
    switch proposal.contents {
    case .packageRequest, .localInstructionChanges, .packageReview: "Cancel Operation"
    default: "Cancel Before Apply"
    }
  }
  var canApplyReport: Bool {
    guard let report, offersApply else { return false }
    return report.instructions.conflicts.isEmpty
      && (report.hasChanges || packageReview?.lifecycle.hasRunnableActions == true)
  }

  var isInstructionOutputPreview: Bool {
    if case .instructionOutputs = proposal.contents { return true }
    return false
  }

  var offersApply: Bool {
    switch proposal.contents {
    case .instructionOutputs: false
    case .localInstructionChanges:
      packageReview != nil && report?.instructions.targets.isEmpty == false
    default: true
    }
  }

  var instructionOutputFocus: InstructionOutputFocus? {
    if case .instructionOutputs(let focus) = proposal.contents { return focus }
    return nil
  }

  var instructionOutputs: [InstructionBuildOutput] {
    let outputs = report?.instructions.outputs ?? []
    guard let focus = instructionOutputFocus else { return outputs }
    return outputs.filter(focus.includes)
  }

  func showsInstructionOutputs(whileEditing draft: ManifestDraft?) -> Bool {
    isInstructionOutputPreview || (draft != nil && report?.instructions.outputs.isEmpty == false)
  }

  func applyTitle(whileEditing draft: ManifestDraft?) -> String {
    guard let report else { return "Apply Changes" }
    if !report.hasChanges { return "Run Package Actions" }
    if case .localInstructionChanges = proposal.contents { return "Apply Local Changes" }
    guard draft?.kind == .component, draft?.component.kind == .instructions,
      !report.skills.contains(where: \.changed), !report.components.contains(where: \.changed),
      report.marketplaceGraphChange == nil, report.marketplaceChanges?.isEmpty != false
    else { return "Apply Changes" }

    let changesLocalFiles = report.instructions.targets.contains { $0.changed || $0.agentsChanged }
    return changesLocalFiles ? "Save and Apply Local Changes" : "Save Declaration"
  }
}

extension LifecycleInspection {
  var hasRunnableActions: Bool { actions.contains { $0.withheld == nil } }
}

struct UpdateRecord: Identifiable {
  let id: UUID
  let scope: WorkspaceScope
  let title: String
  let terminal: UpdateTerminal
}

struct DiscoverySession: Identifiable {
  let id: UUID
  let scope: WorkspaceScope
  var isLoading = true
  var stale = false
  var discovery: ComponentDiscovery?
  var messages: [AppDiagnostic] = []
}

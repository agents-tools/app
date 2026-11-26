import AgentsCore
import AgentsUpdates
import Foundation

struct UpdateProposal: Sendable {
  enum Presentation: Sendable { case workspace, skillTargets }

  let id: UUID
  let scope: WorkspaceScope
  let title: String
  var presentation: Presentation = .workspace
  enum Contents: Sendable {
    case update(UpdateRequest)
    case packageRequest(UpdateRequest, LifecycleOperationIntent)
    case instructionCompilation
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

  init(compilingInstructionsIn scope: WorkspaceScope) {
    id = UUID()
    self.scope = scope
    title = "Build Instructions"
    contents = .instructionCompilation
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
    case .review where isInstructionBuild && !offersApply: "Done"
    case .preparing, .review, .stale, .applying: "Cancel"
    case .finished, .failed, .cancelled: "Done"
    }
  }
  var bindingsReady: Bool { requiredBindings.allSatisfy { bindingInputs[$0] != nil } }
  var applyingCancelTitle: String {
    switch proposal.contents {
    case .packageRequest, .instructionCompilation, .packageReview: "Cancel Operation"
    default: "Cancel Before Apply"
    }
  }
  var canApplyReport: Bool {
    guard let report, offersApply else { return false }
    return report.instructions.conflicts.isEmpty
      && (report.hasChanges || packageReview?.lifecycle.hasRunnableActions == true)
  }

  var isInstructionBuild: Bool {
    if case .instructionCompilation = proposal.contents { return true }
    return false
  }

  var offersApply: Bool {
    !isInstructionBuild || report?.instructions.targets.isEmpty == false
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

import AgentsCore
import AgentsUpdates
import Foundation

struct UpdateProposal: Sendable {
  let id: UUID
  let scope: WorkspaceScope
  let title: String
  let request: UpdateRequest
}

struct UpdateTerminal: Sendable {
  let disposition: UpdateTerminalDisposition
  let recoveredBeforePreparation: Bool
  let recovery: RecoveryInspection
  let succeeded: Bool
  let cancelledBeforeApply: Bool

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
  var terminal: UpdateTerminal?
  var messages: [AppDiagnostic] = []
  var bindingInputs: [String: String] = [:]
  var requiredBindings: [String] {
    Array(Set(report?.components.flatMap(\.requiredBindings) ?? [])).sorted()
  }
  var closeTitle: String {
    switch stage {
    case .preparing, .review, .stale, .applying: "Cancel"
    case .finished, .failed, .cancelled: "Done"
    }
  }
  var bindingsReady: Bool { requiredBindings.allSatisfy { bindingInputs[$0] != nil } }
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
  var discovery: ComponentDiscovery?
  var messages: [AppDiagnostic] = []
}

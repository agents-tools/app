import AgentsUpdates
import Foundation
import Observation

/// Passive client observations belong to Settings, independently of workspace freshness.
@MainActor @Observable
final class ClientSettingsModel {
  private(set) var requestID: UUID?
  private(set) var inspection: AgentClientInspection?
  private(set) var busy = false
  private(set) var message: String?

  func begin() -> UUID {
    let id = UUID()
    requestID = id
    busy = true
    message = nil
    return id
  }

  func finish(id: UUID, result: CoreCompletion) {
    guard requestID == id else { return }
    busy = false
    switch result.output {
    case .clientInspection(let outputID, let value) where outputID == id:
      inspection = value
    case .clientInspectionFailed(let outputID, let error) where outputID == id:
      message = error
    default:
      message =
        result.disposition == .cancelled
        ? "Detection was cancelled before it started." : "Client detection did not complete."
    }
  }
}

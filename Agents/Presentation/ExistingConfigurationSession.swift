import AgentsUpdates
import Foundation

struct ExistingConfigurationSession: Identifiable {
  enum Stage { case preparing, review, applying, failed }

  let id = UUID()
  let scope: WorkspaceScope
  var stage: Stage = .preparing
  var preview: ExistingGlobalConfigurationPreview?
  var stale = false
  var messages: [AppDiagnostic] = []

  static func existingDeclaration(in directory: URL) -> URL {
    directory.appendingPathComponent("agents.json")
  }
}

extension AppModel {
  var canPreviewExistingConfiguration: Bool {
    if case .existingConfigurationAvailable = loadState {
      return scope.kind == .user && !isTerminating && !isApplying
    }
    return false
  }

  var canApplyExistingConfiguration: Bool {
    canPreviewExistingConfiguration && existingConfigurationSession?.stage == .review
      && existingConfigurationSession?.stale == false
  }

  func previewExistingConfiguration() {
    guard scope.kind == .user, !isTerminating, !isApplying else { return }
    if let session = existingConfigurationSession {
      guard session.stage == .failed || (session.stage == .review && session.stale) else {
        return
      }
      existingConfigurationSession?.stage = .preparing
      existingConfigurationSession?.stale = false
      existingConfigurationSession?.messages = []
      existingConfigurationSession?.preview = nil
    } else {
      guard canPreviewExistingConfiguration else { return }
      existingConfigurationSession = ExistingConfigurationSession(scope: scope)
    }
    guard let session = existingConfigurationSession else { return }
    let scope = session.scope
    let actions = actions
    startOperation(
      title: "Preview existing configuration", scope: scope,
      purpose: .existingConfigurationPreview(session.id)
    ) {
      actions.previewExistingConfiguration(in: scope)
    }
  }

  func applyExistingConfiguration() {
    guard canApplyExistingConfiguration, let session = existingConfigurationSession,
      let preview = session.preview
    else { return }
    existingConfigurationSession?.stage = .applying
    let scope = session.scope
    let actions = actions
    startOperation(
      title: "Apply existing configuration", scope: scope,
      purpose: .existingConfigurationApply(session.id)
    ) {
      actions.applyExistingConfiguration(preview, in: scope)
    }
  }

  func cancelExistingConfiguration() {
    guard let session = existingConfigurationSession, session.stage != .applying else { return }
    for operation in operations.values {
      if case .existingConfigurationPreview(let id) = operation.purpose, id == session.id {
        operation.admission.cancel()
      }
    }
    existingConfigurationSession = nil
  }
}

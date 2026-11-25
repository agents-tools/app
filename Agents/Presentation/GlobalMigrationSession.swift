import AgentsUpdates
import Foundation

struct GlobalMigrationSession: Identifiable {
  enum Stage { case preparing, review, applying, failed }

  let id = UUID()
  let scope: WorkspaceScope
  var stage: Stage = .preparing
  var preview: GlobalMigrationPreview?
  var stale = false
  var messages: [AppDiagnostic] = []

  static func previousDeclaration(in directory: URL) -> URL {
    directory.appendingPathComponent("agents.json")
  }
}

extension AppModel {
  var canPreviewGlobalMigration: Bool {
    if case .globalMigrationAvailable = loadState {
      return scope.kind == .user && !isTerminating && !isApplying
    }
    return false
  }

  var canConfirmGlobalMigration: Bool {
    canPreviewGlobalMigration && migrationSession?.stage == .review
      && migrationSession?.stale == false
  }

  func previewGlobalMigration() {
    guard scope.kind == .user, !isTerminating, !isApplying else { return }
    if let session = migrationSession {
      guard session.stage == .failed || (session.stage == .review && session.stale) else {
        return
      }
      migrationSession?.stage = .preparing
      migrationSession?.stale = false
      migrationSession?.messages = []
      migrationSession?.preview = nil
    } else {
      guard canPreviewGlobalMigration else { return }
      migrationSession = GlobalMigrationSession(scope: scope)
    }
    guard let session = migrationSession else { return }
    let scope = session.scope
    let actions = actions
    startOperation(
      title: "Preview migration", scope: scope, purpose: .migrationPreview(session.id)
    ) {
      actions.previewGlobalMigration(in: scope)
    }
  }

  func confirmGlobalMigration() {
    guard canConfirmGlobalMigration, let session = migrationSession,
      let preview = session.preview
    else { return }
    migrationSession?.stage = .applying
    let scope = session.scope
    let actions = actions
    startOperation(
      title: "Migrate user configuration", scope: scope, purpose: .migrationApply(session.id)
    ) {
      actions.applyGlobalMigration(preview, in: scope)
    }
  }

  func cancelGlobalMigration() {
    guard let session = migrationSession, session.stage != .applying else { return }
    for operation in operations.values {
      if case .migrationPreview(let id) = operation.purpose, id == session.id {
        operation.admission.cancel()
      }
    }
    migrationSession = nil
  }
}

import AgentsUpdates
import Foundation

extension CoreActions {
  func previewGlobalMigration(in scope: WorkspaceScope) -> CoreCompletion {
    do {
      let preview = try GlobalConfigurationMigration.preview(environment: environment(for: scope))
      return CoreCompletion(disposition: .completed, output: .globalMigrationPreview(preview))
    } catch {
      return migrationFailure(error, in: scope, operation: "Preview migration")
    }
  }

  func applyGlobalMigration(_ preview: GlobalMigrationPreview, in scope: WorkspaceScope)
    -> CoreCompletion
  {
    do {
      try GlobalConfigurationMigration.apply(preview)
      return CoreCompletion(disposition: .completed)
    } catch {
      return migrationFailure(error, in: scope, operation: "Migrate user configuration")
    }
  }

  private func migrationFailure(_ error: any Error, in scope: WorkspaceScope, operation: String)
    -> CoreCompletion
  {
    let suggestion = (error as? any LocalizedError)?.recoverySuggestion
    let message = [error.localizedDescription, suggestion].compactMap { $0 }
      .joined(separator: "\n")
    return CoreCompletion(
      disposition: .failed,
      diagnostics: [AppDiagnostic(scope: scope, operation: operation, message: message)])
  }
}

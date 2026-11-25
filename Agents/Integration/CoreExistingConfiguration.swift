import AgentsUpdates
import Foundation

extension CoreActions {
  func previewExistingConfiguration(in scope: WorkspaceScope) -> CoreCompletion {
    do {
      let preview = try ExistingGlobalConfiguration.preview(environment: environment(for: scope))
      return CoreCompletion(disposition: .completed, output: .existingConfigurationPreview(preview))
    } catch {
      return existingConfigurationFailure(
        error, in: scope, operation: "Preview existing configuration")
    }
  }

  func applyExistingConfiguration(
    _ preview: ExistingGlobalConfigurationPreview, in scope: WorkspaceScope
  )
    -> CoreCompletion
  {
    do {
      try ExistingGlobalConfiguration.apply(preview)
      return CoreCompletion(disposition: .completed)
    } catch {
      return existingConfigurationFailure(
        error, in: scope, operation: "Apply existing configuration")
    }
  }

  private func existingConfigurationFailure(
    _ error: any Error, in scope: WorkspaceScope, operation: String
  )
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

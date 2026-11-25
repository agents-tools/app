import AgentsCore
import Foundation

extension CoreActions {
  func backUp(_ clients: [BackupClient], projects: [URL], to directory: URL, scope: WorkspaceScope)
    -> CoreCompletion
  {
    let environment = environment(for: scope)
    var diagnostics: [AppDiagnostic] = []
    let outcomes = clients.map { client in
      do {
        let package = try ClientBackups.create(
          client: client, projects: projects, to: directory, environment: environment)
        return ClientBackupOutcome(client: client, package: package)
      } catch {
        diagnostics.append(
          AppDiagnostic(
            scope: scope, operation: "Back up \(client.displayName)",
            message: "Couldn’t create the backup package.", path: directory.path))
        return ClientBackupOutcome(client: client, package: nil)
      }
    }
    return CoreCompletion(
      disposition: diagnostics.isEmpty ? .completed : .failed, diagnostics: diagnostics,
      output: .clientBackup(outcomes))
  }

  func inspectBackup(_ package: URL, scope: WorkspaceScope) -> CoreCompletion {
    do {
      let info = try ClientBackups.inspect(package)
      var destinations: [String: URL] = [:]
      for original in info.projects where original.hasPrefix("/") {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: original, isDirectory: &isDirectory),
          isDirectory.boolValue
        {
          destinations[original] = URL(fileURLWithPath: original, isDirectory: true)
        }
      }
      return CoreCompletion(
        disposition: .completed,
        output: .clientRestoreInspection(
          info.client, projects: info.projects, destinations: destinations))
    } catch {
      return backupFailure(
        "Couldn’t open this backup package. Choose a readable Agents backup.",
        operation: "Inspect backup package", scope: scope)
    }
  }

  func previewBackup(
    _ package: URL, client: BackupClient, destinations: [String: URL], scope: WorkspaceScope
  ) -> CoreCompletion {
    do {
      let preview = try ClientBackups.preview(
        package, projects: destinations, environment: environment(for: scope))
      guard preview.client == client else {
        return backupFailure(
          "The backup package changed. Close this window and open the package again.",
          operation: "Preview backup restore", scope: scope)
      }
      return CoreCompletion(
        disposition: .completed, output: .clientRestoreReview(ClientRestoreReview(preview: preview))
      )
    } catch {
      return backupFailure(
        "Couldn’t review this backup. Check the package and the selected project folders.",
        operation: "Preview backup restore", scope: scope)
    }
  }

  func restoreBackup(_ preview: ClientBackupPreview, scope: WorkspaceScope) -> CoreCompletion {
    do {
      try ClientBackups.restore(preview)
      return CoreCompletion(disposition: .completed)
    } catch {
      return backupFailure(
        "Couldn’t complete the restore. Review the file changes again before retrying.",
        operation: "Restore backup", scope: scope)
    }
  }

  private func backupFailure(_ message: String, operation: String, scope: WorkspaceScope)
    -> CoreCompletion
  {
    // Package errors can originate in client files. Report the failed action without echoing input.
    CoreCompletion(
      disposition: .failed,
      diagnostics: [AppDiagnostic(scope: scope, operation: operation, message: message)])
  }
}

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
        return ClientBackupOutcome(client: client, result: .created(package))
      } catch {
        let message = ClientBackupAction.backup(client).failureMessage(for: error)
        diagnostics.append(
          AppDiagnostic(
            scope: scope, operation: "Back up \(client.displayName)", message: message))
        return ClientBackupOutcome(client: client, result: .failed(message))
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
        ClientBackupAction.inspect.failureMessage(for: error),
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
        ClientBackupAction.preview(client).failureMessage(for: error),
        operation: "Preview backup restore", scope: scope)
    }
  }

  func restoreBackup(_ preview: ClientBackupPreview, scope: WorkspaceScope) -> CoreCompletion {
    do {
      try ClientBackups.restore(preview)
      return CoreCompletion(disposition: .completed)
    } catch {
      return backupFailure(
        ClientBackupAction.restore(preview.client).failureMessage(for: error),
        operation: "Restore backup", scope: scope)
    }
  }

  private func backupFailure(_ message: String, operation: String, scope: WorkspaceScope)
    -> CoreCompletion
  {
    CoreCompletion(
      disposition: .failed,
      diagnostics: [AppDiagnostic(scope: scope, operation: operation, message: message)])
  }
}

private enum ClientBackupAction {
  case backup(BackupClient)
  case inspect
  case preview(BackupClient)
  case restore(BackupClient)

  func failureMessage(for error: any Error) -> String {
    // Core error details can include data from client files or the selected archive.
    switch (error as? ClientBackupError, self) {
    case (.invalidPackage, .backup):
      "Couldn’t verify the new package. Back up again."
    case (.invalidPackage, _):
      "This backup package is invalid or damaged. Choose another Agents backup."
    case (.unsupportedLayout, _):
      "This client’s data layout is unsupported. Check for an Agents App update."
    case (.invalidLocation, .backup):
      "A backup location is unavailable or unsupported. Check the client and selected folders."
    case (.invalidLocation, .inspect):
      "The package location is unavailable or unsupported. Choose another backup file."
    case (.invalidLocation, _):
      "A restore location is unavailable or unsupported. Check the package and destination folders."
    case (.conflict, .backup(let client)):
      "Files changed or conflict. Quit \(client.displayName) and check the selected folders."
    case (.conflict, .inspect):
      "The package changed while it was being read. Open it again."
    case (.conflict, .preview(let client)):
      "Files changed, are in use, or conflict. Quit \(client.displayName) and check the destinations."
    case (.conflict, .restore(let client)):
      "The preview is out of date or files are in use. Quit \(client.displayName), then review again."
    case (.storageFailure, .inspect):
      "Couldn’t read the package. Check that its drive is connected and the file is readable."
    case (.storageFailure, .backup):
      "Couldn’t read or write backup data. Check storage access and free space."
    case (.storageFailure, _):
      "Couldn’t read or write restore data. Check storage access and free space, then review again."
    case (nil, .backup):
      "Couldn’t create the package. Check access to the client data and the selected folders."
    case (nil, .inspect):
      "Couldn’t open the package. Check that the file is readable or choose another Agents backup."
    case (nil, .preview):
      "Couldn’t review the backup. Check access to the package and destination folders."
    case (nil, .restore):
      "Couldn’t restore the backup. Check access to the destination folders, then review again."
    }
  }
}

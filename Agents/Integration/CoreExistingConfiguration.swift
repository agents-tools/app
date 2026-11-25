import AgentsCore
import AgentsUpdates
import Darwin
import Foundation

struct ExistingConfigurationReview: Sendable {
  let preview: ExistingGlobalConfigurationPreview
  let inputs: ExistingConfigurationInputs
}

/// The exact configuration files watched by the App. Core owns the full apply preconditions.
struct ExistingConfigurationInputs: Sendable {
  private enum Stamp: Equatable, Sendable {
    case missing
    case unreadable
    case present(
      device: dev_t, inode: ino_t, size: off_t,
      modifiedSeconds: Int, modifiedNanoseconds: Int,
      changedSeconds: Int, changedNanoseconds: Int)

    init(at url: URL) {
      var info = stat()
      guard lstat(url.path, &info) == 0 else {
        self = errno == ENOENT ? .missing : .unreadable
        return
      }
      self = .present(
        device: info.st_dev, inode: info.st_ino, size: info.st_size,
        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
        changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }
  }

  private let files: [URL: Stamp]

  init(store: StateStore) {
    files = Dictionary(
      uniqueKeysWithValues: CoreReader.stateDependencies(store: store).map {
        ($0.url, Stamp(at: $0.url))
      })
  }

  var hasChanged: Bool {
    files.contains { $0.value == .unreadable || Stamp(at: $0.key) != $0.value }
  }
}

extension CoreActions {
  func previewExistingConfiguration(in scope: WorkspaceScope) -> CoreCompletion {
    do {
      let environment = environment(for: scope)
      let inputs = ExistingConfigurationInputs(
        store: StateStore(scope: .user, environment: environment))
      let preview = try ExistingGlobalConfiguration.preview(environment: environment)
      let review = ExistingConfigurationReview(preview: preview, inputs: inputs)
      return CoreCompletion(disposition: .completed, output: .existingConfigurationPreview(review))
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

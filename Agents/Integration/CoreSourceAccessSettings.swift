import AgentsCore
import Foundation

struct SourceAccessSettingsDocument: Sendable {
  let editor: SourceAccessSettingsEditor
  let profile: SourceAccessProfile?
  let issue: SourceAccessSettingsIssue?

  init(editor: SourceAccessSettingsEditor) {
    self.editor = editor
    do {
      profile = try editor.inspect()
      issue = nil
    } catch {
      profile = nil
      issue = .init(error)
    }
  }

  var isPresent: Bool { editor.original != nil || issue != nil }

  var initialDraft: String {
    if !isPresent { return "version: 1\negress: directAllowed\n" }
    return editor.original.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
}

enum SourceAccessSettingsIssue: Error, Sendable {
  case core(SourceAccessSettingsError)
  case unavailable

  init(_ error: any Error) {
    self = (error as? SourceAccessSettingsError).map(Self.core) ?? .unavailable
  }

  var message: String {
    switch self {
    case .core(let error): error.localizedDescription
    case .unavailable: "Source access settings could not be read or saved."
    }
  }

  var requiresReload: Bool {
    switch self {
    case .core(.changed), .core(.unsafeLocation): true
    default: false
    }
  }
}

struct SourceAccessSettingsRead: Sendable {
  let location: URL
  let document: Result<SourceAccessSettingsDocument, SourceAccessSettingsIssue>
}

enum SourceAccessSettingsResult: Sendable {
  case read(SourceAccessSettingsRead)
  case preview(SourceAccessSettingsPreview)
  case saved(SourceAccessSettingsRead, reset: Bool)
  case failed(SourceAccessSettingsIssue)
}

extension CoreActions {
  func readSourceAccessSettings() -> CoreCompletion {
    .init(disposition: .completed, output: .sourceAccessSettings(.read(sourceAccessSettings())))
  }

  func previewSourceAccessSettings(
    _ bytes: Data?, using editor: SourceAccessSettingsEditor
  ) -> CoreCompletion {
    sourceAccessSettingsResult { .preview(try editor.preview(bytes)) }
  }

  func saveSourceAccessSettings(
    _ preview: SourceAccessSettingsPreview, using editor: SourceAccessSettingsEditor
  ) -> CoreCompletion {
    sourceAccessSettingsResult {
      try editor.save(preview)
      return .saved(sourceAccessSettings(), reset: preview.profile == nil)
    }
  }

  private func sourceAccessSettings() -> SourceAccessSettingsRead {
    let runtime = environment(for: WorkspaceScope(kind: .user, root: home))
    let location = SourceAccessSettingsEditor.settingsURL(environment: runtime)
    do {
      let editor = try SourceAccessSettingsEditor(environment: runtime)
      return .init(location: location, document: .success(.init(editor: editor)))
    } catch {
      return .init(location: location, document: .failure(.init(error)))
    }
  }

  private func sourceAccessSettingsResult(
    _ work: () throws -> SourceAccessSettingsResult
  ) -> CoreCompletion {
    do {
      return .init(disposition: .completed, output: .sourceAccessSettings(try work()))
    } catch {
      return .init(disposition: .failed, output: .sourceAccessSettings(.failed(.init(error))))
    }
  }
}

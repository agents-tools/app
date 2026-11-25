import AgentsCore
import Foundation
import Observation

struct SourceAccessSettingsReview: Identifiable {
  let id: UUID
  let preview: SourceAccessSettingsPreview
}

@MainActor @Observable
final class SourceAccessSettingsModel {
  private(set) var location: URL?
  private(set) var document: SourceAccessSettingsDocument?
  private(set) var draft = ""
  private(set) var review: SourceAccessSettingsReview?
  private(set) var requestID: UUID?
  private(set) var issue: SourceAccessSettingsIssue?
  private(set) var message: String?
  private(set) var requiresReload = false

  var isBusy: Bool { requestID != nil }
  var hasDraftChanges: Bool {
    document.map { !draft.utf8.elementsEqual($0.initialDraft.utf8) } ?? false
  }
  var canPreview: Bool { document != nil && !isBusy && !requiresReload }
  var canReset: Bool { canPreview && document?.isPresent == true }

  func setDraft(_ value: String) {
    guard !isBusy, !draft.utf8.elementsEqual(value.utf8) else { return }
    draft = value
    review = nil
    message = nil
    if !requiresReload { issue = nil }
  }

  func dismissReview() { review = nil }

  func begin() -> UUID? {
    guard !isBusy else { return nil }
    let id = UUID()
    requestID = id
    review = nil
    message = nil
    issue = nil
    return id
  }

  func finish(id: UUID, result: CoreCompletion) {
    guard requestID == id else { return }
    requestID = nil
    guard case .sourceAccessSettings(let outcome) = result.output else {
      message = "The settings operation was cancelled."
      return
    }
    switch outcome {
    case .read(let read):
      capture(read)
    case .preview(let validated):
      if validated.hasChanges {
        review = .init(id: id, preview: validated)
      } else {
        message = "The profile already matches the saved settings."
      }
    case .saved(let read, let reset):
      message = reset ? "Source access settings reset." : "Source access settings saved."
      capture(read)
    case .failed(let error):
      issue = error
      requiresReload = error.requiresReload
    }
  }

  private func capture(_ read: SourceAccessSettingsRead) {
    location = read.location
    switch read.document {
    case .success(let document):
      self.document = document
      draft = document.initialDraft
      requiresReload = false
    case .failure(let error):
      issue = error
      requiresReload = true
    }
  }
}

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
  private(set) var form: SourceAccessProfileDraft?
  private var initialForm: SourceAccessProfileDraft?
  private(set) var repairDraft: String?
  private(set) var review: SourceAccessSettingsReview?
  private(set) var requestID: UUID?
  private(set) var issue: SourceAccessSettingsIssue?
  private(set) var message: String?
  private(set) var requiresReload = false

  var isBusy: Bool { requestID != nil }
  var canActOnDocument: Bool { document != nil && !isBusy && !requiresReload }
  var hasDraftChanges: Bool {
    if let form { return form != initialForm }
    if let repairDraft, let original = document?.originalText {
      return !repairDraft.utf8.elementsEqual(original.utf8)
    }
    return false
  }
  var canPreview: Bool { canActOnDocument && (form != nil || repairDraft != nil) }
  var canReset: Bool { canActOnDocument && document?.isPresent == true }

  func setForm(_ value: SourceAccessProfileDraft) {
    guard !isBusy, form?.id == value.id, form != value else { return }
    form = value
    draftDidChange()
  }

  func setRepairDraft(_ value: String) {
    guard !isBusy, let repairDraft, !repairDraft.utf8.elementsEqual(value.utf8) else { return }
    self.repairDraft = value
    draftDidChange()
  }

  func bytesForPreview() -> Data? {
    if !hasDraftChanges, let original = document?.editor.original { return original }
    if let repairDraft { return Data(repairDraft.utf8) }
    do {
      return try form?.encoded()
    } catch {
      issue = .draftUnavailable
      return nil
    }
  }

  private func draftDidChange() {
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
      requiresReload = false
      form = nil
      repairDraft = nil
      if document.issue != nil {
        repairDraft = document.originalText
      } else if let profile = document.profile, let text = document.originalText {
        form = SourceAccessProfileDraft(yaml: text, profile: profile)
        if form == nil { issue = .draftUnavailable }
      } else {
        form = SourceAccessProfileDraft()
      }
      initialForm = form
    case .failure(let error):
      issue = error
      requiresReload = true
    }
  }
}

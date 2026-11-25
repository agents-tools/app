import Foundation

extension AppModel {
  func reloadSourceAccessSettings() {
    let actions = actions
    startSourceAccessSettingsOperation(title: "Read source access settings") {
      actions.readSourceAccessSettings()
    }
  }

  func previewSourceAccessSettings(reset: Bool = false) {
    let settings = sourceAccessSettings
    guard settings.canPreview, let editor = settings.document?.editor,
      !reset || settings.canReset
    else { return }
    let bytes = reset ? nil : Data(settings.draft.utf8)
    let actions = actions
    startSourceAccessSettingsOperation(title: "Preview source access settings") {
      actions.previewSourceAccessSettings(bytes, using: editor)
    }
  }

  func saveSourceAccessSettings(reviewID: UUID) {
    let settings = sourceAccessSettings
    guard settings.canPreview, let editor = settings.document?.editor,
      let review = settings.review, review.id == reviewID
    else { return }
    let preview = review.preview
    let actions = actions
    startSourceAccessSettingsOperation(title: "Save source access settings") {
      actions.saveSourceAccessSettings(preview, using: editor)
    }
  }

  private func startSourceAccessSettingsOperation(
    title: String, work: @escaping @Sendable () -> CoreCompletion
  ) {
    guard !isTerminating, !isApplying, let id = sourceAccessSettings.begin() else { return }
    startOperation(
      title: title, scope: .init(kind: .user, root: home), purpose: .sourceAccessSettings(id),
      work: work)
  }
}

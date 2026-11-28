import AgentsCore
import Foundation
import Testing

@testable import AgentsApp

@MainActor
@Suite("Operator source access settings", .timeLimit(.minutes(1)))
struct SourceAccessSettingsTests {
  private let direct = "version: 1\negress: directAllowed\n"
  private let proxy = "version: 1\negress: proxyOnly\n"

  @Test func saveAndResetRefreshTheSelectedProjectFromTheUserProfile() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let boundary = try FixtureEventBoundary(root: fixture.root)
    defer { boundary.stop() }
    let declaration = try fixture.writeManifest(
      """
      version: 1
      sources:
        tools: {url: https://github.com/example/tools.git}
      """)
    try await boundary.settle(creation: declaration, root: fixture.root)
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    let project = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(project)
    try await settle(model)
    model.page = .sources
    model.selectedItem = try #require(model.snapshot?.sources.first?.id)
    let selection = try #require(model.sourceAccessSelection)
    model.inspectSourceAccess(selection)
    try await settle(model)
    #expect(try model.sourceAccessSession?.inspection?.get().report.provider == .github)

    model.reloadSourceAccessSettings()
    try await settle(model)
    let settings = model.sourceAccessSettings
    let location = try #require(settings.location)
    let user = WorkspaceScope(kind: .user, root: fixture.home)
    #expect(
      location
        == SourceAccessSettingsEditor.settingsURL(
          environment: model.actions.environment(for: user)))
    for scope in [user, project] {
      let reader = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
      #expect(reader.stateDependencies(scope: scope).contains(.entry(location)))
      #expect(reader.read(scope: scope).readDependencies.contains(.entry(location)))
    }
    #expect(settings.document?.isPresent == false)
    #expect(settings.form?.egress == .directAllowed)
    #expect(!settings.canReset)

    var draft = try #require(settings.form)
    draft.egress = .proxyOnly
    settings.setForm(draft)
    model.previewSourceAccessSettings()
    try await settle(model)
    let review = try #require(settings.review)
    #expect(review.preview.profile?.egress == .proxyOnly)
    #expect(!FileManager.default.fileExists(atPath: location.path))
    #expect(model.sourceAccessSelection?.id == selection.id)
    model.saveSourceAccessSettings(reviewID: review.id)
    try await settle(model)

    #expect(try Data(contentsOf: location) == Data(proxy.utf8))
    #expect(settings.document?.profile?.egress == .proxyOnly)
    #expect(model.scope == project)
    #expect(model.sourceAccessSession == nil)
    try await settle(model, inspectingSource: true)
    let refreshed = try #require(model.sourceAccessSelection)
    #expect(refreshed.id != selection.id)
    #expect(refreshed.id.node == selection.id.node)
    #expect(model.sourceAccessSession?.selection == refreshed.id)
    guard case .failure(.access(.egressDenied)) = model.sourceAccessSession?.inspection else {
      Issue.record("The refreshed project did not use the saved proxy-only policy")
      return
    }

    model.previewSourceAccessSettings()
    try await settle(model)
    #expect(settings.review == nil)
    #expect(settings.message == "The profile already matches the saved settings.")
    #expect(try Data(contentsOf: location) == Data(proxy.utf8))

    model.previewSourceAccessSettings(reset: true)
    try await settle(model)
    let reset = try #require(settings.review)
    #expect(reset.preview.profile == nil)
    #expect(try Data(contentsOf: location) == Data(proxy.utf8))
    model.saveSourceAccessSettings(reviewID: reset.id)
    try await settle(model)
    #expect(!FileManager.default.fileExists(atPath: location.path))
    #expect(settings.document?.isPresent == false)
    try await settle(model, inspectingSource: true)
    let restored = try #require(model.sourceAccessSelection)
    #expect(restored.id != refreshed.id)
    #expect(restored.id.node == selection.id.node)
    #expect(model.sourceAccessSession?.selection == restored.id)
    #expect(try model.sourceAccessSession?.inspection?.get().report.provider == .github)
  }

  @Test func malformedProfileOpensForRepairAndOnlyValidatedDraftCanSave() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    let location = SourceAccessSettingsEditor.settingsURL(
      environment: model.actions.environment(for: model.scope))
    try FileManager.default.createDirectory(
      at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
    let malformed = "version: 1\negress: proxyOnly\nfutureOption: {retain: true}\n"
    try Data(malformed.utf8).write(to: location)
    model.reloadSourceAccessSettings()
    try await settle(model)
    let settings = model.sourceAccessSettings
    #expect(settings.document?.issue != nil)
    #expect(settings.document?.isPresent == true)
    #expect(settings.form == nil)
    #expect(settings.repairDraft == malformed)
    #expect(settings.canReset)

    model.previewSourceAccessSettings()
    try await settle(model)
    #expect(settings.review == nil)
    #expect(settings.issue != nil)
    #expect(try Data(contentsOf: location) == Data(malformed.utf8))

    settings.setRepairDraft(proxy)
    model.previewSourceAccessSettings()
    try await settle(model)
    let superseded = try #require(settings.review)
    settings.setRepairDraft(direct)
    model.previewSourceAccessSettings()
    try await settle(model)
    let current = try #require(settings.review)
    model.saveSourceAccessSettings(reviewID: superseded.id)
    #expect(settings.review?.id == current.id)
    #expect(try Data(contentsOf: location) == Data(malformed.utf8))
    model.saveSourceAccessSettings(reviewID: current.id)
    try await settle(model)
    #expect(try Data(contentsOf: location) == Data(direct.utf8))
    #expect(settings.document?.issue == nil)
    #expect(settings.document?.profile?.egress == .directAllowed)
    #expect(settings.repairDraft == nil)
    #expect(settings.form?.egress == .directAllowed)
  }

  @Test func aConflictPreservesTheDraftAndRequiresReload() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    model.reloadSourceAccessSettings()
    try await settle(model)
    let settings = model.sourceAccessSettings
    var draft = try #require(settings.form)
    draft.egress = .proxyOnly
    settings.setForm(draft)
    model.previewSourceAccessSettings()
    try await settle(model)
    let review = try #require(settings.review)
    let other = try SourceAccessSettingsEditor(
      environment: model.actions.environment(for: model.scope))
    try other.save(other.preview(Data(direct.utf8)))

    model.saveSourceAccessSettings(reviewID: review.id)
    try await settle(model)
    #expect(try Data(contentsOf: other.url) == Data(direct.utf8))
    #expect(settings.review == nil)
    #expect(settings.form?.egress == .proxyOnly)
    #expect(settings.requiresReload)
    #expect(!settings.canPreview)
    guard case .core(.changed(let location)) = settings.issue else {
      Issue.record("Expected Core's stale preview error")
      return
    }
    #expect(location == other.url)

    model.reloadSourceAccessSettings()
    #expect(!settings.isBusy)
    #expect(settings.form?.egress == .proxyOnly)

    model.reloadSourceAccessSettings(discardDraft: true)
    try await settle(model)
    #expect(settings.form?.egress == .directAllowed)
    #expect(settings.document?.profile?.egress == .directAllowed)
    #expect(settings.canPreview)
    settings.setForm(draft)
    #expect(settings.form?.egress == .directAllowed)
  }

  @Test func structuredDraftPreservesFieldsAndPreviewsTheOriginalWhenUnedited() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    let location = SourceAccessSettingsEditor.settingsURL(
      environment: model.actions.environment(for: model.scope))
    try FileManager.default.createDirectory(
      at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = """
      # Operator note
      version: !!int "1"
      egress: directAllowed
      providers: [{host: code.example.test, port: !!int "08443", provider: gitlab}]
      mirrors:
        - source: {host: gitlab.com}
          base: https://archives.example.test/gitlab
          flavor: gitlab
          supportsQualifiedGitLabRefs: true
          requiresExactArchiveBytes: false
      credentials:
        - route: direct
          host: code.example.test
          port: 8443
          path: /team/package
          environmentVariable: !!str NO
          exportable: false
          validationEndpoint: https://code.example.test:8443/api/v4/user
        - route: mirror
          host: archives.example.test
          environmentVariable: ARCHIVE_TOKEN
      """
    let originalBytes = Data(original.utf8)
    try originalBytes.write(to: location)
    model.reloadSourceAccessSettings()
    try await settle(model)
    let settings = model.sourceAccessSettings
    let profile = try #require(settings.document?.profile)
    var draft = try #require(settings.form)
    #expect(draft.providers.first?.authority.port == "08443")
    #expect(draft.mirrors.first?.source.port == "")
    #expect(draft.mirrors.first?.requiresExactArchiveBytes == false)
    #expect(draft.credentials.first?.exportable == false)
    #expect(draft.credentials.last?.exportable == nil)
    #expect(draft.credentials.last?.path == "")
    #expect(draft.credentials.last?.validationEndpoint == "")
    #expect(!settings.hasDraftChanges)
    #expect(settings.bytesForPreview() == originalBytes)

    draft.egress = .proxyOnly
    settings.setForm(draft)
    model.reloadSourceAccessSettings()
    #expect(!settings.isBusy)
    #expect(settings.form == draft)

    model.previewSourceAccessSettings()
    try await settle(model)
    let review = try #require(settings.review)
    #expect(review.preview.profile?.egress == .proxyOnly)
    #expect(review.preview.profile?.providers == profile.providers)
    #expect(review.preview.profile?.mirrors == profile.mirrors)
    #expect(review.preview.profile?.credentials == profile.credentials)
    #expect(try Data(contentsOf: location) == originalBytes)
    model.saveSourceAccessSettings(reviewID: review.id)
    try await settle(model)
    #expect(settings.document?.profile == review.preview.profile)
    #expect(settings.form?.credentials.first?.exportable == false)
    #expect(settings.form?.credentials.last?.exportable == nil)
    #expect(!settings.hasDraftChanges)
  }

  @Test func nonUTF8ProfileCanOnlyBeResetExplicitly() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    let location = SourceAccessSettingsEditor.settingsURL(
      environment: model.actions.environment(for: model.scope))
    try FileManager.default.createDirectory(
      at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data([0xFF, 0xFE, 0xFF])
    try original.write(to: location)
    model.reloadSourceAccessSettings()
    try await settle(model)
    let settings = model.sourceAccessSettings
    #expect(settings.document?.issue != nil)
    #expect(settings.form == nil)
    #expect(settings.repairDraft == nil)
    #expect(!settings.canPreview)
    #expect(settings.canReset)
    model.previewSourceAccessSettings(reset: true)
    try await settle(model)
    #expect(settings.review != nil)
    #expect(try Data(contentsOf: location) == original)
  }

  @Test func externalProfileReplacementRefreshesAnUnchangedRoute() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let boundary = try FixtureEventBoundary(root: fixture.root)
    defer { boundary.stop() }
    try fixture.writeManifest(
      """
      version: 1
      sources:
        tools: {url: https://github.com/example/tools.git}
      """)
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    let location = SourceAccessSettingsEditor.settingsURL(
      environment: model.actions.environment(for: model.scope))
    try FileManager.default.createDirectory(
      at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(direct.utf8).write(to: location)
    try await boundary.settle(creation: location, root: fixture.root)
    model.select(.init(kind: .project, root: fixture.project))
    try await settle(model)
    model.page = .sources
    model.selectedItem = try #require(model.snapshot?.sources.first?.id)
    let selection = try #require(model.sourceAccessSelection)
    model.inspectSourceAccess(selection)
    try await settle(model)
    let before = try #require(model.sourceAccessSession?.inspection).get()

    try fixture.externalWrite(direct, to: location, atomic: true)
    let runtime = model.actions.environment(for: model.scope)
    let probe = selection.inspect(environment: runtime)
    guard case .sourceAccessInspection(.success(let after)) = probe.output else {
      Issue.record("The external replacement did not produce an access report")
      return
    }
    #expect(after.report == before.report)
    #expect(after.settingsFingerprint != before.settingsFingerprint)
    let validation = selection.validate(
      inspection: before, environment: runtime, admission: OperationAdmission())
    guard case .sourceAccessValidation(.failure(.inputsChanged)) = validation.output else {
      Issue.record("Validation accepted the previous profile generation")
      return
    }

    for _ in 0..<1000 {
      if model.sourceAccessSelection?.id != selection.id { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    try await settle(model)
    #expect(model.sourceAccessSelection?.id != selection.id)
    #expect(model.sourceAccessSession == nil)
    try await settle(model, inspectingSource: true)
    let refreshed = try #require(model.sourceAccessSelection)
    #expect(refreshed.id.node == selection.id.node)
    #expect(model.sourceAccessSession?.selection == refreshed.id)
    #expect(
      try model.sourceAccessSession?.inspection?.get().settingsFingerprint
        == after.settingsFingerprint)
  }

  private func makeModel(_ fixture: TestFixture) -> AppModel {
    AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
  }

  private func settle(_ model: AppModel, inspectingSource: Bool = false) async throws {
    for _ in 0..<1000 {
      // The inspector submits a new request whenever the model supplies a fresh selection ID.
      if inspectingSource, let selection = model.sourceAccessSelection {
        model.inspectSourceAccess(selection)
      }
      if model.operations.isEmpty, !model.readsStale { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(model.operations.isEmpty && !model.readsStale)
  }
}

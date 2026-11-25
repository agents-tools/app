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
    try fixture.writeManifest(
      """
      version: 1
      sources:
        tools: {url: https://github.com/example/tools.git}
      """)
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
    #expect(settings.draft == direct)
    #expect(!settings.canReset)

    settings.setDraft(proxy)
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
    let refreshed = try #require(model.sourceAccessSelection)
    #expect(refreshed.id != selection.id)
    model.inspectSourceAccess(refreshed)
    try await settle(model)
    guard case .failure(.access(.egressDenied)) = model.sourceAccessSession?.inspection else {
      Issue.record("The refreshed project did not use the saved proxy-only policy")
      return
    }

    model.previewSourceAccessSettings()
    try await settle(model)
    #expect(settings.review == nil)
    #expect(model.sourceAccessSelection?.id == refreshed.id)

    model.previewSourceAccessSettings(reset: true)
    try await settle(model)
    let reset = try #require(settings.review)
    #expect(reset.preview.profile == nil)
    #expect(try Data(contentsOf: location) == Data(proxy.utf8))
    model.saveSourceAccessSettings(reviewID: reset.id)
    try await settle(model)
    #expect(!FileManager.default.fileExists(atPath: location.path))
    #expect(settings.document?.isPresent == false)
    #expect(model.sourceAccessSelection?.id != refreshed.id)
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
    let malformed = "version: 1\negress: wrong\n"
    try Data(malformed.utf8).write(to: location)
    model.reloadSourceAccessSettings()
    try await settle(model)
    let settings = model.sourceAccessSettings
    #expect(settings.document?.issue != nil)
    #expect(settings.document?.isPresent == true)
    #expect(settings.draft == malformed)
    #expect(settings.canReset)

    model.previewSourceAccessSettings()
    try await settle(model)
    #expect(settings.review == nil)
    #expect(settings.issue != nil)
    #expect(try Data(contentsOf: location) == Data(malformed.utf8))

    settings.setDraft(proxy)
    model.previewSourceAccessSettings()
    try await settle(model)
    let superseded = try #require(settings.review)
    settings.setDraft(direct)
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
  }

  @Test func aConflictPreservesTheDraftAndRequiresReload() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    model.reloadSourceAccessSettings()
    try await settle(model)
    let settings = model.sourceAccessSettings
    settings.setDraft(proxy)
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
    #expect(settings.draft == proxy)
    #expect(settings.requiresReload)
    #expect(!settings.canPreview)
    guard case .core(.changed(let location)) = settings.issue else {
      Issue.record("Expected Core's stale preview error")
      return
    }
    #expect(location == other.url)

    model.reloadSourceAccessSettings()
    try await settle(model)
    #expect(settings.draft == direct)
    #expect(settings.document?.profile?.egress == .directAllowed)
    #expect(settings.canPreview)
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
  }

  private func makeModel(_ fixture: TestFixture) -> AppModel {
    AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
  }

  private func settle(_ model: AppModel) async throws {
    for _ in 0..<1000 {
      if model.operations.isEmpty, !model.readsStale { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(model.operations.isEmpty && !model.readsStale)
  }
}

import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

@Suite("Source access", .timeLimit(.minutes(1)))
struct SourceAccessTests {
  private let manifest = """
    version: 1
    sources:
      local: {path: ./content}
      remote: {url: https://code.example.invalid/team/repo.git}
    """

  @Test(arguments: [true, false])
  func uninstalledAliasUsesWorkspacePolicyAndTrustedMirror(user: Bool) throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(manifest, user: true)
    try fixture.writeManifest(manifest)
    let scope = WorkspaceScope(
      kind: user ? .user : .project, root: user ? fixture.home : fixture.project)
    let selection = try source("remote", in: scope, fixture: fixture)
    var environment = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
      .environment(for: scope)
    let producer = try SourceAuthority(host: "code.example.invalid")
    let mirror = try SourceAuthority(host: "archive.example.invalid", port: 8443)
    let base = try #require(URL(string: "https://archive.example.invalid:8443/packages"))
    environment.sourceAccess = try .init(
      egress: .proxyOnly, providers: [producer: .github],
      mirrors: [.init(source: producer, base: base, flavor: .github)],
      credentials: [
        .init(
          route: .mirror, authority: mirror, path: "/packages/team/repo", category: .environment
        ) {
          Issue.record("Offline inspection resolved a credential")
          return nil
        }
      ])
    let userPolicy = SourcePolicyOperations.policyURL(scope: .user, environment: environment)
    var projectEnvironment = environment
    projectEnvironment.projectDirectory = fixture.project
    let projectPolicy = SourcePolicyOperations.policyURL(
      scope: .project, environment: projectEnvironment)
    let organizationPolicy = fixture.root.appendingPathComponent("organization-source-policy.yaml")
    environment.organizationSourcePolicyURL = organizationPolicy
    for policy in [userPolicy, projectPolicy, organizationPolicy] {
      try Data("version: 1\n".utf8).write(to: policy)
    }

    let before = try fixture.entries()
    let result = selection.inspect(environment: environment)
    guard case .sourceAccessInspection(.success(let inspection)) = result.output else {
      Issue.record("The declared alias did not produce an access report")
      return
    }
    #expect(inspection.report.effectiveHost == "archive.example.invalid:8443")
    #expect(inspection.report.provider == .github)
    #expect(inspection.report.transport == .archive)
    #expect(inspection.report.credentialSource == .environment)
    #expect(inspection.report.availability == .available)
    #expect(!inspection.mayValidate)
    #expect(
      Set(inspection.policy.layers.map(\.url))
        == Set(
          user
            ? [userPolicy, organizationPolicy] : [userPolicy, projectPolicy, organizationPolicy]))
    #expect(try fixture.entries() == before)

    try Data("version: 1\ndeny: [{http: 'https://archive.example.invalid:8443/packages'}]\n".utf8)
      .write(to: organizationPolicy)
    let blocked = selection.inspect(environment: environment)
    guard case .sourceAccessInspection(.failure(.policyDenied)) = blocked.output else {
      Issue.record("The organization layer did not block the effective mirror")
      return
    }
  }

  @Test func validationChecksAdmissionAndRejectsChangedInputsBeforeCore() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(manifest)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let selection = try source("remote", in: scope, fixture: fixture)
    var environment = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
      .environment(for: scope)
    let authority = try SourceAuthority(host: "code.example.invalid")
    let endpoint = try #require(URL(string: "https://code.example.invalid/api/v3/user"))
    environment.sourceAccess = try .init(
      providers: [authority: .github],
      credentials: [
        .init(route: .direct, authority: authority, validationEndpoint: endpoint) {
          Issue.record("Preflight or cancelled validation resolved a credential")
          return nil
        }
      ])
    guard
      case .sourceAccessInspection(.success(let inspection)) =
        selection.inspect(environment: environment).output
    else {
      Issue.record("Expected an offline report")
      return
    }

    let cancelled = OperationAdmission()
    cancelled.cancel()
    #expect(
      selection.validate(
        inspection: inspection, environment: environment, admission: cancelled
      ).disposition == .cancelled)

    let policy = SourcePolicyOperations.policyURL(scope: .project, environment: environment)
    try Data("version: 1\n".utf8).write(to: policy)
    let changedPolicy = selection.validate(
      inspection: inspection, environment: environment, admission: OperationAdmission())
    guard case .sourceAccessValidation(.failure(.inputsChanged)) = changedPolicy.output else {
      Issue.record("Validation reused a report after its policy changed")
      return
    }
    try FileManager.default.removeItem(at: policy)

    try fixture.writeManifest(
      manifest.replacingOccurrences(of: "/team/repo", with: "/other/repo"))
    let changedDeclaration = selection.validate(
      inspection: inspection, environment: environment, admission: OperationAdmission())
    guard case .sourceAccessValidation(.failure(.inputsChanged)) = changedDeclaration.output else {
      Issue.record("Validation reused a report after its declaration changed")
      return
    }
  }

  @Test func aliasWithWhitespaceCannotResolveToAnotherDeclaration() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(manifest + "\n  ' remote ': {path: ./other}\n")
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let selection = try source(" remote ", in: scope, fixture: fixture)
    let environment = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
      .environment(for: scope)
    guard
      case .sourceAccessInspection(.failure(.unsupportedAlias)) =
        selection.inspect(environment: environment).output
    else {
      Issue.record("The alias was interpreted as another source selector")
      return
    }
  }

  @Test @MainActor func reselectingAnAliasCreatesANewSessionAndClosingClearsIt() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let boundary = try FixtureEventBoundary(root: fixture.root)
    defer { boundary.stop() }
    let declaration = try fixture.writeManifest(manifest)
    try await boundary.settle(creation: declaration, root: fixture.root)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    defer { _ = model.requestTermination() }
    model.select(.init(kind: .project, root: fixture.project))
    try await finishOperations(in: model)
    let snapshot = try #require(model.snapshot)
    model.page = .sources
    let local = try #require(snapshot.sources.first { $0.title == "local" })
    let remote = try #require(snapshot.sources.first { $0.title == "remote" })

    model.selectedItem = remote.id
    let selection = try #require(model.sourceAccessSelection)
    model.inspectSourceAccess(selection)
    let original = try #require(model.sourceAccessSession)
    let originalAdmission = try #require(
      model.operations.values.first { operation in
        if case .sourceAccessInspection(let id) = operation.purpose { return id == selection.id }
        return false
      }?.admission)

    model.selectedItem = local.id
    #expect(model.sourceAccessSession == nil)
    #expect(!originalAdmission.begin())
    model.inspectSourceAccess(selection)
    #expect(model.sourceAccessSession == nil)

    model.selectedItem = remote.id
    model.inspectSourceAccess(selection)
    #expect(model.sourceAccessSession == nil)
    let reselected = try #require(model.sourceAccessSelection)
    model.inspectSourceAccess(reselected)
    let current = try #require(model.sourceAccessSession)
    #expect(current.selection != original.selection)
    try await finishOperations(in: model)
    #expect(model.sourceAccessSession?.selection == current.selection)
    #expect(
      try model.sourceAccessSession?.inspection?.get().report.effectiveHost
        == "code.example.invalid")

    model.setInspectorVisible(false)
    #expect(model.sourceAccessSession == nil)
    model.inspectSourceAccess(reselected)
    #expect(model.sourceAccessSession == nil)
  }

  private func source(_ alias: String, in scope: WorkspaceScope, fixture: TestFixture)
    throws -> SourceAccessSelection
  {
    let result = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
      .read(scope: scope)
    let snapshot = try #require(result.snapshot)
    #expect(snapshot.inspection.sources.isEmpty)
    let item = try #require(snapshot.sources.first { $0.title == alias })
    return try #require(
      SourceAccessSelection(
        snapshot: snapshot, node: item.id, presentation: UUID()))
  }

  @MainActor private func finishOperations(in model: AppModel) async throws {
    for _ in 0..<1000 {
      if model.operations.isEmpty { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Source operation did not finish")
  }
}

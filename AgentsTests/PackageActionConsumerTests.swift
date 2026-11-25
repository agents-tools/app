import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

@Suite("Package action consumer", .timeLimit(.minutes(1)))
struct PackageActionConsumerTests {
  @Test func updateReviewCarriesDisabledActionsAndRuntimeBindingsThroughApply() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      """
      version: 1
      lifecycle:
        pre-update:
          - type: command
            run: exit 99
      """)
    var environment = fixture.environment
    environment["APM_NO_SCRIPTS"] = "1"
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let actions = CoreActions(home: fixture.home, processEnvironment: environment)
    let request = UpdateRequest(
      operation: .edit([
        .insertComponent(
          .mcpServer(
            name: "fixture",
            transport: .stdio(
              .init(
                executable: "fixture-command",
                environment: [
                  "TOKEN": .secret("FixtureInput")
                ])), agents: [.codex]), into: .root, at: .last)
      ]))
    let proposal = UpdateProposal(
      id: UUID(), scope: scope, title: "Update", request: request, intent: .update)
    let before = try fixture.entries()
    let prepared = actions.preview(proposal)
    guard case .packageUpdatePreview(let id, let reviewed) = prepared.output else {
      Issue.record("Expected a package review. \(prepared.diagnostics.map(\.message))")
      return
    }
    #expect(id == proposal.id)
    #expect(reviewed.scope == scope)
    #expect(reviewed.report.components.flatMap(\.requiredBindings) == ["FixtureInput"])
    #expect(
      reviewed.lifecycle.actions.contains {
        $0.source.authority == .project && $0.event == .preUpdate && $0.withheld == .disabled
      })
    #expect(try fixture.entries() == before)
    let result = await reviewed.apply(
      proposal.title,
      EphemeralBindings(values: [
        "FixtureInput": Data("fixture-value".utf8)
      ]))
    #expect(
      result.updateTerminal?.disposition == .committed, "\(result.diagnostics.map(\.message))")
    #expect(
      result.updateTerminal?.packageActions.contains {
        $0.action.source.authority == .project && $0.disposition == .withheld && !$0.dispatched
      } == true)
  }

  @Test func yamlReviewRejectsAnEditedBaselineAndDoesNotPublish() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let originalText = """
      version: 1
      # Retain this setting.
      defaultAgents: [codex]
      lifecycle:
        pre-install:
          - type: command
            run: exit 99
      """
    try fixture.writeManifest(originalText)
    let original = try DeclarationDocument(
      bytes: Array(originalText.utf8), identity: DocumentIdentity("fixture"))
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let environment = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    let editable = try PackageActionYAML.text(for: original.declaration.lifecycle)
    let proposed = editable.replacingOccurrences(of: "99", with: "98")
    let before = try fixture.entries()
    let review = try PackageActionYAML.preview(
      proposed, replacing: original, scope: scope, environment: environment)
    let proposedDocument = String(decoding: review.documentChange.bytes, as: UTF8.self)
    #expect(proposedDocument.contains("# Retain this setting."))
    #expect(proposedDocument.contains("exit 98"))
    #expect(try fixture.entries() == before)
    #expect(throws: CoreError.self) {
      try PackageActionYAML.preview(
        proposed + "\ndefaultAgents: []\n", replacing: original, scope: scope,
        environment: environment)
    }
    try fixture.writeManifest(originalText + "\n# External change\n")
    #expect(throws: CoreError.self) {
      try PackageActionYAML.preview(
        proposed, replacing: original, scope: scope, environment: environment)
    }
  }

  @Test func storedAccessCanBeRevokedWhenTheProjectFolderIsGone() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      """
      version: 1
      lifecycle:
        post-install:
          - type: command
            run: exit 99
      """)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let environment = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    let review = try LifecycleOperations.reviewEnable(environment: environment)
    let enabled = await CoreActions.enablePackageActions(review, scope: scope)
    #expect(enabled.disposition == .completed, "\(enabled.diagnostics.map(\.message))")
    let grant = try #require(LifecycleOperations.storedTrust(environment: environment).first)
    #expect(grant.digest == review.enablement.digest)
    try FileManager.default.removeItem(at: fixture.project)
    let revoked = CoreActions.revokePackageActions(
      grant.project, scope: scope, environment: environment)
    #expect(revoked.disposition == .completed)
    let record = try #require(LifecycleOperations.storedTrust(environment: environment).first)
    #expect(record.project == grant.project)
    #expect(record.digest == nil)
    #expect(record.revision > grant.revision)
    #expect(!FileManager.default.fileExists(atPath: fixture.project.path))
  }
}

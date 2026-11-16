import AgentsCore
import AgentsManifest
import Foundation
import Testing

@testable import AgentsApp

struct ManifestDraftTests {
  @Test func allComponentDraftsUseCoreValidationAndLeaveTheAuthorDocumentUntouched() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      """
      # Keep the author's comment.
      version: 1
      sources:
        local:
          path: ./content
      """)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let store = StateStore(
      scope: .project,
      environment: .init(
        projectDirectory: fixture.project, homeDirectory: fixture.home,
        environment: fixture.environment))
    let document = try #require(try store.loadManifest())
    let before = try fixture.entries()
    for kind in DeclaredComponentKind.allCases {
      var draft = ManifestDraft(scope: scope, document: document)
      draft.component.kind = kind
      draft.component.name = "example"
      draft.component.source = "local"
      draft.component.description = "A fixture declaration"
      draft.component.prompt = .literal("Describe the change.")
      draft.component.transport = .stdio(.init(executable: "fixture-command"))
      draft.component.run = .init(executable: "fixture-command")
      draft.component.languages = [".swift": "swift"]
      draft.component.rules = [.ask(.read, "**")]
      draft.component.patterns = ["cache/**"]
      draft.component.path = "plugin"
      draft.component.agents = []
      draft.component.condition = .init(platforms: [])
      draft.component.native = [
        "codex": ["exact": .decimal("1.234567890123456789"), "unset": .null]
      ]
      let result = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
        .validate(
          .init(
            id: draft.id, document: document, edits: draft.edits(home: fixture.home), scope: scope))
      #expect(
        result.disposition == .completed,
        "Core rejected \(kind.rawValue): \(result.diagnostics.map(\.message))")
      let change = try document.preparing(draft.edits(home: fixture.home))
      #expect(
        String(decoding: change.bytes, as: UTF8.self).contains("# Keep the author's comment."))
      #expect(String(decoding: change.bytes, as: UTF8.self).contains("1.234567890123456789"))
      #expect(try fixture.entries() == before)
    }
  }

  @Test func structuralDraftUsesExactDocumentNodesAndPreservesConditions() throws {
    let document = try DeclarationDocument(
      bytes: Array(
        """
        version: 1
        components:
          - kind: ignore
            name: cache
            patterns: [cache/**]
            condition: {agents: []}
        groups:
          shared: {}
        """.utf8), identity: .init("fixture"))
    var draft = ManifestDraft(
      scope: .init(kind: .project, root: URL(fileURLWithPath: "/fixture")), document: document)
    draft.kind = .structure
    let componentNode: NodeID = try #require(document.node(at: "/components/0"))
    draft.structuralNode = componentNode
    let groupNode: NodeID = try #require(document.node(at: "/groups/0"))
    draft.destinationGroup = groupNode
    let moved = try document.preparing(draft.edits(home: draft.scope.root)).expectedDeclaration
    #expect(moved.components.isEmpty)
    let component = try #require(moved.groups.first?["components"]?.elements?.first?.record)
    #expect(component["condition"]?.record?["agents"]?.elements == [])
    draft.structuralAction = .remove
    #expect(
      try document.preparing(draft.edits(home: draft.scope.root)).expectedDeclaration.components
        .isEmpty)
  }

  @Test func defaultsAndSourceIntentPreserveOmissionEmptyAndRequirementIdentity() throws {
    let document = try DeclarationDocument(
      bytes: Array("version: 1\n".utf8), identity: .init("fixture"))
    let scope = WorkspaceScope(kind: .project, root: URL(fileURLWithPath: "/fixture"))
    var draft = ManifestDraft(scope: scope, document: document)
    draft.kind = .defaults
    draft.defaultAgents = []
    #expect(
      try document.preparing(draft.edits(home: scope.root)).expectedDeclaration.defaultAgents == [])
    draft.defaultAgents = nil
    #expect(
      try document.preparing(draft.edits(home: scope.root)).expectedDeclaration.defaultAgents == nil
    )
    draft.kind = .source
    draft.sourceAlias = "rules"
    draft.sourceKind = .git
    draft.sourceLocation = "https://example.com/team/rules.git"
    draft.requirement = .range(from: "1.2.0", to: "2.0.0")
    let ir = try document.preparing(draft.edits(home: scope.root)).expectedDeclaration
    guard case .requirement(let requirement) = ir.sources.first?["requirement"] else {
      Issue.record("Missing typed source requirement")
      return
    }
    let expected = try SourceRequirement.range(from: "1.2.0", to: "2.0.0").canonicalized()
    #expect(try requirement.canonicalized() == expected)
  }
}

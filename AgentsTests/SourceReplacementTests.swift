import AgentsCore
import AgentsManifest
import Foundation
import SwiftUI
import Testing

@testable import AgentsApp

@Suite("Captured source replacement", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SourceReplacementTests {
  @Test func blockSkillPathEditsPreviewReprepareApplyAndReadBack() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let boundary = try FixtureEventBoundary(root: f.root)
    defer { boundary.stop() }
    let source = f.root.appendingPathComponent("team")
    try write(
      "---\nname: demo\ndescription: Demo\n---\nDemo\n",
      to: source.appendingPathComponent("skills/demo/SKILL.md"))
    try f.writeManifest(
      """
      # Preserve the authored block mapping.
      version: 1
      defaultAgents: [codex]
      sources:
        team: {path: "\(source.path)"}
      components:
        - kind: skills
          source: team
          select: [demo]
          mode: link
      """)
    try await boundary.settle(creation: manifest(f), root: f.root)
    let model = try await loaded(f)
    defer { _ = model.requestTermination() }
    model.selectedItem = try #require(model.snapshot?.components.first?.id)
    model.editSelectedDeclaration()
    let draftID = try #require(model.manifestDraft?.id)
    var skill = try #require(model.manifestDraft?.component.skills)
    #expect(skill.path == nil && skill.mode == .link)
    let editor = SkillDraftEditor(value: Binding(get: { skill }, set: { skill = $0 }))
    editor.value.path = "."
    model.manifestDraft?.component.skills = skill
    let before = try f.entries()
    try await review(model)
    #expect(model.manifestDraft?.id == draftID)
    #expect(try f.entries() == before)
    try await apply(model)
    guard
      case .skills(let alias, let installed) = model.snapshot?.inspection.declaration?.components
        .first
    else {
      Issue.record("Expected the edited skill declaration")
      return
    }
    #expect(alias == "team" && installed.path == "." && installed.mode == .link)
    #expect(installed.select == .names(["demo"]))
    let text = try String(contentsOf: manifest(f), encoding: .utf8)
    #expect(text.contains("# Preserve the authored block mapping."))
    #expect(text.contains("- kind: skills"))
    let parsed = try DeclarationDocument(bytes: Array(text.utf8), identity: .init("readback"))
    #expect(parsed.declaration == model.snapshot?.document?.declaration)
    #expect(model.snapshot?.inspection.deployments.allSatisfy { $0.status == .current } == true)
  }

  @Test func sourceRenameAndSameAliasDefinitionEditRetainIndependentReferences() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let boundary = try FixtureEventBoundary(root: f.root)
    defer { boundary.stop() }
    let original = f.root.appendingPathComponent("team")
    let replacement = f.root.appendingPathComponent("replacement")
    for directory in [original, replacement] {
      try write(
        "---\nname: demo\ndescription: Demo\n---\nDemo\n",
        to: directory.appendingPathComponent("skills/demo/SKILL.md"))
      let executable = directory.appendingPathComponent("bin/fixture")
      try write("Fixture bytes; never execute\n", to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let cwd = f.root.appendingPathComponent("workspace")
    try write("Working directory\n", to: cwd.appendingPathComponent("cwd/config.txt"))
    try f.writeManifest(
      """
      version: 1
      defaultAgents: [codex]
      sources:
        team: {path: "\(original.path)"}
        workspace: {path: "\(cwd.path)"}
      components:
        - kind: skills
          source: team
          select: [demo]
          mode: link
        - kind: mcpServer
          name: fixture
          transport:
            kind: stdio
            executable: bin/fixture
            executableSource: team
            workingDirectory: {path: cwd, source: workspace}
      """)
    try await boundary.settle(creation: manifest(f), root: f.root)
    let model = try await loaded(f)
    defer { _ = model.requestTermination() }
    model.selectedItem = try #require(model.snapshot?.sources.first { $0.title == "team" }?.id)
    let sourceNode = model.selectedItem
    model.editSelectedDeclaration()
    let id = try #require(model.manifestDraft?.id)
    #expect(model.manifestDraft?.replacingNode == sourceNode)
    model.manifestDraft?.sourceAlias = "renamed"
    let edits = try #require(model.manifestDraft).edits(home: f.home)
    try #require(edits.count == 1)
    guard case .replaceSource(let node, let value) = edits[0] else {
      Issue.record("Existing source must submit one Core replacement intent")
      return
    }
    #expect(node == sourceNode && value.name == "renamed")
    try await review(model)
    #expect(model.manifestDraft?.id == id)
    try await apply(model)
    try references(model)
    model.closeUpdateReview()
    model.selectedItem = try #require(model.snapshot?.sources.first { $0.title == "renamed" }?.id)
    model.editSelectedDeclaration()
    model.manifestDraft?.sourceLocation = replacement.path
    try await review(model)
    try await apply(model)
    try references(model)
    #expect(
      model.snapshot?.inspection.declaration?.sources["renamed"]?.location == replacement.path)
    #expect(model.snapshot?.inspection.declaration?.sources["workspace"]?.location == cwd.path)
  }

  @Test func changedDeclarationInvalidatesTheCapturedSourceReplacement() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let boundary = try FixtureEventBoundary(root: f.root)
    defer { boundary.stop() }
    try f.writeManifest("version: 1\ndefaultAgents: []\nsources: {team: {path: ./content}}\n")
    try await boundary.settle(creation: manifest(f), root: f.root)
    let model = try await loaded(f)
    defer { _ = model.requestTermination() }
    model.selectedItem = try #require(model.snapshot?.sources.first?.id)
    model.editSelectedDeclaration()
    model.manifestDraft?.sourceAlias = "renamed"
    let draft = try #require(model.manifestDraft)
    try await review(model)
    let text = try String(contentsOf: manifest(f), encoding: .utf8)
    try f.externalWrite("# Genuine external edit\n" + text, to: manifest(f), atomic: true)
    for _ in 0..<500 {
      if model.manifestDraft?.isStale == true
        && model.snapshot?.document?.digest != draft.document?.digest
      {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.manifestDraft?.id == draft.id)
    #expect(model.manifestDraft?.isStale == true)
    #expect(model.manifestDraft?.canReview(against: model.snapshot) == false)
    let rejected = CoreActions(home: f.home, processEnvironment: f.environment).preview(
      .init(
        id: UUID(), scope: draft.scope, title: "Captured source edit",
        request: draft.updateRequest(home: f.home)))
    #expect(rejected.disposition == .failed)
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.isEmpty)
    model.closeUpdateReview()
    model.previewDraft()
    #expect(model.updateSession == nil)
    #expect(
      try String(contentsOf: manifest(f), encoding: .utf8) == "# Genuine external edit\n" + text)
  }

  @Test func newSourcesUpsertAndReplacementKeepsCoreSourceKindModeAdmission() throws {
    for mode in ["link", "edit"] {
      let document = try DeclarationDocument(
        bytes: Array(
          """
          version: 1
          sources: {team: {path: ./content}}
          components: [{kind: skills, source: team, mode: \(mode)}]
          """.utf8), identity: .init("source-mode"))
      let scope = WorkspaceScope(kind: .project, root: URL(fileURLWithPath: "/fixture"))
      var draft = ManifestDraft(scope: scope, document: document)
      let item = try #require(CoreReader.items(document).first { $0.category == "Source" })
      let declaration = Declaration(sources: ["team": .init(kind: .local, location: "./content")])
      draft.load(item, from: declaration)
      draft.sourceKind = .git
      draft.sourceLocation = "https://example.invalid/team.git"
      draft.requirement = .branch("main")
      if mode == "edit" {
        #expect(throws: (any Error).self) { try document.preparing(draft.edits(home: scope.root)) }
      } else {
        let prepared = try document.preparing(draft.edits(home: scope.root))
        #expect(prepared.expectedDeclaration.components.first?["mode"]?.string == mode)
        #expect(prepared.expectedDeclaration.sources.first?.kind == "git")
      }
      #expect(document.declaration.components.first?["mode"]?.string == mode)
      var newSource = ManifestDraft(scope: scope, document: document)
      newSource.kind = .source
      newSource.sourceAlias = "additional"
      newSource.sourceLocation = "./more"
      guard case .upsertSource = newSource.edits(home: scope.root).first else {
        Issue.record("New source must retain upsert intent")
        return
      }
    }
  }

  private func references(_ model: AppModel) throws {
    let components = try #require(model.snapshot?.inspection.declaration?.components)
    guard case .skills(let alias, _) = components[0],
      case .mcpServer(_, .stdio(let run), _, _, _, _) = components[1]
    else {
      Issue.record("Missing renamed typed references")
      return
    }
    #expect(alias == "renamed" && run.executableSource == "renamed")
    #expect(run.workingDirectory == .init(path: "cwd", source: "workspace"))
  }
  private func loaded(_ f: TestFixture) async throws -> AppModel {
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: f.environment)
    model.select(.init(kind: .project, root: f.project))
    try await idle(model)
    try #require(model.canModify)
    return model
  }
  private func review(_ model: AppModel) async throws {
    model.previewDraft()
    try await idle(model)
    try #require(
      model.updateSession?.stage == .review,
      "Review: \(model.updateSession?.messages.map(\.message) ?? []), stale: \(model.manifestDraft?.isStale ?? false)"
    )
    try #require(model.updateSession?.report != nil)
  }
  private func apply(_ model: AppModel) async throws {
    model.confirmUpdate()
    try await idle(model)
    try #require(
      model.updateRecords.last?.terminal.disposition == .committed,
      "Apply: \(model.updateSession?.messages.map(\.message) ?? [])")
  }
  private func idle(_ model: AppModel) async throws {
    for _ in 0..<600 {
      if model.operations.isEmpty {
        try await Task.sleep(for: .milliseconds(150))
        if model.operations.isEmpty { return }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Owned operation did not finish")
  }
  private func manifest(_ f: TestFixture) -> URL {
    f.project.appendingPathComponent(".agent/agents.yaml")
  }
  private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }
}

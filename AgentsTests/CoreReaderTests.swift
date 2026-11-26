import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

@Suite("Core read projections", .serialized)
struct CoreReaderTests {
  @Test func emptyAndInvalidScopesDoNotCreateState() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let reader = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
    let empty = reader.read(scope: scope)
    #expect(empty.snapshot?.isEmpty == true)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".agent").path)
    )
    #expect(
      !FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".agents").path))

    try fixture.writeManifest("version: 1\ncomponents: [\n")
    let before = try fixture.entries()
    let invalid = reader.read(scope: scope)
    #expect(invalid.snapshot == nil)
    #expect(invalid.diagnostics.contains { $0.message.contains("manifest.") })
    #expect(try fixture.entries() == before)
  }

  @Test func completeDeclarationRetainsSymbolicStructureAndCoreDefaults() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: []
      sources:
        local:
          path: ../content
      components:
        - kind: mcpServer
          name: local-tools
          transport:
            kind: stdio
            executable: fixture-command
          condition:
            agents: []
        - kind: instructions
          sections:
            - name: style
              condition:
                scopes: [project]
          chatgpt:
            explain:
              sections:
                - name: style
      groups:
        common:
          components:
            - kind: command
              name: review
              description: Review the change
              prompt: Review the selected diff
      uses:
        - group: common
      exports: [common]
      """)
    let before = try fixture.entries()
    let result = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
      .read(scope: .init(kind: .project, root: fixture.project))
    let snapshot = try #require(result.snapshot)
    #expect(snapshot.effectiveDefaultAgents.isEmpty)
    #expect(snapshot.sources.first?.title == "local")
    let server = try #require(snapshot.components.first { $0.record.kind == "mcpServer" })
    #expect(server.record["condition"]?.record?["agents"]?.elements == [])
    #expect(snapshot.items.contains { $0.category == "Group Reference" && $0.title == "common" })
    #expect(snapshot.components.contains { $0.title == "review" && $0.container == "common" })
    #expect(snapshot.document?.declaration.exports == ["common"])
    #expect(try fixture.entries() == before)
  }

  @Test func projectOwnInstructionsAreReadFromTheAuthorFile() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: 1\n")
    let directory = fixture.project.appendingPathComponent(".agent/instructions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let author = directory.appendingPathComponent("style.md")
    try Data("---\ndescription: Style rules.\n---\n# Project Style\nKeep changes focused.\n".utf8)
      .write(to: author)
    let before = try fixture.entries()
    let snapshot = try #require(
      CoreReader(home: fixture.home, processEnvironment: fixture.environment)
        .read(scope: .init(kind: .project, root: fixture.project)).snapshot)
    let instruction = try #require(snapshot.ownInstructions?.first)
    #expect(instruction.heading == "Project Style")
    #expect(instruction.description == "Style rules.")
    #expect(instruction.authorFile == author)
    #expect(try fixture.entries() == before)
  }

  @Test func instructionOutputPreservesSharedFilesImportsAndIndependentSectionTargets() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    for name in ["first", "second", "gemini"] {
      _ = try InstructionOperations.initializeInstructions(named: name, environment: runtime)
    }
    let claudeFile = fixture.project.appendingPathComponent(".claude/CLAUDE.md")
    try FileManager.default.createDirectory(
      at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Claude project notes\n".utf8).write(to: claudeFile)
    try fixture.writeManifest(
      """
      version: 1
      components:
        - kind: instructions
          agents: [claude-code, codex, gemini-cli]
          sections:
            - {name: second, condition: {agents: [claude-code, codex]}}
            - {name: first, condition: {agents: [claude-code, codex]}}
            - {name: gemini, condition: {agents: [gemini-cli], scopes: [project]}}
          chatgpt:
            daily:
              sections: [{name: first}, {name: second}]
      """)
    _ = try InstructionOperations.updateInstalled(environment: runtime, apply: true)
    let reader = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let before = try fixture.entries()
    let snapshot = try #require(reader.read(scope: scope).snapshot)
    let mapping = try #require(snapshot.mappings.first { $0.scope == scope })

    let shared = try #require(mapping.targets(for: .codex).first)
    #expect(shared.id == "AGENTS.md")
    #expect(Set(shared.recipients) == [.claudeCode, .codex])
    #expect(shared.sections.map(\.name) == ["second", "first"])
    #expect(mapping.deployment(for: shared, in: snapshot)?.status == .current)
    #expect(mapping.deployment(for: shared, in: snapshot)?.effectiveReaders == nil)

    let forwarding = try #require(
      mapping.targets(for: .claudeCode).first { $0.importedFile != nil })
    #expect(forwarding.id == ".claude/CLAUDE.md")
    #expect(forwarding.importedFile == "../AGENTS.md")
    #expect(forwarding.sections.isEmpty)
    #expect(mapping.importedTarget(for: forwarding)?.sections == shared.sections)
    #expect(mapping.targets(for: .geminiCLI).map(\.id) == ["GEMINI.md"])
    #expect(mapping.targets(for: .geminiCLI).first?.sections.map(\.name) == ["gemini"])
    #expect(mapping.targets(for: .cursor).isEmpty)
    #expect(mapping.prompts["daily"]?.map(\.name) == ["first", "second"])
    #expect(snapshot.mappings.first { $0.scope.kind == .user }?.targets.isEmpty == true)
    #expect(try fixture.entries() == before)

    let declaration = try #require(snapshot.inspection.declaration)
    let item = try #require(snapshot.instructions.first)
    var draft = ManifestDraft(scope: scope, document: snapshot.document)
    draft.load(item, from: declaration)
    let gemini = try #require(
      draft.component.instructions.sectionReferences.firstIndex { $0.name == "gemini" })
    draft.component.instructions.sectionReferences[gemini].condition?.agents = []
    let preview = try UpdateOperations.preview(
      draft.updateRequest(home: fixture.home), scope: .project, environment: runtime)
    let changed = preview.instructions.targets.filter { $0.changed || $0.agentsChanged }
    #expect(changed.map(\.target) == ["GEMINI.md"])
    #expect(changed.first?.after == nil)
    #expect(changed.first?.beforeAgents == [.geminiCLI])
    #expect(preview.instructions.changedPrompts.isEmpty)
    #expect(try fixture.entries() == before)
  }

  @Test func capabilityFilterUsesResolvedRecipientsAndKeepsUnresolvedDeclarations() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    let manifest = """
      version: 1
      defaultAgents: [cursor]
      components:
        - kind: mcpServer
          name: gemini-cli-helper
          agents: [codex]
          transport: {kind: stdio, executable: fixture-command}
      """
    try fixture.writeManifest(manifest)
    let reader = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let unresolved = try #require(reader.read(scope: scope).snapshot)
    #expect(unresolved.components.map(\.title) == ["gemini-cli-helper"])
    #expect(unresolved.resolvedComponents(of: .mcpServer, for: nil).isEmpty)

    _ = try UpdateOperations.withPreparedUpdate(scope: .project, environment: runtime) {
      try $0.apply()
    }
    let before = try fixture.entries()
    let resolved = try #require(reader.read(scope: scope).snapshot)
    let server = try #require(resolved.resolvedComponents(of: .mcpServer, for: .codex).first)
    #expect(server.name == "gemini-cli-helper")
    #expect(resolved.resolvedComponents(of: .mcpServer, for: .geminiCLI).isEmpty)
    #expect(resolved.resolvedComponents(of: .mcpServer, for: .cursor).isEmpty)
    #expect(resolved.inspection.deployments.contains { $0.ownerRecords.contains(server.record) })
    #expect(try fixture.entries() == before)
  }

  @Test func skillInventoryUsesEachRecipientsResolvedInstallationMode() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let source = fixture.home.appendingPathComponent("content")
    for name in ["shared", "editable"] {
      let skill = source.appendingPathComponent("skills/\(name)")
      try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
      try Data("---\nname: \(name)\ndescription: Fixture skill.\n---\nFixture body.\n".utf8)
        .write(to: skill.appendingPathComponent("SKILL.md"))
    }
    try fixture.writeManifest(
      """
      version: 1
      sources: {local: {path: ./content}}
      components:
        - {kind: skills, source: local, select: [shared], agents: [codex], mode: copy}
        - {kind: skills, source: local, select: [shared], agents: [claude-code], mode: link}
        - {kind: skills, source: local, select: [editable], agents: [codex], mode: edit}
      """, user: true)
    let environment = RuntimeEnvironment(
      projectDirectory: fixture.home, homeDirectory: fixture.home, environment: fixture.environment)
    _ = try UpdateOperations.withPreparedUpdate(scope: .user, environment: environment) {
      try $0.apply()
    }

    let scope = WorkspaceScope(kind: .user, root: fixture.home)
    let result = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
      .read(scope: scope)
    let snapshot = try #require(result.snapshot)
    let inventory = try #require(snapshot.inventory)
    #expect(inventory.count == 3)
    let expected: [(String, AgentID, InstallMode)] = [
      ("shared", .codex, .copy), ("shared", .claudeCode, .link), ("editable", .codex, .edit),
    ]
    for (name, agent, mode) in expected {
      let row = try #require(inventory.first { $0.id.name == name && $0.id.agent == agent })
      #expect(row.mode == mode)
      let deployment = try #require(
        snapshot.inspection.deployments.first {
          $0.location.path == row.id.path && $0.recipients == [agent]
        })
      #expect(deployment.ownership == "generated")
      #expect(deployment.status == .current)
      let owner = try #require(
        snapshot.inspection.components.first { deployment.ownerRecords == [$0.record] })
      #expect(owner.name == name && owner.recipients == [agent])
    }
  }

  @Test func orphanResolvedStateIsNotAnEmptyScope() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let directory = fixture.project.appendingPathComponent(".agent")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appendingPathComponent("agents.resolved"))
    let before = try fixture.entries()
    let result = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
      .read(scope: .init(kind: .project, root: fixture.project))
    #expect(result.snapshot == nil)
    #expect(result.diagnostics.contains { $0.message.contains("Missing declaration") })
    #expect(try fixture.entries() == before)
  }
}

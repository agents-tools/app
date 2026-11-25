import AgentsCore
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

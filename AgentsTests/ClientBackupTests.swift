import AgentsCore
import Foundation
import Testing

@testable import AgentsApp

@Suite("Client backups", .timeLimit(.minutes(1)))
@MainActor
struct ClientBackupTests {
  @Test func backsUpTwoClientsInOneActionWithNoProjectsSelected() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let output = try folder("backups", in: fixture.root)
    let codex = try folder(".codex", in: fixture.home)
    let gemini = try folder(".gemini", in: fixture.home)
    try Data("Codex instructions".utf8).write(to: codex.appendingPathComponent("AGENTS.md"))
    try Data("Gemini instructions".utf8).write(to: gemini.appendingPathComponent("GEMINI.md"))
    let model = AppModel(
      home: fixture.home,
      preferences: AppPreferences(defaults: nil, initialProjects: [fixture.project]),
      processEnvironment: fixture.environment)
    model.backupDirectory = output
    model.backupClients = [.codex, .geminiCLI]

    model.backUpSelectedClients()
    try await idle(model)

    #expect(Set(model.backupOutcomes.map(\.client)) == [.codex, .geminiCLI])
    let packages = try model.backupOutcomes.map { outcome in
      let package = try #require(outcome.package)
      let info = try ClientBackups.inspect(package)
      #expect(info.client == outcome.client)
      #expect(info.projects.isEmpty)
      return package
    }
    #expect(Set(packages).count == 2)
  }

  @Test func remappedRestoreWritesOnlyAfterConfirmingTheCurrentPreview() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let output = try folder("backups", in: fixture.root)
    let codex = try folder(".codex", in: fixture.home)
    try Data("User instructions".utf8).write(to: codex.appendingPathComponent("AGENTS.md"))
    let destination = try folder("destination", in: fixture.root)
    let source = fixture.project.appendingPathComponent("AGENTS.md")
    let target = destination.appendingPathComponent("AGENTS.md")
    let archived = Data("Instructions in the package".utf8)
    let current = Data("Current instructions".utf8)
    try archived.write(to: source)
    try current.write(to: target)
    let model = AppModel(
      home: fixture.home,
      preferences: AppPreferences(defaults: nil, initialProjects: [fixture.project]),
      processEnvironment: fixture.environment)
    model.backupDirectory = output
    model.backupClients = [.codex]
    model.backupProjects = [fixture.project.standardizedFileURL]
    model.backUpSelectedClients()
    try await idle(model)
    let package = try #require(model.backupOutcomes.first?.package)
    try current.write(to: source)

    model.openBackupPackage(package)
    try await idle(model)
    let session = try #require(model.restoreSession)
    let original = try #require(session.projects.first)
    #expect(
      session.destinations[original]?.standardizedFileURL == fixture.project.standardizedFileURL)
    model.reviewBackupRestore()
    try await idle(model)
    guard case .review = model.restoreSession?.stage else {
      Issue.record("Expected a preview for the original project")
      return
    }

    model.editBackupDestinations()
    model.mapBackupProject(original, to: destination, sessionID: session.id)
    model.confirmBackupRestore()
    #expect(model.operations.isEmpty)
    #expect(try Data(contentsOf: target) == current)
    #expect(try Data(contentsOf: source) == current)
    model.reviewBackupRestore()
    try await idle(model)
    guard case .review(let review) = model.restoreSession?.stage else {
      Issue.record("Expected a preview for the remapped project")
      return
    }
    #expect(review.rows.contains { $0.kind == .replace && $0.path.hasSuffix("AGENTS.md") })
    #expect(try Data(contentsOf: target) == current)

    model.confirmBackupRestore()
    try await idle(model)
    guard case .restored = model.restoreSession?.stage else {
      Issue.record("Expected restore to complete")
      return
    }
    #expect(try Data(contentsOf: target) == archived)
    #expect(try Data(contentsOf: source) == current)
  }

  private func folder(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func idle(_ model: AppModel) async throws {
    for _ in 0..<1000 {
      if model.operations.isEmpty { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.operations.isEmpty)
  }
}

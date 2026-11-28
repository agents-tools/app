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
    let packages = try model.backupOutcomes.compactMap { outcome -> URL? in
      guard case .created(let package) = outcome.result else { return nil }
      let info = try ClientBackups.inspect(package)
      #expect(info.client == outcome.client)
      #expect(info.projects.isEmpty)
      return package
    }
    #expect(Set(packages).count == 2)
  }

  @Test func reportsAnUnsupportedClientAlongsideASuccessfulBackup() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let codex = try folder(".codex", in: fixture.home)
    try Data("sqlite_home = 42\n".utf8).write(to: codex.appendingPathComponent("config.toml"))
    let gemini = try folder(".gemini", in: fixture.home)
    try Data("Gemini instructions".utf8).write(to: gemini.appendingPathComponent("GEMINI.md"))
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.backupDirectory = try folder("backups", in: fixture.root)
    model.backupClients = [.codex, .geminiCLI]

    model.backUpSelectedClients()
    try await idle(model)

    let codexOutcome = model.backupOutcomes.first { $0.client == .codex }
    let geminiOutcome = model.backupOutcomes.first { $0.client == .geminiCLI }
    guard case .failed(let message) = codexOutcome?.result,
      case .created(let package) = geminiOutcome?.result
    else {
      Issue.record("Expected an unsupported Codex layout and a successful Gemini CLI backup")
      return
    }
    #expect(message == "This client’s data layout is unsupported. Check for an Agents App update.")
    #expect(try ClientBackups.inspect(package).client == .geminiCLI)
  }

  @Test func recommendsAnotherPackageWhenTheSelectedFileIsInvalid() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let package = fixture.root.appendingPathComponent("empty.agentsbackup")
    try Data().write(to: package)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)

    model.openBackupPackage(package)
    try await idle(model)

    #expect(
      model.restoreSession?.message
        == "This backup package is invalid or damaged. Choose another Agents backup.")
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
    guard case .created(let package) = model.backupOutcomes.first?.result else {
      Issue.record("Expected a Codex backup package")
      return
    }
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
    #expect(review.hasChanges)
    #expect(try Data(contentsOf: target) == current)

    let modified = Data("Modified after the preview".utf8)
    try modified.write(to: target)
    model.confirmBackupRestore()
    try await idle(model)
    #expect(
      model.restoreSession?.message
        == "The preview is out of date or files are in use. Quit Codex, then review again.")
    #expect(try Data(contentsOf: target) == modified)

    model.reviewBackupRestore()
    try await idle(model)
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

import Foundation
import Testing

@testable import AgentsApp

@MainActor @Suite("Global configuration migration")
struct GlobalMigrationTests {
  @Test func initialUserReadOffersPreviewAndCancelLeavesFilesUnchanged() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try writePreviousConfiguration(fixture.home.appendingPathComponent(".agents"))
    let before = try fixture.entries()
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    #expect(model.page == .overview)
    #expect(model.scope.kind == .user)
    model.refresh()
    try await waitUntil { model.canPreviewGlobalMigration && model.operations.isEmpty }

    model.previewGlobalMigration()
    try await waitUntil { model.canConfirmGlobalMigration }
    let preview = try #require(model.migrationSession?.preview)
    #expect(preview.declarationURL.lastPathComponent == "agents.yaml")
    #expect(preview.ledgerURL.lastPathComponent == "agents.resolved")
    #expect(preview.originalLedgerURL != preview.ledgerURL)
    #expect(try fixture.entries() == before)
    model.cancelGlobalMigration()
    model.confirmGlobalMigration()
    #expect(model.migrationSession == nil)
    #expect(model.operations.isEmpty)
    #expect(try fixture.entries() == before)
  }

  @Test func changedPreviousDeclarationRequiresFreshPreviewThenReloadsOverview() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let directory = fixture.home.appendingPathComponent(".agents")
    try writePreviousConfiguration(directory)
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    model.refresh()
    try await waitUntil { model.canPreviewGlobalMigration && model.operations.isEmpty }
    model.previewGlobalMigration()
    try await waitUntil { model.canConfirmGlobalMigration }

    let previousDeclaration = directory.appendingPathComponent("agents.json")
    let replacement = "{\"agents\":[\"codex\"],\"sources\":{}}\n"
    try fixture.externalWrite(replacement, to: previousDeclaration, atomic: true)
    try await waitUntil {
      model.migrationSession?.stale == true && model.canPreviewGlobalMigration
        && model.operations.isEmpty
    }
    let before = try fixture.entries()
    #expect(!model.canConfirmGlobalMigration)
    model.confirmGlobalMigration()
    #expect(model.operations.isEmpty)
    #expect(try fixture.entries() == before)

    model.previewGlobalMigration()
    try await waitUntil { model.canConfirmGlobalMigration }
    let preview = try #require(model.migrationSession?.preview)
    let previousLedger = try Data(contentsOf: preview.ledgerURL)
    model.confirmGlobalMigration()
    #expect(model.isApplying)
    try await waitUntil { model.snapshot?.document != nil && model.operations.isEmpty }

    #expect(!model.isApplying)
    #expect(model.migrationSession == nil)
    #expect(model.didMigrateGlobalConfiguration)
    #expect(model.page == .overview)
    #expect(model.snapshot?.effectiveDefaultAgents.map(\.rawValue) == ["codex"])
    #expect(try Data(contentsOf: previousDeclaration) == Data(replacement.utf8))
    #expect(try Data(contentsOf: preview.originalLedgerURL) == previousLedger)
  }

  @Test func projectPairKeepsOrdinaryReadFailure() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try writePreviousConfiguration(fixture.home.appendingPathComponent(".agents"))
    try writePreviousConfiguration(fixture.project.appendingPathComponent(".agent"))
    let before = try fixture.entries()
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    model.select(.init(kind: .project, root: fixture.project))
    try await waitUntil { model.operations.isEmpty }
    guard case .failed(let diagnostics) = model.loadState else {
      Issue.record("Expected the ordinary project read error")
      return
    }
    #expect(!diagnostics.isEmpty)
    #expect(!model.canPreviewGlobalMigration)
    model.previewGlobalMigration()
    #expect(model.migrationSession == nil)
    #expect(try fixture.entries() == before)
  }

  @Test func unsafePreviousConfigurationShowsPreviewErrorWithoutWriting() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let directory = fixture.home.appendingPathComponent(".agents")
    try writePreviousConfiguration(directory)
    try Data("{\"instructions\":{\"sections\":[\"team-style\"]}}\n".utf8)
      .write(to: directory.appendingPathComponent("agents.json"))
    let before = try fixture.entries()
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    model.refresh()
    try await waitUntil { model.canPreviewGlobalMigration && model.operations.isEmpty }
    model.previewGlobalMigration()
    try await waitUntil { model.migrationSession?.stage == .failed }

    #expect(model.migrationSession?.messages.isEmpty == false)
    #expect(model.migrationSession?.preview == nil)
    #expect(!model.canConfirmGlobalMigration)
    #expect(!model.didMigrateGlobalConfiguration)
    #expect(try fixture.entries() == before)
  }

  private func makeModel(_ fixture: TestFixture) -> AppModel {
    AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
  }

  private func writePreviousConfiguration(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{\"agents\":[],\"sources\":{}}\n".utf8)
      .write(to: directory.appendingPathComponent("agents.json"))
    try Data(
      """
      {"version":1,"sources":{},"skills":{},"instructions":{"sections":[],"chatgpt":{},"targets":{}}}
      """.utf8
    ).write(to: directory.appendingPathComponent("agents.resolved"))
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1600 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }
}

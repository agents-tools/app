import Foundation
import Testing

@testable import AgentsApp

@MainActor @Suite("Use existing configuration")
struct ExistingConfigurationTests {
  @Test func initialUserReadOffersPreviewAndCancelLeavesFilesUnchanged() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try writeExistingConfiguration(fixture.home.appendingPathComponent(".agents"))
    let before = try fixture.entries()
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    #expect(model.page == .overview)
    #expect(model.scope.kind == .user)
    model.refresh()
    try await waitUntil { model.canPreviewExistingConfiguration && model.operations.isEmpty }

    model.previewExistingConfiguration()
    try await waitUntil { model.canApplyExistingConfiguration }
    let preview = try #require(model.existingConfigurationSession?.preview)
    #expect(preview.declarationURL.lastPathComponent == "agents.yaml")
    #expect(preview.ledgerURL.lastPathComponent == "agents.resolved")
    #expect(preview.originalLedgerURL != preview.ledgerURL)
    #expect(try fixture.entries() == before)
    model.cancelExistingConfiguration()
    model.applyExistingConfiguration()
    #expect(model.existingConfigurationSession == nil)
    #expect(model.operations.isEmpty)
    #expect(try fixture.entries() == before)
  }

  @Test func changedExistingDeclarationRequiresFreshPreviewThenReloadsOverview() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let directory = fixture.home.appendingPathComponent(".agents")
    try writeExistingConfiguration(directory)
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    model.refresh()
    try await waitUntil { model.canPreviewExistingConfiguration && model.operations.isEmpty }
    model.previewExistingConfiguration()
    try await waitUntil { model.canApplyExistingConfiguration }

    let existingDeclaration = directory.appendingPathComponent("agents.json")
    let replacement = "{\"agents\":[\"codex\"],\"sources\":{}}\n"
    try fixture.externalWrite(replacement, to: existingDeclaration, atomic: true)
    try await waitUntil {
      model.existingConfigurationSession?.stale == true && model.canPreviewExistingConfiguration
        && model.operations.isEmpty
    }
    let before = try fixture.entries()
    #expect(!model.canApplyExistingConfiguration)
    model.applyExistingConfiguration()
    #expect(model.operations.isEmpty)
    #expect(try fixture.entries() == before)

    model.previewExistingConfiguration()
    try await waitUntil { model.canApplyExistingConfiguration }
    let preview = try #require(model.existingConfigurationSession?.preview)
    let originalLedger = try Data(contentsOf: preview.ledgerURL)
    model.applyExistingConfiguration()
    #expect(model.isApplying)
    try await waitUntil { model.snapshot?.document != nil && model.operations.isEmpty }

    #expect(!model.isApplying)
    #expect(model.existingConfigurationSession == nil)
    #expect(model.didApplyExistingConfiguration)
    #expect(model.page == .overview)
    #expect(model.snapshot?.effectiveDefaultAgents.map(\.rawValue) == ["codex"])
    #expect(try Data(contentsOf: existingDeclaration) == Data(replacement.utf8))
    #expect(try Data(contentsOf: preview.originalLedgerURL) == originalLedger)
  }

  @Test func projectPairKeepsOrdinaryReadFailure() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try writeExistingConfiguration(fixture.home.appendingPathComponent(".agents"))
    try writeExistingConfiguration(fixture.project.appendingPathComponent(".agent"))
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
    #expect(!model.canPreviewExistingConfiguration)
    model.previewExistingConfiguration()
    #expect(model.existingConfigurationSession == nil)
    #expect(try fixture.entries() == before)
  }

  @Test func unsafeExistingConfigurationShowsPreviewErrorWithoutWriting() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let directory = fixture.home.appendingPathComponent(".agents")
    try writeExistingConfiguration(directory)
    try Data("{\"instructions\":{\"sections\":[\"team-style\"]}}\n".utf8)
      .write(to: directory.appendingPathComponent("agents.json"))
    let before = try fixture.entries()
    let model = makeModel(fixture)
    defer { _ = model.requestTermination() }
    model.refresh()
    try await waitUntil { model.canPreviewExistingConfiguration && model.operations.isEmpty }
    model.previewExistingConfiguration()
    try await waitUntil { model.existingConfigurationSession?.stage == .failed }

    #expect(model.existingConfigurationSession?.messages.isEmpty == false)
    #expect(model.existingConfigurationSession?.preview == nil)
    #expect(!model.canApplyExistingConfiguration)
    #expect(!model.didApplyExistingConfiguration)
    #expect(try fixture.entries() == before)
  }

  private func makeModel(_ fixture: TestFixture) -> AppModel {
    AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
  }

  private func writeExistingConfiguration(_ directory: URL) throws {
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

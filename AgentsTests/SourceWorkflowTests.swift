import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

@Suite("Source workflow inputs", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SourceWorkflowTests {
  @Test func explicitImportSelectionReinspectsWithoutPublishing() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    try f.writeManifest("version: 1\ndefaultAgents: []\n")
    let file = f.root.appendingPathComponent("mcp.json")
    try Data(
      #"{"mcpServers":{"first":{"command":"one","args":["","a\nb"]},"second":{"command":"two"}}}"#
        .utf8
    ).write(to: file)
    let model = await loaded(f)
    let before = try f.entries()
    model.beginImport()
    model.importSession?.file = file
    model.importSession?.format = "cursorMCPV1"
    model.inspectImport()
    try await idle(model)
    let choice = try #require(
      model.importSession?.inspection?.availableChoices.first {
        $0.effects.components.contains { ComponentDraft($0.declaration).name == "first" }
      })
    model.importSession?.selectedChoices = [choice.id]
    model.resolveImportSelection()
    try await idle(model)
    let imported = try #require(model.importSession?.inspection)
    #expect(imported.components.map { ComponentDraft($0.declaration).name } == ["first"])
    let component = ComponentDraft(try #require(imported.components.first).declaration)
    guard case .stdio(let executable) = component.transport else {
      Issue.record("Expected captured stdio arguments")
      return
    }
    #expect(executable.arguments == ["", "a\nb"])
    model.importSession?.selectedChoices = []
    model.resolveImportSelection()
    try await idle(model)
    #expect(model.importSession?.inspection?.components.isEmpty == true)
    model.inspectImport()
    try await idle(model)
    #expect(model.importSession?.inspection?.components.count == 2)
    #expect(try f.entries() == before)
    _ = model.requestTermination()
  }

  @Test func issuedSourceCoordinateHandleReachesPublicImporter() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let boundary = try FixtureEventBoundary(root: f.root)
    defer { boundary.stop() }
    try f.writeManifest("version: 1\ndefaultAgents: []\n")
    let lock = f.root.appendingPathComponent("source-lock.json")
    try Data(
      "{\"lockfileVersion\":1,\"sources\":{\"acme/repo\":{\"resolvedRef\":\"\(String(repeating: "a", count: 40))\"}}}"
        .utf8
    ).write(to: lock)
    try await boundary.settle(creation: lock, root: f.root)
    let model = await loaded(f)
    defer { _ = model.requestTermination() }
    model.beginImport()
    model.importSession?.file = lock
    model.importSession?.format = "rulesyncSourcesV1"
    model.inspectImport()
    try await idle(model)
    #expect(model.importSession?.inspection?.sources.first?.declaration == nil)
    let sourceInput = try #require(
      model.importSession?.inspection?.requiredInputs.first { $0.kind == .sourceCoordinates })
    model.importSession?.inputs[sourceInput.id]?.enabled = true
    model.importSession?.inputs[sourceInput.id]?.source = .init(
      kind: .git, location: "https://example.invalid/acme/repo")
    model.resolveImportSelection()
    try await idle(model)
    #expect(
      model.importSession?.inspection?.sources.first?.declaration?.location
        == "https://example.invalid/acme/repo")
    #expect(
      model.importSession?.inspection?.sources.first?.declaration?.requirement
        == .revision(String(repeating: "a", count: 40)))
    _ = model.requestTermination()
  }

  @Test func subscriptionReadKeepsOldScopeErrorAndNeverWritesState() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    try f.writeManifest("version: 1\ndefaultAgents: []\n")
    let model = await loaded(f)
    let before = try f.entries()
    model.checkSubscriptions()
    try await idle(model)
    #expect(model.watchStatusSession?.statuses.isEmpty == true)
    #expect(model.watchStatusSession?.messages.isEmpty == true)
    model.checkSubscriptions(source: "missing")
    model.select(.init(kind: .user, root: f.home))
    try await idle(model)
    #expect(
      model.diagnostics.contains {
        $0.scope.root == f.project && $0.operation == "Check subscriptions"
      })
    #expect(try f.entries() == before)
    #expect(model.operations.isEmpty)
    _ = model.requestTermination()
  }

  @Test func changedDeclarationInvalidatesCapturedDiscoveryInsteadOfRebinding() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    try f.writeManifest(
      """
      version: 1
      defaultAgents: []
      components:
        - kind: mcpServer
          name: before
          transport: {kind: stdio, executable: fixture-command}
      """)
    let model = await loaded(f)
    let before = try f.entries()
    model.discoverComponents()
    try await idle(model)
    #expect(model.discoverySession?.discovery?.components.first?.name == "before")
    #expect(try f.entries() == before)
    try f.externalWrite(
      "version: 1\ndefaultAgents: []\n", to: f.project.appendingPathComponent(".agent/agents.yaml"),
      atomic: true)
    for _ in 0..<400 {
      if model.discoverySession?.stale == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.discoverySession?.stale == true)
    model.previewDiscovery()
    #expect(model.updateSession == nil)
    #expect(model.discoverySession?.discovery?.components.first?.name == "before")
    try await idle(model)
    _ = model.requestTermination()
  }

  @Test func cancelledQueuedSubscriptionReadDoesNotClaimAnEmptyResult() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    try f.writeManifest("version: 1\ndefaultAgents: []\n")
    let model = await loaded(f)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let (events, started) = AsyncStream.makeStream(of: Bool.self)
    var iterator = events.makeAsyncIterator()
    model.startOperation(title: "Owned fixture work", scope: model.scope) {
      started.yield(true)
      gate.wait()
      return .init(disposition: .completed)
    }
    #expect(await iterator.next() == true)
    model.checkSubscriptions()
    #expect(model.watchStatusSession?.busy == true)
    model.cancelQueuedOperations()
    #expect(!model.operations.isEmpty)
    gate.signal()
    try await idle(model)
    #expect(model.watchStatusSession?.busy == false)
    #expect(model.watchStatusSession?.hasResult == false)
    #expect(model.watchStatusSession?.messages.isEmpty == false)
    #expect(model.operations.isEmpty)
    _ = model.requestTermination()
  }

  private func loaded(_ f: TestFixture) async -> AppModel {
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: f.environment)
    model.select(.init(kind: .project, root: f.project))
    try? await idle(model)
    return model
  }

  private func idle(_ model: AppModel) async throws {
    for _ in 0..<1600 {
      if model.operations.isEmpty {
        try await Task.sleep(for: .milliseconds(300))
        if model.operations.isEmpty { return }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Outer operation did not return")
  }
}

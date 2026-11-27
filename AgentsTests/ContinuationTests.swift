import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

@MainActor struct ContinuationTests {
  @Test func activationRetriesFailedReadsAndSkipsObservedConfiguration() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: [broken\n", user: true)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    defer { _ = model.requestTermination() }

    model.refreshOnActivation()
    #expect(model.operations.count == 1)
    model.refreshOnActivation()
    #expect(model.operations.count == 1)
    try await eventually { model.operations.isEmpty }
    guard case .failed = model.loadState else {
      Issue.record("Expected the invalid configuration to fail its first read")
      return
    }

    try fixture.writeManifest("version: 1\n", user: true)
    model.refreshOnActivation()
    try await eventually { model.operations.isEmpty && model.canModify }
    let loadedAt = try #require(model.snapshot?.readAt)
    model.refreshOnActivation()
    #expect(model.operations.isEmpty)
    #expect(model.snapshot?.readAt == loadedAt)

    model.refresh()
    try await eventually { model.operations.isEmpty && model.canModify }
    #expect(model.snapshot?.readAt != loadedAt)
  }

  @Test func nativeCacheEventsDoNotRefreshAndInstructionSnapshotsSurviveWorkspaceReads()
    async throws
  {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "rules", environment: runtime)
    let producer = fixture.project.appendingPathComponent("producer")
    let cache = producer.appendingPathComponent(".git/lfs/objects/a3/f0")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try fixture.writeManifest(
      """
      version: 1
      sources: {local: {path: ./producer}}
      components:
        - kind: instructions
          sections: [{name: rules, recipients: [chatgpt-app]}]
      """)
    let model = await loaded(fixture)
    defer { _ = model.requestTermination() }
    let initial = try #require(model.snapshot?.readAt)
    let events = try FixtureEventBoundary(root: fixture.root)
    defer { events.stop() }
    let object = cache.appendingPathComponent("object")
    try fixture.externalWrite("LFS cache payload", to: object)
    try await events.settle(creation: object, root: fixture.root)
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.snapshot?.readAt == initial)
    #expect(model.operations.isEmpty)

    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    model.startOperation(title: "Hold the Core worker", scope: scope) {
      gate.wait()
      return .init(disposition: .completed)
    }
    model.previewUpdate(
      UpdateProposal(previewingInstructionOutputsIn: scope, focus: .app(.chatGPTApp)))
    try fixture.externalWrite(
      "Genuine authored input", to: producer.appendingPathComponent("input.md"))
    try await eventually { model.operations.values.contains { $0.title == "Read configuration" } }
    #expect(model.updateSession?.stage == .preparing)
    gate.signal()
    try await eventually { model.operations.isEmpty }
    #expect(model.snapshot?.readAt != initial)
    #expect(model.updateSession?.stage == .review)
    let output = try #require(model.updateSession?.instructionOutputs.first)
    #expect(output.recipient == .chatGPTApp)
    #expect(output.fullText?.contains("# rules") == true)

    model.refresh()
    try await eventually { model.operations.isEmpty }
    #expect(model.updateSession?.stage == .review)
    #expect(model.updateSession?.instructionOutputs == [output])
    #expect(model.updateSession?.canApplyReport == false)

    model.select(.init(kind: .user, root: fixture.home))
    model.select(scope)
    try await eventually { model.operations.isEmpty }
    #expect(model.updateSession?.stage == .stale)
    #expect(model.updateSession?.instructionOutputs.isEmpty == true)
  }

  @Test func atomicExternalReplacementRetainsDirtyDraftAndInvalidatesPreview() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: 1\ndefaultAgents: []\n")
    let model = await loaded(fixture)
    defer { _ = model.requestTermination() }
    model.beginDraft(.defaults)
    #expect(model.manifestDraft != nil)
    model.manifestDraft?.defaultAgents = [.codex]
    let draftID = model.manifestDraft?.id
    // Fixture creation can still be in the native event batch when the first read finishes.
    // Exercise the same explicit re-review used after an unchanged-document invalidation.
    for _ in 0..<3 {
      try await eventually { model.canModify }
      model.previewDraft()
      try await eventually {
        model.updateSession?.stage == .review || model.updateSession?.stage == .stale
      }
      if model.updateSession?.stage == .review { break }
      model.closeUpdateReview()
    }
    try #require(model.updateSession?.stage == .review)
    let url = fixture.project.appendingPathComponent(".agent/agents.yaml")
    try fixture.externalWrite(
      "# External replacement\nversion: 1\ndefaultAgents: []\nexports: []\n", to: url, atomic: true)
    try await eventually { model.manifestDraft?.isStale == true && !model.readsStale }
    #expect(model.manifestDraft?.id == draftID)
    #expect(model.manifestDraft?.defaultAgents == [.codex])
    #expect(model.updateSession?.stage == .stale)
    #expect(model.snapshot?.document?.declaration.exports == [])
    model.confirmUpdate()
    #expect(!model.isApplying)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent(".agent/agents.resolved").path))
  }

  @Test func absentInputsAndInvalidManifestRecoverFromActualFileEvents() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = await loaded(fixture)
    defer { _ = model.requestTermination() }
    #expect(model.snapshot?.isEmpty == true)
    try fixture.externalWrite(
      "version: [broken\n", to: fixture.project.appendingPathComponent(".agent/agents.yaml"))
    try await eventually {
      if case .failed = model.loadState { return true }
      return false
    }
    try fixture.externalWrite(
      "version: 1\ndefaultAgents: []\n",
      to: fixture.project.appendingPathComponent(".agent/agents.yaml"))
    try await eventually { model.snapshot?.document != nil && !model.readsStale }
    #expect(model.scope.root == fixture.project)
  }

  @Test func releasedScopeDoesNotReactAndUnchangedNodeSelectionSurvivesRefresh() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      "version: 1\ncomponents:\n  - kind: ignore\n    name: cache\n    patterns: [cache/**]\n")
    let model = await loaded(fixture)
    defer { _ = model.requestTermination() }
    let node = try #require(model.snapshot?.components.first?.id)
    model.selectedItem = node
    model.refresh()
    try await eventually { model.operations.isEmpty }
    #expect(model.selectedItem == node)
    model.select(.init(kind: .user, root: fixture.home))
    try await eventually { model.operations.isEmpty }
    let read = model.snapshot?.readAt
    try fixture.externalWrite(
      "version: 1\ndefaultAgents: []\n",
      to: fixture.project.appendingPathComponent(".agent/agents.yaml"))
    try await Task.sleep(for: .milliseconds(700))
    #expect(model.scope.kind == .user)
    #expect(model.snapshot?.readAt == read)
    #expect(model.operations.isEmpty)
  }

  @Test func structuralControlsUseExactNodesForRemovalReferenceAndSectionOrder() throws {
    let document = try DeclarationDocument(
      bytes: Array(
        """
        # Authored structure
        version: 1
        sources:
          unused: {path: ./unused}
        components:
          - kind: instructions
            sections: [{name: first}, {name: second}]
        groups:
          one: {}
          two: {condition: {agents: []}}
          unused: {}
        uses: [{group: one, condition: {agents: []}}, {group: two}]
        exports: [one, two]
        """.utf8), identity: .init("structure fixture"))
    let scope = WorkspaceScope(kind: .project, root: URL(fileURLWithPath: "/fixture"))
    var draft = ManifestDraft(scope: scope, document: document)
    draft.kind = .structure
    draft.structuralAction = .remove
    draft.structuralNode = document.node(at: "/sources/0")
    #expect(
      try document.preparing(draft.edits(home: scope.root)).expectedDeclaration.sources.isEmpty)
    draft.structuralNode = document.node(at: "/groups/2")
    #expect(
      try document.preparing(draft.edits(home: scope.root)).expectedDeclaration.groups.count == 2)
    draft.structuralNode = document.node(at: "/uses/0")
    #expect(
      try document.preparing(draft.edits(home: scope.root)).expectedDeclaration.uses.count == 1)
    draft.structuralNode = document.node(at: "/components/0/sections/1")
    draft.structuralAction = .move
    draft.destinationNode = document.node(at: "/components/0/sections/0")
    draft.insertFirst = true
    let change = try document.preparing(draft.edits(home: scope.root))
    #expect(
      change.expectedDeclaration.components[0]["sections"]?.elements?.first?.record?["name"]?.string
        == "second")
    #expect(String(decoding: change.bytes, as: UTF8.self).contains("# Authored structure"))
  }

  @Test func typedReferenceReplacementAndExportsPreserveExactValues() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      "version: 1\ngroups:\n  one: {}\n  two: {}\nuses:\n  - group: one\n    condition: {agents: []}\nexports: [one]\n"
    )
    let snapshot = try #require(
      CoreReader(home: fixture.home, processEnvironment: fixture.environment).read(
        scope: .init(kind: .project, root: fixture.project)
      ).snapshot)
    let declaration = try #require(snapshot.inspection.declaration)
    let item = try #require(snapshot.items.first { $0.category == "Group Reference" })
    var draft = ManifestDraft(scope: snapshot.scope, document: snapshot.document)
    draft.captureReferences(from: declaration)
    draft.load(item, from: declaration)
    #expect(draft.referenceCondition?.agents == [])
    draft.referenceName = "two"
    let document = try #require(snapshot.document)
    let ir = try document.preparing(draft.edits(home: fixture.home)).expectedDeclaration
    #expect(ir.uses.count == 1)
    #expect(ir.uses[0]["name"]?.string == "two")
    #expect(ir.uses[0]["condition"]?.record?["agents"]?.elements == [])
    draft.kind = .exports
    draft.exports = ["two", "one"]
    #expect(
      try document.preparing(draft.edits(home: fixture.home)).expectedDeclaration.exports == [
        "two", "one",
      ])
  }

  @Test func assistanceCancellationKeepsOwnershipUntilGenerationActuallyReturns() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let gate = AssistanceGate()
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment,
      assistance: .init(available: { true }, generate: { input in await gate.wait(input) }))
    model.setAssistanceEnabled(true)
    model.reviewAssistance(.init(action: .translateDescription, text: "A selected description"))
    model.generateAssistance()
    await gate.started()
    #expect(model.operations.count == 1)
    #expect(model.requestTermination() == .later)
    await Task.yield()
    #expect(!model.operations.isEmpty)
    await gate.release()
    try await eventually { model.operations.isEmpty }
    if case .cancelled = model.assistanceSession?.stage {
    } else {
      Issue.record("Cancellation must suppress generated output")
    }
  }

  @Test func optOutCancelsOwnedGenerationAndRetainsNoResult() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let gate = AssistanceGate()
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment,
      assistance: .init(available: { true }, generate: { input in await gate.wait(input) }))
    model.setAssistanceEnabled(true)
    model.reviewAssistance(.init(action: .explainSkill, text: "Selected description"))
    model.generateAssistance()
    await gate.started()
    model.setAssistanceEnabled(false)
    #expect(model.assistanceSession == nil)
    #expect(!model.operations.isEmpty)
    await gate.release()
    try await eventually { model.operations.isEmpty }
    #expect(model.assistanceSession == nil)
    model.reviewAssistance(.init(action: .explainSkill, text: "Ignored"))
    #expect(model.assistanceSession == nil)
  }

  @Test func safeChangeProjectionExcludesSecretNativeValuesAndPaths() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: [codex]
      components:
        - kind: mcpServer
          name: private-example
          transport: {kind: stdio, executable: private-command, arguments: [secret-argument], environment: {TOKEN: {secret: private-slot}}}
      """)
    let proposal = UpdateProposal(
      id: UUID(), scope: .init(kind: .project, root: fixture.project), title: "fixture",
      request: .init())
    let result = CoreActions(home: fixture.home, processEnvironment: fixture.environment).preview(
      proposal)
    guard case .updatePreview(_, let report) = result.output else {
      Issue.record("Real Core preview required")
      return
    }
    let input = AssistanceInput.changes(report, action: .explainConfiguration)
    for value in [
      fixture.root.path, "private-command", "secret-argument", "private-slot", "TOKEN",
      "private-example",
    ] {
      #expect(!input.prompt.contains(value))
    }
    #expect(input.text.contains("Runtime binding slots required: 1"))
    #expect(input.withinLimit)
  }

  @Test func sourceDirectoryEventsRefreshWithoutRebindingDocumentNodes() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: 1\nsources:\n  local: {path: ./content}\n")
    let directory = fixture.project.appendingPathComponent("content")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = await loaded(fixture)
    defer { _ = model.requestTermination() }
    let node = try #require(model.snapshot?.sources.first?.id)
    model.selectedItem = node
    model.beginDraft(.source)
    let read = model.snapshot?.readAt
    try fixture.externalWrite(
      "A new producer input", to: directory.appendingPathComponent("input.md"), atomic: true)
    try await eventually { model.snapshot?.readAt != read && !model.readsStale }
    #expect(model.selectedItem == node)
    #expect(model.manifestDraft?.isStale == true)
    let draft = try #require(model.manifestDraft)
    #expect(draft.canReview(against: model.snapshot))
    #expect(draft.document?.digest == model.snapshot?.document?.digest)
  }

  @Test func failedObsoleteAssistanceRetainsSafeDiagnosticAndNoProviderPayload() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let gate = AssistanceGate()
    struct SensitiveFailure: LocalizedError {
      var errorDescription: String? { "provider echoed PRIVATE_INPUT" }
    }
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment,
      assistance: .init(
        available: { true },
        generate: { input in
          _ = await gate.wait(input)
          throw SensitiveFailure()
        }))
    model.setAssistanceEnabled(true)
    let original = model.scope
    model.reviewAssistance(.init(action: .translateDescription, text: "PRIVATE_INPUT"))
    model.generateAssistance()
    await gate.started()
    model.select(.init(kind: .project, root: fixture.project))
    #expect(!model.operations.isEmpty)
    await gate.release()
    try await eventually { model.operations.isEmpty }
    #expect(
      model.diagnostics.contains { $0.scope == original && $0.operation == "Translate Description" }
    )
    #expect(!model.diagnostics.contains { $0.message.contains("PRIVATE_INPUT") })
    if case .outdated = model.assistanceSession?.stage {
    } else {
      Issue.record("Old-scope output must be withheld")
    }
    _ = model.requestTermination()
  }

  private func loaded(_ fixture: TestFixture) async -> AppModel {
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.select(.init(kind: .project, root: fixture.project))
    try? await eventually { model.operations.isEmpty && model.canModify }
    return model
  }
  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<1600 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Expected native event or owned terminal did not arrive within eight seconds")
  }
}

private actor AssistanceGate {
  private var continuation: CheckedContinuation<String, Never>?
  private var waiting: CheckedContinuation<Void, Never>?
  func wait(_ input: AssistanceInput) async -> String {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      waiting?.resume()
      waiting = nil
    }
  }
  func started() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func release() {
    continuation?.resume(returning: "Auxiliary text")
    continuation = nil
  }
}

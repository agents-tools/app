import AgentsCore
import AgentsManifest
import AgentsUpdates
import CryptoKit
import Foundation
import Testing

@testable import AgentsApp

@Suite("Public API presentation integration", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct PublicAPIConsumerTests {
  @Test func selectedOrganizationPolicyGovernsAppPreviewBeforeAnyWrite() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let user = WorkspaceScope(kind: .user, root: fixture.home)
    let unavailable = fixture.home.appendingPathComponent("required-policy.yaml")
    let actions = CoreActions(
      home: fixture.home, processEnvironment: fixture.environment,
      policyFiles: [user.id: unavailable.path])
    let before = try fixture.entries()
    let proposal = UpdateProposal(
      id: UUID(), scope: scope, title: "Install handbook",
      request: .init(
        operation: .declaration(
          .init(
            agents: [.codex],
            components: [
              .mcpServer(
                name: "handbook",
                transport: .streamableHTTP(url: "https://example.invalid/mcp", headers: [:]))
            ]))))
    let preview = actions.preview(proposal)
    #expect(!preview.diagnostics.isEmpty)
    let audit = try OrganizationPolicyOperations.audit(
      scope: .project, environment: actions.environment(for: scope))
    #expect(
      audit.organization.findings.contains {
        $0.authority == .user && $0.outcome == .block && $0.rule == "policy-unavailable"
      })
    #expect(try fixture.entries() == before)
  }

  @Test func symbolicReviewAndConnectionDescriptionUseTheCapturedPublicValues() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let scope = WorkspaceScope(kind: .project, root: f.project)
    let proposal = UpdateProposal(
      id: UUID(), scope: scope, title: "Fixture connections",
      request: .init(
        operation: .declaration(
          .init(
            agents: [.claudeCode],
            components: [
              .mcpServer(
                name: "stdio",
                transport: .stdio(
                  .init(
                    executable: "fixture-command", arguments: ["", "a\nb", "literal-private"],
                    environment: [
                      "TOKEN": .literal("literal-private"), "INPUT": .secret("test-input"),
                    ]))),
              .mcpServer(
                name: "http",
                transport: .streamableHTTP(
                  url: "https://example.invalid/private-route?token=private-query",
                  headers: ["Authorization": .literal("Bearer private-header")])),
            ]))))
    let preview = actions.preview(proposal)
    guard case .updatePreview(_, let report) = preview.output else {
      Issue.record("Expected a public combined preview")
      return
    }
    let stdio = try #require(report.components.first { $0.name == "stdio" })
    let text = try #require(stdio.symbolicAfter)
    #expect(text.contains("fixture-command"))
    #expect(text.contains("test-input"))
    #expect(!text.contains("\"kind\": \"object\""))
    let view = SymbolicChangeView(title: "After", text: stdio.symbolicAfter)
    #expect(view.text == text)
    let applied = actions.apply(
      proposal, fingerprint: report.displayedFingerprint, admission: OperationAdmission(),
      bindings: ["test-input": Data("one-time".utf8)])
    #expect(applied.updateTerminal?.disposition == .committed)
    let snapshot = try #require(
      CoreReader(home: f.home, processEnvironment: f.environment)
        .read(scope: scope).snapshot)
    let before = try f.entries()
    for component in snapshot.inspection.components {
      let result = actions.connectionSnapshot(
        id: UUID(), scope: scope, selection: component.selection)
      guard case .connectionSnapshot(_, let captured, let description) = result.output else {
        Issue.record("Expected the exact selected connection")
        continue
      }
      #expect(description.snapshotID == captured.id)
      #expect(result.readDependencies == captured.readDependencies)
      #expect(!result.readDependencies.isEmpty)
      #expect(description.readDependencies == captured.readDependencies)
      let presentation = ConnectionDescriptionView(description: description)
      #expect(presentation.description == description)
      if component.name == "stdio" {
        #expect(description.startsOwnedProcess)
        #expect(description.executable == "fixture-command")
        #expect(description.arguments?.prefix(2) == ["", "ab"])
        #expect(description.arguments?.last?.contains("literal-private") == false)
        #expect(description.workingDirectory != nil)
        #expect(description.requiredBindings == ["test-input"])
      } else {
        #expect(!description.startsOwnedProcess)
        let endpoint = try #require(description.endpoint)
        #expect(endpoint.contains("example.invalid"))
        #expect(!endpoint.contains("private-route"))
        #expect(!endpoint.contains("private-query"))
        #expect(!endpoint.contains("private-header"))
        #expect(description.executable == nil)
      }
    }
    #expect(try f.entries() == before)
  }

  @Test func emptySubscriptionInspectionRetainsAbsentReadLeavesWithoutWriting() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let scope = WorkspaceScope(kind: .project, root: f.project)
    let before = try f.entries()
    let result = actions.watchStatus(id: UUID(), scope: scope, source: nil)
    guard case .watchStatus(_, let values) = result.output else {
      Issue.record("Expected empty public inspection")
      return
    }
    #expect(values.isEmpty)
    let store = StateStore(scope: .project, environment: actions.environment(for: scope))
    #expect(
      Set(result.readDependencies)
        == Set(
          [store.declarationURL, store.resolvedURL, store.watchURL].map(ReadDependency.subtree)))
    #expect(try f.entries() == before)
  }

  @Test func displayedWatchAcknowledgmentPreservesOuterFailureAndQueuedCancellation() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let scope = WorkspaceScope(kind: .project, root: f.project)
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let runtime = actions.environment(for: scope)
    let bytes = Data("# Fixture\n".utf8)
    let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let watch = WatchOperations(
      discoverSkills: { _ in [] },
      fetchArtifacts: { _ in
        [
          WatchArtifact(
            name: "fixture",
            artifact: LockedArtifact(
              type: .skillMD, url: "https://example.invalid/fixture.md", digest: digest),
            files: ["SKILL.md": bytes], payloads: [digest: bytes])
        ]
      })
    _ = try watch.add("https://example.invalid/index", alias: "watched", environment: runtime)
    let displayed = try watch.diff("watched", environment: runtime)
    #expect(!displayed.readLocations.isEmpty)
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: f.environment)
    model.select(scope)
    try await ready(model)
    model.watchStatusSession = .init(
      scope: scope, source: "watched", busy: false,
      hasResult: true, statuses: [displayed])
    let gate = ConsumerGate()
    defer { gate.release() }
    var events = gate.events.makeAsyncIterator()
    model.startOperation(title: "Held fixture operation", scope: scope) {
      gate.wait()
      return .init(disposition: .completed)
    }
    _ = await events.next()
    model.markSubscriptionRead(displayed)
    #expect(model.isApplying)
    #expect(model.watchStatusSession?.busy == true)
    model.cancelQueuedOperations()
    gate.release()
    try await idle(model)
    #expect(!model.isApplying)
    #expect(model.watchStatusSession?.busy == false)
    #expect(model.watchStatusSession?.stale == true)
    #expect(
      model.watchStatusSession?.messages.contains {
        $0.message == "Acknowledgment was cancelled before it started."
      } == true)
    let store = StateStore(scope: .project, environment: runtime)
    let manifest = try Data(contentsOf: store.declarationURL)
    try (manifest + Data("# changed evidence\n".utf8)).write(to: store.declarationURL)
    let rejected = actions.acknowledgeWatch(displayed, scope: scope)
    #expect(rejected.updateTerminal?.disposition == .unchanged)
    #expect(rejected.updateTerminal?.succeeded == false)
    #expect(rejected.updateTerminal?.recovery.pending == false)
    #expect(!rejected.diagnostics.isEmpty)
    _ = model.requestTermination()
  }

  @Test func watchCompletionRecordsTheActualOuterTerminalBeforeRefresh() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let scope = WorkspaceScope(kind: .project, root: f.project)
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let runtime = actions.environment(for: scope)
    let bytes = Data("# Fixture\n".utf8)
    let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let watch = WatchOperations(
      discoverSkills: { _ in [] },
      fetchArtifacts: { _ in
        [
          WatchArtifact(
            name: "fixture",
            artifact: LockedArtifact(
              type: .skillMD, url: "https://example.invalid/fixture.md", digest: digest),
            files: ["SKILL.md": bytes], payloads: [digest: bytes])
        ]
      })
    _ = try watch.add("https://example.invalid/index", alias: "watched", environment: runtime)
    let displayed = try watch.diff("watched", environment: runtime)
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: f.environment)
    model.select(scope)
    try await ready(model)
    let session = WatchStatusSession(scope: scope, source: "watched", statuses: [displayed])
    model.watchStatusSession = session
    model.startOperation(
      title: "Mark subscription as read", scope: scope, purpose: .watchSeen(session.id)
    ) {
      actions.completed(
        UpdateOperations.performWatch(displayed, operations: watch),
        scope: scope, title: "Mark subscription as read"
      ) { _ in nil }
    }
    #expect(model.isApplying)
    try await idle(model)
    #expect(model.watchStatusSession?.terminal?.disposition == .committed)
    #expect(model.watchStatusSession?.terminal?.recovery.pending == false)
    #expect(model.updateRecords.last?.scope == scope)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    #expect(model.watchStatusSession?.stale == true)
    #expect(model.watchStatusSession?.busy == false)
    _ = model.requestTermination()
  }

  @Test func clientDetectionAndMetadataChangesLeaveEditingAndReviewIndependent() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    try f.writeManifest("version: 1\ndefaultAgents: []\n")
    let bin = f.root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
    let command = bin.appendingPathComponent("codex")
    let marker = f.root.appendingPathComponent("executed")
    try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: command)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    var environment = f.environment
    environment["PATH"] = bin.path + ":relative:"
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: environment)
    model.select(.init(kind: .project, root: f.project))
    try await ready(model)
    model.beginDraft(.defaults)
    model.manifestDraft?.defaultAgents = [.codex]
    model.previewDraft()
    try await idle(model)
    try #require(model.updateSession?.stage == .review)
    let draft = model.manifestDraft?.id
    let review = model.updateSession?.id
    let before = try f.entries()
    model.redetectClients()
    #expect(model.clientSettings.busy)
    #expect(model.canModify)
    try await idle(model)
    let inspection = try #require(model.clientSettings.inspection)
    #expect(inspection.scope == .user)
    #expect(inspection.pathCoverage.excludedEntries == ["relative", ""])
    let codex = try #require(inspection.clients.first { $0.agent == .codex }?.commands.first)
    #expect(codex.location?.path == command.path)
    #expect(codex.version.rawVersion == nil)
    #expect(codex.version.unknownReason == .unrecognizedLayout)
    #expect(model.manifestDraft?.id == draft)
    #expect(model.updateSession?.id == review)
    #expect(model.updateSession?.stage == .review)
    #expect(model.canModify)
    #expect(try f.entries() == before)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let readAt = model.snapshot?.readAt
    try f.externalWrite("#!/bin/sh\nexit 91\n", to: command, atomic: true)
    try await Task.sleep(for: .milliseconds(700))
    #expect(model.snapshot?.readAt == readAt)
    #expect(!model.readsStale)
    #expect(model.updateSession?.stage == .review)
    model.redetectClients()
    try await idle(model)
    #expect(model.clientSettings.inspection?.startedAt != inspection.startedAt)
    #expect(model.canModify)
    _ = model.requestTermination()
  }

  @Test func obsoleteClientResultsCannotReplaceTheLatestRequest() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let actions = CoreActions(home: f.home, processEnvironment: [:])
    let settings = ClientSettingsModel()
    let old = settings.begin()
    let current = settings.begin()
    settings.finish(id: old, result: actions.inspectClients(id: old))
    #expect(settings.busy && settings.inspection == nil)
    settings.finish(id: current, result: actions.inspectClients(id: current))
    let report = try #require(settings.inspection)
    #expect(!settings.busy)
    settings.finish(
      id: old,
      result: .init(disposition: .failed, output: .clientInspectionFailed(old, "obsolete failure")))
    #expect(settings.inspection?.startedAt == report.startedAt)
    #expect(settings.message == nil)
    let failed = settings.begin()
    settings.finish(
      id: failed,
      result: .init(
        disposition: .failed, output: .clientInspectionFailed(failed, "fixture detection error")))
    #expect(settings.message == "fixture detection error")
    #expect(settings.inspection?.startedAt == report.startedAt)
  }

  @Test func queuedClientCancellationAndTerminationRetainApplicationOwnership() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: [:])
    let gate = ConsumerGate()
    defer { gate.release() }
    var events = gate.events.makeAsyncIterator()
    model.startOperation(title: "Held fixture operation", scope: model.scope) {
      gate.wait()
      return .init(disposition: .completed)
    }
    _ = await events.next()
    model.redetectClients()
    #expect(model.operations.count == 2)
    #expect(model.requestTermination() == .later)
    #expect(model.clientSettings.busy)
    gate.release()
    try await idle(model)
    #expect(!model.clientSettings.busy)
    #expect(model.clientSettings.inspection == nil)
    #expect(model.clientSettings.message == "Detection was cancelled before it started.")
    #expect(model.operations.isEmpty)
  }

  @Test func clientCompletionRemainsInItsUserContextAcrossWorkspaceSelection() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: [:])
    let gate = ConsumerGate()
    defer { gate.release() }
    var events = gate.events.makeAsyncIterator()
    model.startOperation(title: "Held fixture operation", scope: model.scope) {
      gate.wait()
      return .init(disposition: .completed)
    }
    _ = await events.next()
    model.redetectClients()
    model.select(.init(kind: .project, root: f.project))
    gate.release()
    try await idle(model)
    #expect(model.scope.root == f.project)
    #expect(model.clientSettings.inspection?.scope == .user)
    #expect(model.clientSettings.inspection?.homeDirectory.path == f.home.path)
    #expect(model.clientSettings.inspection?.projectDirectory.path == f.home.path)
    #expect(model.clientSettings.message == nil)
    _ = model.requestTermination()
  }

  private func ready(_ model: AppModel) async throws {
    try await idle(model)
    try #require(model.canModify)
  }

  private func idle(_ model: AppModel) async throws {
    for _ in 0..<1200 {
      if model.operations.isEmpty {
        try await Task.sleep(for: .milliseconds(300))
        if model.operations.isEmpty { return }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Application operations did not reach their outer terminal")
  }
}

private final class ConsumerGate: @unchecked Sendable {
  let events: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let semaphore = DispatchSemaphore(value: 0)
  init() { (events, continuation) = AsyncStream.makeStream(of: Void.self) }
  func wait() {
    continuation.yield(())
    semaphore.wait()
  }
  func release() { semaphore.signal() }
}

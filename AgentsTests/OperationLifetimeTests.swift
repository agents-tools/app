import Foundation
import Testing

@testable import AgentsApp

private final class WorkerGate: @unchecked Sendable {
  let events: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private let recovery = DispatchSemaphore(value: 0)
  private let cleanup = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var executionCount = 0

  init() {
    (events, continuation) = AsyncStream.makeStream(of: String.self)
  }
  func waitInRecovery() {
    continuation.yield("recovery")
    recovery.wait()
  }
  func waitInCleanup() {
    continuation.yield("cleanup")
    cleanup.wait()
  }
  func releaseRecovery() { recovery.signal() }
  func releaseCleanup() { cleanup.signal() }
  func recordExecution() { lock.withLock { executionCount += 1 } }
  var executions: Int { lock.withLock { executionCount } }
}

@Suite("Application operation ownership", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct OperationLifetimeTests {
  @Test func quitWaitsForPreCallbackRecoveryAndOuterCleanupAndCancelsQueuedWork() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let resource = fixture.root.appendingPathComponent("owned-resource")
    try Data("owned".utf8).write(to: resource)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let gate = WorkerGate()
    defer {
      gate.releaseRecovery()
      gate.releaseCleanup()
    }
    var phases = gate.events.makeAsyncIterator()
    let (replies, reply) = AsyncStream.makeStream(of: Bool.self)
    var replyReceived = false
    model.terminationReply = { allowed in
      replyReceived = true
      reply.yield(allowed)
    }
    model.startOperation(title: "Preparation with recovery", scope: model.scope) {
      gate.waitInRecovery()
      gate.waitInCleanup()
      do {
        try FileManager.default.removeItem(at: resource)
        return CoreCompletion(disposition: .completed, snapshot: nil, diagnostics: [])
      } catch {
        return CoreCompletion(
          disposition: .failed, snapshot: nil,
          diagnostics: [
            AppDiagnostic(
              scope: .init(kind: .user, root: fixture.home), operation: "Cleanup",
              message: "Fixture cleanup failed", blocksTermination: true)
          ])
      }
    }
    #expect(await phases.next() == "recovery")
    model.startOperation(title: "Queued read", scope: model.scope) {
      gate.recordExecution()
      return CoreCompletion(disposition: .completed, snapshot: nil, diagnostics: [])
    }
    #expect(model.requestTermination() == .later)
    #expect(!replyReceived)
    #expect(
      model.startOperation(title: "New work", scope: model.scope, work: { .cancelled }) == nil)
    gate.releaseRecovery()
    #expect(await phases.next() == "cleanup")
    #expect(!replyReceived)
    #expect(FileManager.default.fileExists(atPath: resource.path))
    #expect(!model.operations.isEmpty)
    gate.releaseCleanup()
    var termination = replies.makeAsyncIterator()
    #expect(await termination.next() == true)
    #expect(model.operations.isEmpty)
    #expect(gate.executions == 0)
    #expect(!FileManager.default.fileExists(atPath: resource.path))
  }

  @Test func obsoleteSelectionCannotHideCleanupFailureOrReplaceCurrentContent() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: 1\n")
    let preferences = AppPreferences(defaults: nil, initialProjects: [fixture.project])
    let model = AppModel(
      home: fixture.home, preferences: preferences, processEnvironment: fixture.environment)
    let oldScope = model.scope
    let gate = WorkerGate()
    defer { gate.releaseRecovery() }
    var phases = gate.events.makeAsyncIterator()
    model.startOperation(title: "Old connection cleanup", scope: oldScope) {
      gate.waitInRecovery()
      let old = CoreReader(home: fixture.home, processEnvironment: fixture.environment).read(
        scope: oldScope)
      return CoreCompletion(
        disposition: .failed, snapshot: old.snapshot,
        diagnostics: [
          AppDiagnostic(
            scope: oldScope, operation: "Connection cleanup", message: "Owned resource remains",
            blocksTermination: true)
        ])
    }
    #expect(await phases.next() == "recovery")
    let selected = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(selected)
    gate.releaseRecovery()
    for _ in 0..<1000 {
      if model.operations.isEmpty { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.operations.isEmpty)
    #expect(model.snapshot?.scope == selected)
    #expect(model.diagnostics.contains { $0.scope == oldScope && $0.blocksTermination })
    #expect(model.requestTermination() == .cancel)
    #expect(model.terminationBlocked)
  }

  @Test func cleanupFailureCancelsAnAlreadyPendingQuit() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = model.scope
    let gate = WorkerGate()
    defer { gate.releaseRecovery() }
    var phases = gate.events.makeAsyncIterator()
    let (replies, reply) = AsyncStream.makeStream(of: Bool.self)
    model.terminationReply = { reply.yield($0) }
    model.startOperation(title: "Delayed cleanup", scope: scope) {
      gate.waitInRecovery()
      return CoreCompletion(
        disposition: .failed, snapshot: nil,
        diagnostics: [
          AppDiagnostic(
            scope: scope, operation: "Cleanup", message: "Cleanup did not complete",
            blocksTermination: true)
        ])
    }
    #expect(await phases.next() == "recovery")
    #expect(model.requestTermination() == .later)
    gate.releaseRecovery()
    var termination = replies.makeAsyncIterator()
    #expect(await termination.next() == false)
    #expect(model.operations.isEmpty)
    #expect(!model.isTerminating)
    #expect(model.terminationBlocked)
    #expect(model.requestTermination() == .cancel)
  }
}

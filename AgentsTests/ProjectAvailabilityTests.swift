import Foundation
import Testing

@testable import AgentsApp

@Suite("Registered project availability", .serialized)
@MainActor
struct ProjectAvailabilityTests {
  @Test func movedRegisteredProjectRemainsRegisteredAndIsUnavailableUntilRestored() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let preferences = AppPreferences(defaults: nil, initialProjects: [fixture.project])
    let model = AppModel(
      home: fixture.home, preferences: preferences, processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)
    #expect(model.snapshot?.isEmpty == true)
    let moved = fixture.root.appendingPathComponent("moved-project")
    try FileManager.default.moveItem(at: fixture.project, to: moved)
    model.refresh()
    try await idle(model)
    #expect(preferences.projects.map(\.path) == [fixture.project.path])
    #expect(model.scope == scope)
    guard case .failed(let diagnostics) = model.loadState else {
      Issue.record("A missing registered root was presented as existing empty configuration")
      return
    }
    #expect(diagnostics.contains { $0.scope == scope && $0.path == fixture.project.path })
    #expect(!FileManager.default.fileExists(atPath: fixture.project.path))
    try FileManager.default.moveItem(at: moved, to: fixture.project)
    model.refresh()
    try await idle(model)
    #expect(model.snapshot?.isEmpty == true)
  }

  @Test func projectRemovedBeforeConfirmationIsNotRecreatedByEitherScopedCreation() async throws {
    for kind in CreationRequest.Kind.allCases {
      let fixture = try TestFixture()
      defer { try? fixture.remove() }
      let model = AppModel(
        home: fixture.home, preferences: AppPreferences(defaults: nil),
        processEnvironment: fixture.environment)
      let scope = WorkspaceScope(kind: .project, root: fixture.project)
      model.select(scope)
      try await idle(model)
      model.beginCreation(kind)
      model.creationSession?.name = "rules"
      let skillDestination = fixture.project.appendingPathComponent("skill")
      if kind == .skill {
        try FileManager.default.createDirectory(
          at: skillDestination, withIntermediateDirectories: false)
        model.selectCreationDirectory(skillDestination)
      }
      model.reviewCreation()
      try await idle(model)
      try fixture.externalRemove(fixture.project)
      model.confirmCreation()
      try await idle(model)
      #expect(model.operations.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: fixture.project.path))
      #expect(!FileManager.default.fileExists(atPath: skillDestination.path))
      for _ in 0..<1600 {
        if model.diagnostics.contains(where: { $0.scope == scope && $0.path == scope.root.path }) {
          break
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(model.diagnostics.contains { $0.scope == scope && $0.path == scope.root.path })
      switch model.creationSession?.stage {
      case .failed: break
      case .confirmation where model.creationSession?.stale == true: break
      default:
        Issue.record(
          "Known-unavailable scope was not rejected or invalidated before initialization")
      }
    }
  }

  @Test func projectRemovedWhileCreationIsQueuedIsRejectedAtWorkerStart() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)
    model.beginCreation(.instructions)
    model.creationSession?.name = "rules"
    for _ in 0..<4 {
      model.reviewCreation()
      try await idle(model)
      if model.creationSession?.stale == false { break }
    }
    try #require(model.creationSession?.stale == false)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let (events, entered) = AsyncStream.makeStream(of: Void.self)
    model.startOperation(title: "Block queue", scope: scope) {
      entered.yield(())
      gate.wait()
      return CoreCompletion(disposition: .completed)
    }
    var event = events.makeAsyncIterator()
    _ = await event.next()
    model.confirmCreation()
    try #require(model.isApplying)
    try FileManager.default.removeItem(at: fixture.project)
    gate.signal()
    try await idle(model)
    #expect(model.operations.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.project.path))
    #expect(model.diagnostics.contains { $0.scope == scope && $0.path == scope.root.path })
    guard case .failed = model.creationSession?.stage else {
      Issue.record("Creation recreated an unavailable root after leaving the queue")
      return
    }
  }

  @Test func selectedMappingReportRetainsUnavailableProjectAndItsPathDiagnostic() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let preferences = AppPreferences(defaults: nil, initialProjects: [fixture.project])
    let model = AppModel(
      home: fixture.home, preferences: preferences, processEnvironment: fixture.environment)
    model.chooseMappings()
    model.mappingSession?.selectedProjects = [fixture.project]
    try FileManager.default.removeItem(at: fixture.project)
    model.readMappings()
    try await idle(model)
    guard case .loaded(let mappings) = model.mappingSession?.stage else {
      Issue.record("Missing mapping report terminal")
      return
    }
    let mapping = try #require(mappings.first { $0.scope.kind == .project })
    #expect(mapping.scope.root.path == fixture.project.path)
    #expect(mapping.status.hasPrefix("Unavailable:"))
    #expect(mapping.copyText.contains(fixture.project.path))
    #expect(model.diagnostics.contains { $0.path == fixture.project.path })
    #expect(preferences.projects.map(\.path) == [fixture.project.path])
    #expect(!FileManager.default.fileExists(atPath: fixture.project.path))
  }

  @Test func fileAtRegisteredDirectoryPathIsUnavailable() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try FileManager.default.removeItem(at: fixture.project)
    try Data("file".utf8).write(to: fixture.project)
    let result = CoreReader(home: fixture.home, processEnvironment: fixture.environment)
      .read(scope: .init(kind: .project, root: fixture.project))
    #expect(result.snapshot == nil)
    #expect(result.diagnostics.contains { $0.path == fixture.project.path })
    #expect(try Data(contentsOf: fixture.project) == Data("file".utf8))
  }

  private func idle(_ model: AppModel) async throws {
    for _ in 0..<2000 {
      if model.operations.isEmpty {
        try await Task.sleep(for: .milliseconds(300))
        if model.operations.isEmpty { return }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Application did not process all operation terminals")
  }
}

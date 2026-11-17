import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

@Suite("Public managed workflows", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ManagedWorkflowTests {
  @Test func creationReviewsCoreFileAndTemplateBeforeTypedPublication() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let model = await loaded(f)
    let before = try f.entries()
    model.beginCreation(.instructions)
    model.creationSession?.name = "team-style"
    model.reviewCreation()
    try await idle(model)
    let description = try #require(model.creationSession?.description)
    #expect(description.kind == .instructions)
    #expect(description.template.contains("team-style"))
    #expect(!FileManager.default.fileExists(atPath: description.file.path))
    #expect(try f.entries() == before)
    model.confirmCreation()
    try await idle(model)
    #expect(model.creationSession?.terminal?.disposition == .committed)
    #expect(try String(contentsOf: description.file, encoding: .utf8) == description.template)
    #expect(model.snapshot?.document == nil)
    _ = model.requestTermination()
  }

  @Test func importUsesCapturedNativeIntentAndRejectsChangedInputBeforeApply() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    try f.writeManifest("version: 1\ndefaultAgents: [claude-code]\n")
    try FileManager.default.createDirectory(
      at: f.project.appendingPathComponent(".cursor"), withIntermediateDirectories: false)
    let inputDirectory = f.root.appendingPathComponent("authoring-source")
    try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: false)
    let input = inputDirectory.appendingPathComponent("mcp.json")
    try Data(
      #"{"mcpServers":{"documentation":{"command":"fixture-command","args":["","a\nb"]}}}"#.utf8
    ).write(to: input)
    let model = await loaded(f)
    let before = try f.entries()
    model.beginImport()
    model.importSession?.format = "cursorMCPV1"
    model.importSession?.file = input
    model.inspectImport()
    try await idle(model)
    let imported = try #require(model.importSession?.inspection)
    #expect(imported.diagnostics.isEmpty)
    #expect(imported.components.count == 1)
    #expect(try f.entries() == before)
    try await ready(model)
    for _ in 0..<4 {
      if model.importSession?.stale == true {
        model.inspectImport()
        try await idle(model)
        try await ready(model)
      }
      model.reviewImport()
      try await idle(model)
      if model.updateSession?.report != nil || model.importSession?.messages.isEmpty == false {
        break
      }
      try await ready(model)
    }
    #expect(
      model.updateSession?.report?.hasChanges == true,
      "Import diagnostics: \(model.importSession?.messages.map(\.message) ?? []) \(model.updateSession?.messages.map(\.message) ?? [])"
    )
    try Data(#"{"mcpServers":{}}"#.utf8).write(to: input, options: .atomic)
    model.confirmUpdate()
    try await idle(model)
    #expect(!model.updateRecords.contains { $0.terminal.disposition == .committed })
    #expect(model.snapshot?.inspection.components.isEmpty == true)
    _ = model.requestTermination()
  }

  @Test func independentImportPublishesCapturedArgumentsThroughReviewedCoreApply() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let boundary = try FixtureEventBoundary(root: f.root)
    defer { boundary.stop() }
    try f.writeManifest("version: 1\ndefaultAgents: [claude-code]\n")
    try FileManager.default.createDirectory(
      at: f.project.appendingPathComponent(".cursor"), withIntermediateDirectories: false)
    let directory = f.root.appendingPathComponent("independent-author")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let file = directory.appendingPathComponent("mcp.json")
    let bytes = Data(
      #"{"mcpServers":{"documentation":{"command":"fixture-command","args":["","a\nb"]}}}"#.utf8)
    try bytes.write(to: file)
    try await boundary.settle(creation: file, root: f.root)
    let model = await loaded(f)
    defer { _ = model.requestTermination() }
    model.beginImport()
    model.importSession?.file = file
    model.importSession?.format = "cursorMCPV1"
    model.inspectImport()
    try await idle(model)
    model.reviewImport()
    try await idle(model)
    try #require(model.updateSession?.report?.hasChanges == true)
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    let component = try #require(model.snapshot?.inspection.declaration?.components.first)
    guard case .mcpServer(_, .stdio(let run), _, _, _) = component else {
      Issue.record("Expected imported MCP intent")
      return
    }
    #expect(run.arguments == ["", "a\nb"])
    #expect(model.snapshot?.inspection.deployments.allSatisfy { $0.status == .current } == true)
    #expect(try Data(contentsOf: file) == bytes)
    _ = model.requestTermination()
  }

  @Test func managedConnectionPreparationUsesExactSelectionWithoutExecutingIt() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let scope = WorkspaceScope(kind: .project, root: f.project)
    let request = UpdateRequest(
      operation: .declaration(
        .init(
          agents: [.claudeCode],
          components: [
            .mcpServer(name: "fixture", transport: .stdio(.init(executable: "fixture-command")))
          ])))
    let proposal = UpdateProposal(
      id: UUID(), scope: scope, title: "Fixture configuration", request: request)
    let preview = actions.preview(proposal)
    guard case .updatePreview(_, let report) = preview.output else {
      Issue.record("Expected actual Core preview")
      return
    }
    #expect(
      actions.apply(
        proposal, fingerprint: report.displayedFingerprint, admission: OperationAdmission()
      ).updateTerminal?.disposition == .committed)
    let model = await loaded(f)
    let selected = try #require(model.availableComponentSelection.first)
    let before = try f.entries()
    model.beginConnection(selected)
    try await idle(model)
    #expect(model.connectionSession?.snapshot != nil)
    #expect(model.connectionSession?.description?.startsOwnedProcess == true)
    #expect(try f.entries() == before)
    try f.writeManifest("version: 1\ndefaultAgents: []\n")
    let obsolete = actions.connectionSnapshot(
      id: UUID(), scope: scope, selection: selected.selection)
    #expect(obsolete.disposition == .failed)
    _ = model.requestTermination()
  }

  @Test func subscriptionRemovalReviewsWithoutWritingThenPreservesTheSource() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let producer = f.root.appendingPathComponent("producer")
    try FileManager.default.createDirectory(at: producer, withIntermediateDirectories: false)
    try f.writeManifest(
      "version: 1\ndefaultAgents: []\nsources: {watched: {path: \(producer.path)}}\nwatch: [watched]\n"
    )
    let runtime = RuntimeEnvironment(
      projectDirectory: f.project, homeDirectory: f.home, environment: f.environment)
    let store = StateStore(scope: .project, environment: runtime)
    let identity = try SourceDeclaration(kind: .local, location: producer.path).identity(
      environment: runtime)
    try JSONEncoder().encode(
      WatchState(sources: [identity: .init(seen: .revision(String(repeating: "a", count: 40)))])
    ).write(to: store.watchURL)
    let model = await loaded(f)
    let before = try f.entries()
    model.beginWatch(source: "watched", removing: true)
    model.reviewWatch()
    try await idle(model)
    #expect(model.watchSession?.preview?.sourceID == identity)
    #expect(try f.entries() == before)
    try await ready(model)
    model.confirmWatch()
    try await idle(model)
    #expect(model.watchSession?.terminal?.disposition == .committed)
    #expect(model.snapshot?.inspection.declaration?.sources["watched"] != nil)
    #expect(model.snapshot?.watch?.sources.isEmpty == true)
    _ = model.requestTermination()
  }

  @Test func pickerCompletionsOnlyUpdateTheirAdmittedSession() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let model = await loaded(f)
    let selected = f.root.appendingPathComponent("selected")
    model.beginCreation(.skill)
    let creation = try #require(model.creationSession)
    model.selectCreationDirectory(selected, for: creation)
    #expect(model.creationSession?.directory == selected)
    #expect(model.creationSession?.directorySelected == true)
    model.creationSession = nil
    model.selectCreationDirectory(f.home, for: creation)
    #expect(model.creationSession == nil)
    model.beginCreation(.skill)
    let replacement = try #require(model.creationSession)
    model.selectCreationDirectory(selected, for: creation)
    #expect(model.creationSession?.directorySelected == false)
    model.creationSession?.stage = .describing
    model.selectCreationDirectory(selected, for: replacement)
    #expect(model.creationSession?.directorySelected == false)
    model.creationSession?.stage = .input

    model.beginImport()
    let imported = try #require(model.importSession)
    model.selectImportFile(selected, for: imported)
    model.selectImportDirectory(f.root, for: imported)
    #expect(model.importSession?.file == selected)
    #expect(model.importSession?.inputRoot == f.root)
    model.importSession?.busy = true
    model.selectImportFile(f.home, for: imported)
    model.selectImportDirectory(f.home, for: imported)
    #expect(model.importSession?.file == selected)
    #expect(model.importSession?.inputRoot == f.root)
    model.importSession = nil
    model.selectImportFile(f.home, for: imported)
    model.selectImportDirectory(f.home, for: imported)
    #expect(model.importSession == nil)
    model.beginImport()
    model.selectImportFile(selected, for: imported)
    model.selectImportDirectory(f.root, for: imported)
    #expect(model.importSession?.file == nil)
    #expect(model.importSession?.inputRoot == nil)
    let currentImport = try #require(model.importSession)

    model.select(.init(kind: .user, root: f.home))
    model.selectCreationDirectory(selected, for: replacement)
    model.selectImportFile(selected, for: currentImport)
    model.selectImportDirectory(f.root, for: currentImport)
    #expect(model.creationSession?.directorySelected == false)
    #expect(model.importSession?.file == nil)
    #expect(model.importSession?.inputRoot == nil)
    try await idle(model)
    model.select(replacement.scope)
    try await idle(model)
    _ = model.requestTermination()
    #expect(model.isTerminating)
    model.selectCreationDirectory(selected, for: replacement)
    model.selectImportFile(selected, for: currentImport)
    model.selectImportDirectory(f.root, for: currentImport)
    #expect(model.creationSession?.directorySelected == false)
    #expect(model.importSession?.file == nil)
    #expect(model.importSession?.inputRoot == nil)
  }

  private func loaded(_ f: TestFixture) async -> AppModel {
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: f.environment)
    model.select(.init(kind: .project, root: f.project))
    try? await ready(model)
    return model
  }
  private func ready(_ model: AppModel) async throws {
    for _ in 0..<1600 {
      if model.operations.isEmpty && model.canModify {
        try await Task.sleep(for: .milliseconds(300))
        if model.operations.isEmpty && model.canModify { return }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Scope did not become readable")
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

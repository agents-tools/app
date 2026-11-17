import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

@Suite("Captured source and import choices", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct SelectionConsumerTests {
  @Test func explicitSourceChoiceIsPureEmptyIsNoOpAndReviewedAdditionApplies() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let boundary = try FixtureEventBoundary(root: f.root)
    defer { boundary.stop() }
    let producer = f.root.appendingPathComponent("producer")
    let input = producer.appendingPathComponent("instructions/style.md")
    try write(
      "---\ndescription: Team style\n---\n# Team\nUse a consistent style.\n", at: input)
    try await boundary.settle(creation: input, root: f.root)
    let model = await loaded(f)
    defer { _ = model.requestTermination() }
    let before = try f.entries()
    model.beginCatalog(alias: "team", source: .init(kind: .local, location: producer.path))
    model.inspectCatalog()
    try await idle(model)
    let catalog = try #require(model.catalogSession?.catalog)
    let choice = try #require(
      catalog.availableChoices.first { if case .instruction = $0.unit { true } else { false } })
    #expect(!choice.effects.isEmpty)
    #expect(choice.effects.contains { $0.kind == .instructions })
    #expect(try f.entries() == before)
    model.previewCatalogSelection()
    #expect(model.updateSession == nil)
    #expect(model.operations.isEmpty)
    model.catalogSession?.selected = [choice.id]
    model.catalogSession?.agents = [.codex]
    model.previewCatalogSelection()
    try await idle(model)
    try #require(
      model.updateSession?.report?.hasChanges == true,
      "Catalog: \(model.catalogSession?.messages.map(\.message) ?? []); review: \(model.updateSession?.messages.map(\.message) ?? []); stage: \(String(describing: model.updateSession?.stage)); stale: \(model.readsStale)"
    )
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    #expect(model.snapshot?.inspection.declaration?.sources["team"] != nil)
    #expect(model.snapshot?.inspection.components.contains { $0.kind == .instructions } == true)
    _ = model.requestTermination()
  }

  @Test func capturedSourceRequestUsesTheExistingPreviewFingerprintAndApply() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let producer = f.root.appendingPathComponent("producer")
    try write(
      "---\ndescription: Team style\n---\n# Team\nConsistent style.\n",
      at: producer.appendingPathComponent("instructions/style.md"))
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let scope = WorkspaceScope(kind: .project, root: f.project)
    var session = CatalogSession(
      scope: scope, alias: "team", source: .init(kind: .local, location: producer.path))
    guard case .catalog(_, let catalog) = actions.inspectCatalog(session).output else {
      Issue.record("Expected catalog")
      return
    }
    let choice = try #require(
      catalog.availableChoices.first { if case .instruction = $0.unit { true } else { false } })
    session.capture(catalog)
    session.selected = [choice.id]
    session.agents = [.codex]
    let before = try f.entries()
    guard case .catalogRequest(_, let request?) = actions.selectCatalog(session).output else {
      Issue.record("Expected captured addition")
      return
    }
    #expect(try f.entries() == before)
    let proposal = UpdateProposal(
      id: UUID(), scope: scope, title: "Add chosen instruction", request: request)
    guard case .updatePreview(_, let report) = actions.preview(proposal).output else {
      Issue.record("Expected actual preview")
      return
    }
    #expect(report.hasChanges)
    let applied = actions.apply(
      proposal, fingerprint: report.displayedFingerprint, admission: OperationAdmission())
    #expect(applied.updateTerminal?.disposition == .committed)
    let readback = try #require(
      CoreReader(home: f.home, processEnvironment: f.environment).read(scope: scope).snapshot)
    #expect(readback.inspection.declaration?.sources["team"] != nil)
    #expect(readback.inspection.components.contains { $0.kind == .instructions })
  }

  @Test func catalogHandlesRejectOtherInspectionsAndChangedSource() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let producer = f.root.appendingPathComponent("producer")
    let file = producer.appendingPathComponent("instructions/style.md")
    try write("---\ndescription: Original\n---\n# Original\n", at: file)
    let scope = WorkspaceScope(kind: .project, root: f.project)
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    var session = CatalogSession(
      scope: scope, alias: "team", source: .init(kind: .local, location: producer.path))
    let first = actions.inspectCatalog(session)
    let second = actions.inspectCatalog(session)
    guard case .catalog(_, let a) = first.output,
      case .catalog(_, let b) = second.output
    else {
      Issue.record(
        "Expected public catalogs: \((first.diagnostics + second.diagnostics).map(\.message))")
      return
    }
    session.capture(a)
    session.selected = [try #require(b.availableChoices.first).id]
    #expect(actions.selectCatalog(session).disposition == .failed)
    session.selected = [try #require(a.availableChoices.first).id]
    try write("---\ndescription: Changed\n---\n# Changed\n", at: file)
    let before = try f.entries()
    #expect(actions.selectCatalog(session).disposition == .failed)
    #expect(try f.entries() == before)
    session.selected = []
    let empty = actions.selectCatalog(session)
    guard case .catalogRequest(_, nil) = empty.output else {
      Issue.record("Empty catalog selection must not create a request")
      return
    }
    #expect(try f.entries() == before)
  }

  @Test func nativeAndMemberChoicesPreserveTheirActualSelectionUnits() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let producer = f.root.appendingPathComponent("extension")
    try write(
      #"{"name":"exact-package","version":"1.2.3"}"#,
      at: producer.appendingPathComponent("gemini-extension.json"))
    try write(
      "description = \"One\"\nprompt = \"First\"\n",
      at: producer.appendingPathComponent("commands/one.toml"))
    try write(
      "description = \"Two\"\nprompt = \"Second\"\n",
      at: producer.appendingPathComponent("commands/two.toml"))
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    var session = CatalogSession(
      scope: .init(kind: .project, root: f.project), alias: "extension",
      source: .init(kind: .local, location: producer.path))
    guard case .catalog(_, let catalog) = actions.inspectCatalog(session).output else {
      Issue.record("Expected plugin catalog")
      return
    }
    session.capture(catalog)
    let native = try #require(
      catalog.availableChoices.first { if case .nativePlugin = $0.unit { true } else { false } })
    #expect(native.unavailableReason == nil)
    session.selected = [native.id]
    guard case .catalogRequest(_, let nativeRequest?) = actions.selectCatalog(session).output,
      case .declaration(let declaration) = nativeRequest.operation,
      case .plugin(_, _, _, .native, let select, let exclude, let agents, _, _) = declaration
        .components.first
    else {
      Issue.record("Expected captured native registration")
      return
    }
    #expect(select == nil && exclude.isEmpty)
    #expect(agents?.count == 1)
    let members = catalog.availableChoices.filter {
      if case .pluginMember = $0.unit { true } else { false }
    }
    #expect(members.count == 2)
    session.selected = Set(members.map(\.id))
    guard case .catalogRequest(_, let memberRequest?) = actions.selectCatalog(session).output,
      case .declaration(let memberDeclaration) = memberRequest.operation,
      case .plugin(_, _, _, .components, let kinds, _, _, _, _) = memberDeclaration.components.first
    else {
      Issue.record("Expected components strategy")
      return
    }
    #expect(memberDeclaration.components.count == 1)
    #expect(kinds == [.command])
    session.selected.insert(native.id)
    #expect(actions.selectCatalog(session).disposition == .failed)
  }

  @Test func importerChoicesKeepAllFamiliesAndFixedEffectsThroughResolution() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let file = f.root.appendingPathComponent("opencode.json")
    try write(
      #"{"mcp":{"servers":{"same":{"type":"local","command":["never-run"]}}},"commands":{"same":{"template":"Review"},"other":{"template":"Other"}},"agents":{"same":{"system":"Review","mode":"subagent"}},"lsp":{"fixed":{"command":["never-run"]}}}"#,
      at: file)
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    var session = ImportSession(
      scope: .init(kind: .project, root: f.project), file: file, format: "openCodeConfigV2")
    guard
      case .sourceImport(_, let inspection) = actions.inspectImport(
        id: session.id, scope: session.scope, file: file, format: session.format
      ).output
    else {
      Issue.record("Expected import inspection")
      return
    }
    session.capture(inspection)
    let before = try f.entries()
    let shared = try #require(
      inspection.availableChoices.first { $0.effects.components.count == 3 })
    #expect(
      Set(shared.effects.components.map(\.declaration.kind)) == [.mcpServer, .command, .subagent])
    #expect(inspection.fixedEffects.components.map(\.declaration.kind) == [.lspServer])
    session.selectedChoices = [shared.id]
    #expect(session.hasPendingResolution)
    let selectionResult = actions.resolveImport(session)
    guard case .sourceImport(_, let resolved) = selectionResult.output else {
      Issue.record("Selection: \(selectionResult.diagnostics.map(\.message))")
      return
    }
    session.capture(resolved)
    #expect(!session.hasPendingResolution)
    #expect(resolved.components.count == 4)
    #expect(!resolved.availableChoices.contains { $0.id == shared.id })
    session.selectedChoices = []
    guard case .sourceImport(_, let empty) = actions.resolveImport(session).output else {
      Issue.record("Expected explicit empty conversion")
      return
    }
    #expect(empty.components.map(\.declaration.kind) == [.lspServer])
    #expect(try f.entries() == before)
  }

  @Test func explicitContentHandleRetainsIndependentIntegrityDiagnostics() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let file = f.root.appendingPathComponent("skills-lock.json")
    try write(
      "---\nname: review\ndescription: Review\n---\nReview this.\n",
      at: f.root.appendingPathComponent("skills/review/SKILL.md"))
    try write(
      "{\"version\":3,\"skills\":{\"review\":{\"source\":\"acme/repo\",\"sourceType\":\"github\",\"sourceUrl\":\"https://example.invalid/acme/repo\",\"skillFolderHash\":\""
        + String(repeating: "a", count: 40)
        + "\",\"installedAt\":\"2026-11-10T00:00:00Z\",\"updatedAt\":\"2026-11-10T00:00:00Z\"}}}",
      at: file)
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    var session = ImportSession(
      scope: .init(kind: .project, root: f.project), file: file, format: "vercelUserV3")
    guard
      case .sourceImport(_, let initial) = actions.inspectImport(
        id: session.id, scope: session.scope, file: file, format: session.format
      ).output
    else {
      Issue.record("Expected content input inspection")
      return
    }
    session.capture(initial)
    let before = try f.entries()
    let input = try #require(initial.requiredInputs.first { $0.kind == .explicitContent })
    session.inputs[input.id]?.enabled = true
    session.inputs[input.id]?.path = "../escape"
    let escaped = actions.resolveImport(session)
    #expect(escaped.disposition == .failed)
    #expect(!escaped.diagnostics.isEmpty)
    session.inputs[input.id]?.path = "skills/review"
    let result = actions.resolveImport(session)
    guard case .sourceImport(_, let resolved) = result.output else {
      Issue.record("Content: \(result.diagnostics.map(\.message))")
      return
    }
    #expect(
      resolved.resources.contains { $0.hash != nil && $0.requiresStandaloneSource },
      "\(resolved.diagnostics.map(\.message))")
    #expect(!resolved.diagnostics.isEmpty)
    #expect(!resolved.requiredInputs.contains { $0.kind == .explicitContent })
    #expect(try f.entries() == before)
  }

  @Test func symbolicResolutionCannotClearRawResourceAdmission() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let boundary = try FixtureEventBoundary(root: f.root)
    defer { boundary.stop() }
    let file = f.root.appendingPathComponent("settings.json")
    try write(
      #"{"mcpServers":{"review":{"command":"never-run","env":{"TOKEN":"PRIVATE_LITERAL_CANARY"}}}}"#,
      at: file)
    try await boundary.settle(creation: file, root: f.root)
    let model = await loaded(f)
    defer { _ = model.requestTermination() }
    let before = try f.entries()
    model.beginImport()
    model.importSession?.file = file
    model.importSession?.format = "claudeSettingsV1"
    model.inspectImport()
    try await idle(model)
    let initial = try #require(model.importSession?.inspection)
    let slot = try #require(initial.requiredInputs.first { $0.kind == .bindingReference })
    #expect(!String(reflecting: initial).contains("PRIVATE_LITERAL_CANARY"))
    model.importSession?.inputs[slot.id]?.enabled = true
    model.importSession?.inputs[slot.id]?.reference = .secret
    model.importSession?.inputs[slot.id]?.name = "review-token"
    model.resolveImportSelection()
    try await idle(model)
    let resolved = try #require(model.importSession?.inspection)
    #expect(resolved.bindings.isEmpty)
    #expect(resolved.resources.contains { $0.selected && $0.requiresBindingRewrite })
    #expect(model.importSession?.rawResourcesBlocked == true)
    model.reviewImport()
    #expect(model.updateSession == nil)
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let result = actions.importRequest(
      id: UUID(), scope: model.scope, imported: resolved,
      inspection: try #require(model.snapshot?.inspection))
    #expect(result.disposition == .failed)
    #expect(!result.diagnostics.isEmpty)
    #expect(try f.entries() == before)
    _ = model.requestTermination()
  }

  @Test func catalogScopeChangeAndQueuedQuitCannotPublishObsoleteChoices() async throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let producer = f.root.appendingPathComponent("producer")
    try write(
      "---\ndescription: Team\n---\n# Team\n",
      at: producer.appendingPathComponent("instructions/style.md"))
    let model = await loaded(f)
    defer { _ = model.requestTermination() }
    let gate = SelectionWorkerGate()
    defer { gate.release() }
    var events = gate.events.makeAsyncIterator()
    model.startOperation(title: "Held selection fixture", scope: model.scope) {
      gate.wait()
      return .init(disposition: .completed)
    }
    _ = await events.next()
    model.beginCatalog(alias: "team", source: .init(kind: .local, location: producer.path))
    model.inspectCatalog()
    #expect(model.catalogSession?.busy == true)
    model.select(.init(kind: .user, root: f.home))
    gate.release()
    try await idle(model)
    #expect(model.catalogSession?.busy == false)
    #expect(model.catalogSession?.stale == true)
    #expect(model.catalogSession?.catalog == nil)
    #expect(model.scope.kind == .user)
    model.select(.init(kind: .project, root: f.project))
    try await idle(model)
    let quitGate = SelectionWorkerGate()
    defer { quitGate.release() }
    var quitEvents = quitGate.events.makeAsyncIterator()
    model.startOperation(title: "Held selection quit fixture", scope: model.scope) {
      quitGate.wait()
      return .init(disposition: .completed)
    }
    _ = await quitEvents.next()
    model.beginCatalog(alias: "team", source: .init(kind: .local, location: producer.path))
    model.inspectCatalog()
    #expect(model.requestTermination() == .later)
    quitGate.release()
    try await idle(model)
    #expect(model.catalogSession?.busy == false)
    #expect(model.catalogSession?.catalog == nil)
    #expect(
      model.catalogSession?.messages.contains {
        $0.message == "Queued source operation was cancelled."
      } == true)
    #expect(model.operations.isEmpty)
  }

  private func loaded(_ f: TestFixture) async -> AppModel {
    let model = AppModel(
      home: f.home, preferences: AppPreferences(defaults: nil), processEnvironment: f.environment)
    model.select(.init(kind: .project, root: f.project))
    try? await idle(model)
    return model
  }
  private func idle(_ model: AppModel) async throws {
    for _ in 0..<1500 {
      if model.operations.isEmpty {
        try await Task.sleep(for: .milliseconds(300))
        if model.operations.isEmpty { return }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Operation did not reach its outer terminal")
  }
  private func write(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
}

private final class SelectionWorkerGate: @unchecked Sendable {
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

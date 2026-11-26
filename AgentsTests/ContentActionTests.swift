import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import SwiftUI
import Testing

@testable import AgentsApp

@Suite("Explicit content actions", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ContentActionTests {
  @Test func creationRequiresConfirmationAndCannotOverwriteOrInstall() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.select(.init(kind: .project, root: fixture.project))
    try await idle(model)
    let before = try fixture.entries()
    model.beginCreation(.instructions)
    model.creationSession?.name = "project-style"
    model.confirmCreation()
    #expect(try fixture.entries() == before)
    model.reviewCreation()
    try await idle(model)
    model.confirmCreation()
    try await idle(model)
    guard case .created(let file) = model.creationSession?.stage else {
      Issue.record("Expected the confirmed creation to return its actual author file")
      return
    }
    #expect(try String(contentsOf: file, encoding: .utf8).contains("# project-style"))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent(".agent/agents.yaml").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent(".agent/agents.resolved").path))
    let created = try fixture.entries()
    model.beginCreation(.instructions)
    model.creationSession?.name = "project-style"
    model.reviewCreation()
    try await idle(model)
    model.confirmCreation()
    try await idle(model)
    #expect(try fixture.entries() == created)
    #expect(model.diagnostics.contains { $0.message.contains("already exists") })
    guard case .failed = model.creationSession?.stage else {
      Issue.record("Existing content was not rejected by the typed creation path")
      return
    }

    model.beginCreation(.skill)
    model.reviewCreation()
    try await idle(model)
    model.confirmCreation()
    #expect(try fixture.entries() == created)
    model.selectCreationDirectory(fixture.root.appendingPathComponent("selected-skill-directory"))
    model.reviewCreation()
    try await idle(model)
    model.confirmCreation()
    try await idle(model)
    guard case .created(let directory) = model.creationSession?.stage else {
      Issue.record("Expected selected-directory skill creation")
      return
    }
    #expect(directory.path == fixture.root.appendingPathComponent("selected-skill-directory").path)
    #expect(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path))
    let skillCreated = try fixture.entries()
    model.beginCreation(.skill)
    model.selectCreationDirectory(directory)
    model.reviewCreation()
    try await idle(model)
    model.confirmCreation()
    try await idle(model)
    #expect(try fixture.entries() == skillCreated)
  }

  @Test func userScopeCannotCreateProjectInstructions() {
    let scope = WorkspaceScope(kind: .user, root: URL(fileURLWithPath: "/unused-fixture-home"))
    let model = AppModel(
      home: scope.root, preferences: AppPreferences(defaults: nil), processEnvironment: [:])
    model.beginCreation(.instructions)
    #expect(model.creationSession == nil)
    let result = CoreActions(home: scope.root, processEnvironment: [:]).create(
      .init(id: UUID(), scope: scope, kind: .instructions, directory: scope.root, name: "rules"))
    #expect(result.disposition == .failed)
    #expect(result.diagnostics.contains { $0.message.contains("only be created in a project") })
  }

  @Test func namedPromptUsesLockedOrderAndCurrentConsumerAppendWithoutWritingState() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "first", environment: runtime)
    _ = try InstructionOperations.initializeInstructions(named: "second", environment: runtime)
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: [codex]
      components:
        - kind: instructions
          sections: [{name: first}, {name: second}]
          chatgpt:
            daily:
              sections: [{name: second}, {name: first}]
              append: custom.md
      """)
    let append = fixture.project.appendingPathComponent("custom.md")
    try Data("First appendix".utf8).write(to: append)
    _ = try InstructionOperations.updateInstalled(environment: runtime, apply: true)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)
    let before = try fixture.entries()
    model.previewPrompt(name: "daily", in: scope)
    try await idle(model)
    guard case .ready(let text) = model.promptSession?.stage else {
      Issue.record("Expected real Core prompt content")
      return
    }
    let second = try #require(text.range(of: "# second"))
    let first = try #require(text.range(of: "# first"))
    #expect(second.lowerBound < first.lowerBound)
    #expect(text.hasSuffix("First appendix"))
    #expect(try fixture.entries() == before)
    try Data("Current appendix".utf8).write(to: append)
    let changed = try fixture.entries()
    for _ in 0..<4 {
      model.refresh()
      try await idle(model)
      model.previewPrompt(name: "daily", in: scope)
      try await idle(model)
      if case .ready = model.promptSession?.stage { break }
    }
    guard case .ready(let current) = model.promptSession?.stage else {
      Issue.record("Expected the current consumer append")
      return
    }
    #expect(current.hasSuffix("Current appendix"))
    #expect(!current.contains("First appendix"))
    #expect(try fixture.entries() == changed)
    let mapping = try #require(model.snapshot?.mappings.first { $0.scope == scope })
    #expect(mapping.copyText.contains("Prompt: daily\nSection: .:second\nSection: .:first"))
    #expect(mapping.copyText.contains("Target: AGENTS.md"))
  }

  @Test func instructionDraftAndBuildExposeTheSameFullOutputsBeforeInstallation() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "shared", environment: runtime)
    _ = try InstructionOperations.initializeInstructions(named: "both", environment: runtime)
    let source = fixture.project.appendingPathComponent("producer/instructions")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("---\ndescription: Producer fixture\n---\n# Producer rules\nFull body café.\n".utf8)
      .write(to: source.appendingPathComponent("shared.md"))
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: [codex]
      sources: {team: {path: ./producer}}
      components:
        - kind: instructions
          sections: [{name: shared}, {name: shared, source: team}, {name: both}]
      """)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)
    model.selectedItem = try #require(model.snapshot?.instructions.first?.id)
    model.editSelectedDeclaration()
    let draft = try #require(model.manifestDraft)
    var sections = draft.component.instructions.sectionReferences
    #expect(sections.map(\.reference) == ["shared", "team:shared", "both"])

    let appOnly = InstructionRecipientsEditor(
      section: Binding(get: { sections[1] }, set: { sections[1] = $0 }), scope: .project,
      defaultAgents: [.codex])
    appOnly.selection(for: .chatGPTApp).wrappedValue = true
    appOnly.selection(for: .geminiApp).wrappedValue = true
    #expect(sections[1].recipients == [.local(.codex), .chatGPTApp, .geminiApp])
    appOnly.selection(for: .local(.codex)).wrappedValue = false
    let mixed = InstructionRecipientsEditor(
      section: Binding(get: { sections[2] }, set: { sections[2] = $0 }), scope: .project,
      defaultAgents: [.codex])
    mixed.selection(for: .chatGPTApp).wrappedValue = true
    model.manifestDraft?.component.instructions.sectionReferences = sections

    let before = try fixture.entries()
    let localFile = fixture.project.appendingPathComponent("AGENTS.md")
    model.previewDraft()
    try await idle(model)
    let review = try #require(model.updateSession?.report)
    #expect(try fixture.entries() == before)
    #expect(!FileManager.default.fileExists(atPath: localFile.path))
    #expect(
      Set(review.instructions.outputs.map(\.recipient)) == [
        .local(.codex), .chatGPTApp, .geminiApp,
      ])
    let local = try #require(review.instructions.outputs.first { $0.recipient == .local(.codex) })
    let chatGPT = try #require(review.instructions.outputs.first { $0.recipient == .chatGPTApp })
    let gemini = try #require(review.instructions.outputs.first { $0.recipient == .geminiApp })
    let localText = try #require(local.fullText)
    let chatGPTText = try #require(chatGPT.fullText)
    let geminiText = try #require(gemini.fullText)
    #expect(local.fileURL?.path == localFile.path)
    #expect(localText.contains("# shared") && localText.contains("# both"))
    #expect(!localText.contains("Producer rules"))
    #expect(chatGPT.fileURL == nil && gemini.fileURL == nil)
    #expect(chatGPTText.contains("Full body café.") && chatGPTText.contains("# both"))
    #expect(geminiText.contains("Full body café.") && !geminiText.contains("# both"))
    #expect(Data(chatGPTText.utf8) == chatGPT.content)
    #expect(
      local.content == review.instructions.targets.first { $0.url.path == localFile.path }?.after)

    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    let saved = try #require(model.snapshot?.inspection.declaration)
    #expect(try saved.instructions?.sectionReferences == sections)
    #expect(try Data(contentsOf: localFile) == local.content)
    let resolved = try #require(model.snapshot?.inspection.components)
    let resolvedAppOnly = try #require(
      resolved.first { $0.name == "shared" && $0.recipients.isEmpty })
    #expect(Set(resolvedAppOnly.copyRecipients) == [.chatGPTApp, .geminiApp])
    let resolvedMixed = try #require(resolved.first { $0.name == "both" })
    #expect(resolvedMixed.recipients == [.codex])
    #expect(resolvedMixed.copyRecipients == [.chatGPTApp])
    let snapshot = try #require(model.snapshot)
    let destinations = InstructionAppDestination.inScope(scope, snapshot: snapshot)
    #expect(destinations.allSatisfy { $0.hasResolvedUnits == true })
    model.closeUpdateReview()

    try FileManager.default.removeItem(at: localFile)
    model.refresh()
    try await idle(model)
    let beforeBuild = try fixture.entries()
    model.previewUpdate(UpdateProposal(compilingInstructionsIn: scope))
    try await idle(model)
    let build = try #require(model.updateSession?.report)
    #expect(build.instructions.outputs == review.instructions.outputs)
    #expect(model.updateSession?.canApplyReport == true)
    #expect(try fixture.entries() == beforeBuild)

    model.clientFilter = .codex
    for (focus, expected) in [
      (InstructionOutputFocus.app(.geminiApp), gemini),
      (.local(file: localFile, recipient: .codex), local),
    ] {
      model.closeUpdateReview()
      model.previewUpdate(UpdateProposal(compilingInstructionsIn: scope, focus: focus))
      try await idle(model)
      let preview = try #require(model.updateSession)
      #expect(preview.stage == .review)
      #expect(preview.proposal.scope == scope)
      #expect(preview.instructionOutputs == [expected])
      #expect(!preview.offersApply && !preview.canApplyReport)
      model.confirmUpdate()
      #expect(try fixture.entries() == beforeBuild)
    }
  }

  @Test func unconfiguredAppDestinationsAreVisibleAndPreviewTheirOwnEmptyOutput() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "rules", environment: runtime)
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: [codex]
      components:
        - kind: instructions
          sections: [{name: rules}]
      """)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let userScope = WorkspaceScope(kind: .user, root: fixture.home)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.select(scope)
    try await idle(model)
    let snapshot = try #require(model.snapshot)
    let destinations = InstructionAppDestination.inScope(scope, snapshot: snapshot)
    #expect(destinations.map(\.recipient) == [.chatGPTApp, .geminiApp])
    #expect(destinations.allSatisfy { $0.hasResolvedUnits == false })
    let otherDestinations = InstructionAppDestination.inScope(userScope, snapshot: snapshot)
    #expect(otherDestinations.allSatisfy { $0.hasResolvedUnits == nil })

    let before = try fixture.entries()
    let focus = InstructionOutputFocus.app(.chatGPTApp)
    model.previewUpdate(UpdateProposal(compilingInstructionsIn: userScope, focus: focus))
    #expect(model.updateSession == nil)
    model.previewUpdate(UpdateProposal(compilingInstructionsIn: scope, focus: focus))
    try await idle(model)
    let preview = try #require(model.updateSession)
    #expect(preview.stage == .review)
    #expect(preview.report?.instructions.outputs.map(\.recipient) == [.local(.codex)])
    #expect(preview.instructionOutputs.isEmpty)
    #expect(preview.instructionOutputFocus?.emptyMessage.contains("ChatGPT App") == true)
    #expect(!preview.offersApply)
    #expect(try fixture.entries() == before)
  }

  @Test func copyOnlyBuildNeverOffersLocalApply() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "copy", environment: runtime)
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: [codex]
      components:
        - kind: instructions
          sections: [{name: copy, recipients: [chatgpt-app, gemini-app]}]
      """)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.select(scope)
    try await idle(model)
    let before = try fixture.entries()
    let otherScope = WorkspaceScope(kind: .user, root: fixture.home)
    model.previewUpdate(UpdateProposal(compilingInstructionsIn: otherScope))
    #expect(model.updateSession == nil)
    model.previewUpdate(UpdateProposal(compilingInstructionsIn: scope))
    try await idle(model)
    let session = try #require(model.updateSession)
    let report = try #require(session.report)
    #expect(session.stage == .review)
    #expect(Set(report.instructions.outputs.map(\.recipient)) == [.chatGPTApp, .geminiApp])
    #expect(report.instructions.outputs.allSatisfy { $0.fileURL == nil })
    #expect(report.instructions.targets.isEmpty)
    #expect(!session.canApplyReport && !session.offersApply)
    model.confirmUpdate()
    try await idle(model)
    #expect(try fixture.entries() == before)
  }

  @Test func quitCancelsQueuedCreationAndConsumesItsTerminal() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let (events, entered) = AsyncStream.makeStream(of: Void.self)
    model.startOperation(title: "Blocked read", scope: model.scope) {
      entered.yield(())
      gate.wait()
      return CoreCompletion(disposition: .completed)
    }
    var event = events.makeAsyncIterator()
    _ = await event.next()
    let destination = fixture.root.appendingPathComponent("never-created")
    model.beginCreation(.skill)
    model.selectCreationDirectory(destination)
    model.reviewCreation()
    let (replies, reply) = AsyncStream.makeStream(of: Bool.self)
    model.terminationReply = { reply.yield($0) }
    #expect(model.requestTermination() == .later)
    gate.signal()
    var termination = replies.makeAsyncIterator()
    #expect(await termination.next() == true)
    #expect(model.operations.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    guard case .cancelled = model.creationSession?.stage else {
      Issue.record("Queued creation lost its cancellation terminal")
      return
    }
  }

  @Test func obsoletePromptErrorsAreKeptWithoutReplacingTheNewScope() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let oldScope = model.scope
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let (events, entered) = AsyncStream.makeStream(of: Void.self)
    model.startOperation(title: "Blocked read", scope: oldScope) {
      entered.yield(())
      gate.wait()
      return CoreCompletion(disposition: .completed)
    }
    var event = events.makeAsyncIterator()
    _ = await event.next()
    model.previewPrompt(name: "absent", in: oldScope)
    let selected = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(selected)
    gate.signal()
    try await idle(model)
    #expect(model.snapshot?.scope == selected)
    #expect(
      model.diagnostics.contains {
        $0.scope == oldScope && $0.operation.contains("Generate prompt")
      })
    guard case .outdated = model.promptSession?.stage else {
      Issue.record("Obsolete prompt retained current content")
      return
    }
  }

  @Test func selectedProjectMappingsIncludeMissingScopesWithoutWriting() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let second = fixture.root.appendingPathComponent("second-project", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let preferences = AppPreferences(defaults: nil, initialProjects: [fixture.project, second])
    let model = AppModel(
      home: fixture.home, preferences: preferences, processEnvironment: fixture.environment)
    model.chooseMappings()
    model.mappingSession?.selectedProjects = [fixture.project, second]
    let before = try fixture.entries()
    model.readMappings()
    try await idle(model)
    guard case .loaded(let mappings) = model.mappingSession?.stage else {
      Issue.record("No mapping terminal")
      return
    }
    #expect(
      Set(mappings.map { $0.scope.root.path })
        == Set([fixture.home.path, fixture.project.path, second.path]))
    #expect(mappings.allSatisfy { $0.status == "No resolved instruction mapping" })
    #expect(mappings.allSatisfy { $0.copyText.contains($0.scope.root.path) })
    #expect(try fixture.entries() == before)
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

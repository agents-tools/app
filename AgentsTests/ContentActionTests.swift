import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
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

  @Test func webDestinationsStartEmptyAndRenderIndependentSelectionsWithoutLocalOutputs()
    async throws
  {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    for name in ["first", "second"] {
      _ = try InstructionOperations.initializeInstructions(named: name, environment: runtime)
    }
    try fixture.writeManifest(
      """
      version: 1
      components:
        - kind: instructions
          agents: [codex]
          sections: [{name: first}]
      """)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)

    let before = try fixture.entries()
    for (destination, selection) in [
      (WebInstructionDestination.chatGPT, ["second", "first"]), (.gemini, ["first"]),
    ] {
      let snapshot = try #require(model.snapshot)
      let configuration = WebInstructionConfiguration(
        destination, snapshot: snapshot, environment: runtime)
      #expect(!configuration.hasNamedPrompt)
      #expect(configuration.choices == ["first", "second"])
      model.saveWebInstructionSelection(selection, in: configuration)
      #expect(model.preferences.webInstructionSelections[configuration.preferenceKey] == selection)
      #expect(model.updateSession == nil)
      model.confirmUpdate()
    }

    let snapshot = try #require(model.snapshot)
    let mapping = try #require(snapshot.mappings.first { $0.scope == scope })
    #expect(mapping.targets.isEmpty)
    for (destination, headings) in [
      (WebInstructionDestination.chatGPT, ["# second", "# first"]), (.gemini, ["# first"]),
    ] {
      let configuration = WebInstructionConfiguration(
        destination, snapshot: snapshot, environment: runtime)
      let selection = try #require(
        model.preferences.webInstructionSelections[configuration.preferenceKey])
      model.previewWebInstructionSelection(selection, in: configuration)
      try await idle(model)
      guard case .ready(let preview) = model.promptSession?.stage else {
        Issue.record("Expected the configured destination’s rendered text")
        return
      }
      #expect(
        preview.split(separator: "\n").filter { $0.hasPrefix("# ") }.map(String.init) == headings)
      var copied: String?
      model.copyInstructionPreview {
        copied = $0
        return true
      }
      #expect(copied == preview)
      model.promptSession = nil
    }
    #expect(try fixture.entries() == before)
  }

  @Test func webPreviewKeepsMissingAndDriftedDeploymentsAndTheirLock() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "shared", environment: runtime)
    try fixture.writeManifest(
      """
      version: 1
      components:
        - kind: instructions
          agents: [codex, gemini-cli]
          sections: [{name: shared}]
      """)
    _ = try InstructionOperations.updateInstalled(environment: runtime, apply: true)
    let codex = fixture.project.appendingPathComponent("AGENTS.md")
    let gemini = fixture.project.appendingPathComponent("GEMINI.md")
    let drifted = Data("# Locally changed\n".utf8)
    try drifted.write(to: codex)
    try FileManager.default.removeItem(at: gemini)
    let store = StateStore(scope: .project, environment: runtime)
    let lock = try Data(contentsOf: store.resolvedURL)
    let before = try fixture.entries()

    // A named prompt has a destination ID, but the public selector operates on unit names.
    let operation = UpdateOperation.edit([
      .insertComponent(
        .instructions(.init(agents: [], chatgpt: ["chatgpt-web": .init(sections: ["shared"])])),
        into: .root, at: .last)
    ])
    #expect(throws: CoreError.self) {
      try UpdateOperations.preview(
        .init(operation: operation, kinds: [.instructions], names: ["chatgpt-web"]),
        environment: runtime)
    }
    let unitPlan = try UpdateOperations.preview(
      .init(operation: operation, kinds: [.instructions], names: ["shared"]),
      environment: runtime)
    #expect(unitPlan.instructions.changedPrompts == ["chatgpt-web"])
    #expect(
      Set(unitPlan.instructions.targets.filter(\.changed).map(\.target)) == [
        "AGENTS.md", "GEMINI.md",
      ])

    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)
    let configuration = WebInstructionConfiguration(
      .chatGPT, snapshot: try #require(model.snapshot), environment: runtime)
    model.saveWebInstructionSelection(["shared"], in: configuration)
    model.confirmUpdate()
    #expect(model.updateSession == nil)
    model.previewWebInstructionSelection(["shared"], in: configuration)
    try await idle(model)
    var copied: String?
    model.copyInstructionPreview {
      copied = $0
      return true
    }
    #expect(copied?.hasPrefix("# shared\n") == true)
    #expect(try Data(contentsOf: codex) == drifted)
    #expect(!FileManager.default.fileExists(atPath: gemini.path))
    #expect(try Data(contentsOf: store.resolvedURL) == lock)
    #expect(try fixture.entries() == before)
  }

  @Test func webChoicesIgnoreInactiveGroupsAndKeepImportedNamedPromptSeparate() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "own", environment: runtime)
    let producer = fixture.root.appendingPathComponent("producer")
    let producerRuntime = RuntimeEnvironment(
      projectDirectory: producer, homeDirectory: fixture.home, environment: fixture.environment)
    try FileManager.default.createDirectory(at: producer, withIntermediateDirectories: true)
    _ = try InstructionOperations.initializeInstructions(
      named: "upstream", environment: producerRuntime)
    let sourceUnits = producer.appendingPathComponent("instructions")
    try FileManager.default.createDirectory(at: sourceUnits, withIntermediateDirectories: true)
    for name in ["active-unit", "conditional-unit"] {
      try Data("---\ndescription: A source instruction.\n---\n# \(name)\nFull body.\n".utf8)
        .write(to: sourceUnits.appendingPathComponent(name + ".md"))
    }
    let producerManifest = producer.appendingPathComponent(".agent/agents.yaml")
    try Data(
      """
      version: 1
      groups:
        published:
          components:
            - kind: instructions
              chatgpt:
                gemini-web: {sections: [{name: upstream}]}
      exports: [published]
      """.utf8
    ).write(to: producerManifest)
    try fixture.writeManifest(
      """
      version: 1
      sources: {team: {path: ../producer}}
      groups:
        active-here:
          components:
            - kind: instructions
              agents: []
              sections: [{name: active-unit, source: team}]
        unused:
          components:
            - kind: instructions
              chatgpt:
                gemini-web: {sections: [{name: unused-unit, source: team}]}
        inactive-here:
          condition: {scopes: [user]}
          components:
            - kind: instructions
              chatgpt:
                gemini-web: {sections: [{name: conditional-unit, source: team}]}
      uses: [{group: active-here}, {group: inactive-here}, {group: published, source: team}]
      """)
    _ = try InstructionOperations.updateInstalled(environment: runtime, apply: true)
    let named = try InstructionOperations.renderChatGPT(prompt: "gemini-web", environment: runtime)
    let before = try fixture.entries()
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)
    let configuration = WebInstructionConfiguration(
      .gemini, snapshot: try #require(model.snapshot), environment: runtime)
    #expect(configuration.hasNamedPrompt)
    #expect(configuration.choices == ["own", "team:active-unit"])
    #expect(model.preferences.webInstructionSelections[configuration.preferenceKey] == nil)

    let selection = ["own", "team:active-unit"]
    model.saveWebInstructionSelection(selection, in: configuration)
    model.previewWebInstructionSelection(selection, in: configuration)
    try await idle(model)
    guard case .ready(let text) = model.promptSession?.stage else {
      Issue.record("Expected an independent Gemini Web composition")
      return
    }
    #expect(text.hasPrefix("# own\n"))
    #expect(text.contains("# active-unit\nFull body.\n"))
    #expect(String(decoding: named, as: UTF8.self).hasPrefix("# upstream\n"))
    #expect(
      try InstructionOperations.renderChatGPT(prompt: "gemini-web", environment: runtime) == named)
    #expect(try fixture.entries() == before)
  }

  @Test func webCompositionPreservesExistingNamedPromptsAndTheirCustomAppends() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    for name in ["first", "second"] {
      _ = try InstructionOperations.initializeInstructions(named: name, environment: runtime)
    }
    try fixture.writeManifest(
      """
      version: 1
      components:
        - kind: instructions
          chatgpt:
            daily: { sections: [{name: first}], append: daily.md }
            chatgpt-web: { sections: [{name: first}], append: custom.md }
      """)
    try Data("Daily appendix".utf8).write(to: fixture.project.appendingPathComponent("daily.md"))
    try Data("Destination appendix".utf8).write(
      to: fixture.project.appendingPathComponent("custom.md"))
    _ = try InstructionOperations.updateInstalled(environment: runtime, apply: true)
    let daily = try InstructionOperations.renderChatGPT(prompt: "daily", environment: runtime)
    let named = try InstructionOperations.renderChatGPT(prompt: "chatgpt-web", environment: runtime)
    let before = try fixture.entries()
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.select(scope)
    try await idle(model)
    let snapshot = try #require(model.snapshot)
    let configuration = WebInstructionConfiguration(
      .chatGPT, snapshot: snapshot, environment: runtime)
    #expect(configuration.hasNamedPrompt)
    model.saveWebInstructionSelection(["second"], in: configuration)
    model.previewWebInstructionSelection(["second"], in: configuration)
    try await idle(model)
    guard case .ready(let composed) = model.promptSession?.stage else {
      Issue.record("Expected the app's independent composition")
      return
    }
    #expect(composed.hasPrefix("# second"))
    model.previewPrompt(name: "chatgpt-web", in: scope)
    try await idle(model)
    guard case .ready(let previous) = model.promptSession?.stage else {
      Issue.record("Expected the original named prompt")
      return
    }
    #expect(Data(previous.utf8) == named)
    #expect(previous.hasSuffix("Destination appendix"))
    #expect(try InstructionOperations.renderChatGPT(prompt: "daily", environment: runtime) == daily)
    #expect(try fixture.entries() == before)
  }

  @Test func mappedCopyReturnsExactSharedBytesAndRejectsDriftAndSymlinks() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home,
      environment: fixture.environment)
    _ = try InstructionOperations.initializeInstructions(named: "shared", environment: runtime)
    let claude = fixture.project.appendingPathComponent(".claude/CLAUDE.md")
    try FileManager.default.createDirectory(
      at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("Handwritten Claude notes\n".utf8).write(to: claude)
    try fixture.writeManifest(
      """
      version: 1
      components:
        - kind: instructions
          agents: [claude-code, codex]
          sections: [{name: shared}]
      """)
    _ = try InstructionOperations.updateInstalled(environment: runtime, apply: true)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    let scope = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(scope)
    try await idle(model)
    let mapping = try #require(model.snapshot?.mappings.first { $0.scope == scope })
    let shared = try #require(mapping.targets.first { $0.id == "AGENTS.md" })
    let forwarding = try #require(mapping.targets.first { $0.id == ".claude/CLAUDE.md" })
    let before = try fixture.entries()
    let sharedURL = fixture.project.appendingPathComponent("AGENTS.md")
    let bytes = try Data(contentsOf: sharedURL)
    let expected = try #require(String(data: bytes, encoding: .utf8))
    var clipboard: [String] = []
    for target in [shared, forwarding] {
      model.copyMappedInstructions(target, in: scope) {
        clipboard.append($0)
        return true
      }
      try await idle(model)
      #expect(model.promptSession?.clipboardResult == true)
      model.promptSession = nil
    }
    #expect(clipboard == [expected, expected])
    #expect(try fixture.entries() == before)

    let actions = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
    func read(_ target: MappingTarget) -> CoreCompletion {
      actions.render(
        .init(id: UUID(), scope: scope, content: .mapped(target), title: "Copy Full Text"))
    }
    try Data("Drifted".utf8).write(to: sharedURL)
    #expect(read(shared).diagnostics.contains { $0.message.contains("differs from its lock") })
    try FileManager.default.removeItem(at: sharedURL)
    let outside = fixture.root.appendingPathComponent("outside")
    try Data(bytes).write(to: outside)
    try FileManager.default.createSymbolicLink(at: sharedURL, withDestinationURL: outside)
    #expect(read(shared).disposition == .failed)
    try FileManager.default.removeItem(at: sharedURL)
    try bytes.write(to: sharedURL)
    let claudeDirectory = claude.deletingLastPathComponent()
    let moved = fixture.root.appendingPathComponent("outside-claude")
    try FileManager.default.moveItem(at: claudeDirectory, to: moved)
    try FileManager.default.createSymbolicLink(at: claudeDirectory, withDestinationURL: moved)
    #expect(read(forwarding).disposition == .failed)
    let arbitrary = MappingTarget(
      id: outside.path, recipients: [.codex], sections: shared.sections, importedFile: nil)
    #expect(read(arbitrary).disposition == .failed)
  }

  @Test func mappedUserCopyUsesTheConfiguredClientHomeAndKeepsProjectScopeSeparate() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let codexHome = fixture.root.appendingPathComponent("custom-codex")
    let environment = fixture.environment.merging(["CODEX_HOME": codexHome.path]) { _, new in new }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.project, homeDirectory: fixture.home, environment: environment)
    let source = fixture.root.appendingPathComponent("source/instructions")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("---\ndescription: User fixture\n---\n# User rules\nFull body.\n".utf8)
      .write(to: source.appendingPathComponent("user.md"))
    try fixture.writeManifest(
      """
      version: 1
      sources: {fixture: {path: "\(source.deletingLastPathComponent().path)"}}
      components:
        - kind: instructions
          agents: [codex]
          sections: [{name: user, source: fixture}]
      """, user: true)
    _ = try InstructionOperations.updateInstalled(scope: .user, environment: runtime, apply: true)
    let user = WorkspaceScope(kind: .user, root: fixture.home)
    let project = WorkspaceScope(kind: .project, root: fixture.project)
    let reader = CoreReader(home: fixture.home, processEnvironment: environment)
    let snapshot = try #require(reader.read(scope: project).snapshot)
    let target = try #require(snapshot.mappings.first { $0.scope == user }?.targets.first)
    let file = codexHome.appendingPathComponent("AGENTS.md")
    #expect(target.id == file.path)
    let before = try fixture.entries()
    let actions = CoreActions(home: fixture.home, processEnvironment: environment)
    let result = actions.render(
      .init(id: UUID(), scope: user, content: .mapped(target), title: "Copy Full Text"))
    guard case .prompt(_, let text) = result.output else {
      Issue.record("Expected the mapped user output: \(result.diagnostics.map(\.message))")
      return
    }
    #expect(Data(text.utf8) == (try Data(contentsOf: file)))
    let wrongScope = actions.render(
      .init(id: UUID(), scope: project, content: .mapped(target), title: "Copy Full Text"))
    #expect(wrongScope.disposition == .failed)
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

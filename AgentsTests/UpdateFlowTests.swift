import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation
import SwiftUI
import Testing

@testable import AgentsApp

@Suite("Native configuration lifecycle", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct UpdateFlowTests {
  @Test func firstConfigurationRequiresReviewAndPublishesThroughCore() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = await loadedModel(fixture)
    let before = try fixture.entries()
    model.beginDraft(.defaults)
    model.manifestDraft?.defaultAgents = []
    try await reviewed(model) { model.previewDraft() }
    #expect(try fixture.entries() == before)
    #expect(model.updateSession?.report?.hasChanges == true)
    #expect(model.updateSession?.closeTitle == "Cancel")
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    #expect(model.snapshot?.inspection.declaration?.agents == [])
    #expect(model.snapshot?.inspection.generation != nil)
    #expect(model.snapshot?.inspection.recovery.pending == false)
    #expect(model.updateSession?.terminal?.disposition == .committed)
    #expect(model.updateSession?.closeTitle == "Done")
    #expect(model.manifestDraft != nil)
    model.closeUpdateReview()
    #expect(model.manifestDraft == nil)
    #expect(model.updateSession == nil)
  }

  @Test func editHydratesActualFieldsAndPreservesExactArgumentsCommentsAndNativeValues()
    async throws
  {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      """
      # Keep this author comment.
      version: 1
      defaultAgents: []
      components:
        - kind: mcpServer
          name: tools
          transport:
            kind: stdio
            executable: fixture-command
            arguments: ['', "a\\nb", repeated, repeated]
          native:
            codex:
              '': null
              exact: 1.234567890123456789
      """)
    let model = await loadedModel(fixture)
    model.selectedItem = try #require(model.snapshot?.components.first?.id)
    model.editSelectedDeclaration()
    #expect(
      model.manifestDraft?.component.transport
        == .stdio(
          .init(executable: "fixture-command", arguments: ["", "a\nb", "repeated", "repeated"])))
    let draft = try #require(model.manifestDraft)
    var executable: ExecutableDeclaration
    guard case .stdio(let actual) = draft.component.transport else {
      Issue.record("Expected stdio")
      return
    }
    executable = actual
    let binding = Binding(get: { executable }, set: { executable = $0 })
    var ids = executable.arguments.map { _ in UUID() }
    let rows = ArgumentRows(
      values: ExecutableEditor(value: binding).arguments,
      identities: Binding(get: { ids }, set: { ids = $0 }))
    rows.text(for: ids[1]).wrappedValue = "changed\nargument"
    model.manifestDraft?.component.transport = .stdio(executable)
    let before = try fixture.entries()
    try await reviewed(model) { model.previewDraft() }
    #expect(try fixture.entries() == before)
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    let declaration = try #require(model.snapshot?.inspection.declaration)
    guard case .mcpServer(_, let transport, _, _, let native, _) = declaration.components[0] else {
      Issue.record("Expected server")
      return
    }
    #expect(transport == .stdio(executable))
    #expect(native["codex"]?[""] == .null)
    #expect(native["codex"]?["exact"] == .decimal("1.234567890123456789"))
    #expect(
      String(decoding: model.snapshot!.document!.bytes, as: UTF8.self).contains(
        "# Keep this author comment."))
  }

  @Test func changedDiskRejectsDisplayedPreviewWithoutOverwritingIt() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: 1\ndefaultAgents: []\n")
    let model = await loadedModel(fixture)
    model.beginDraft(.defaults)
    model.manifestDraft?.defaultAgents = [.codex]
    try await reviewed(model) { model.previewDraft() }
    #expect(model.updateSession?.report != nil)
    try fixture.writeManifest("# External change\nversion: 1\ndefaultAgents: []\n")
    let before = try fixture.entries()
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .unchanged)
    #expect(model.updateRecords.last?.terminal.succeeded == false)
    let after = try fixture.entries()
    #expect(after["/project/.agent/agents.yaml"] == before["/project/.agent/agents.yaml"])
    #expect(after["/project/.agent/agents.resolved"] == before["/project/.agent/agents.resolved"])
    #expect(model.updateSession?.messages.isEmpty == false)
  }

  @Test func preciseSelectionRemovalUsesRealRecordedState() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let boundary = try FixtureEventBoundary(root: fixture.root)
    defer { boundary.stop() }
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: [codex]
      components:
        - kind: mcpServer
          name: first
          transport: {kind: stdio, executable: fixture-command}
        - kind: mcpServer
          name: second
          transport: {kind: stdio, executable: fixture-command}
      """)
    try await boundary.settle(
      creation: fixture.project.appendingPathComponent(".agent/agents.yaml"), root: fixture.root)
    let model = await loadedModel(fixture)
    defer { _ = model.requestTermination() }
    model.previewUpdate(title: "Initial update")
    try await idle(model)
    model.confirmUpdate()
    try await idle(model)
    let selected = try #require(model.availableComponentSelection.first { $0.name == "first" })
    let removal = UpdateRequest(operation: .remove, selections: [selected.selection])
    do {
      _ = try UpdateOperations.preview(
        removal, scope: .project,
        environment: .init(
          projectDirectory: fixture.project, homeDirectory: fixture.home,
          environment: fixture.environment))
    } catch {
      Issue.record("Direct public Core removal preview failed: \(error)")
    }
    model.previewUpdate(title: "Remove first", request: removal)
    try await idle(model)
    #expect(
      model.updateSession?.report != nil,
      "Removal preview: \(model.updateSession?.messages.map(\.message) ?? [])")
    model.confirmUpdate()
    try await idle(model)
    #expect(
      model.updateRecords.last?.terminal.succeeded == true,
      "Removal result: \(model.updateSession?.messages.map(\.message) ?? [])")
    #expect(model.availableComponentSelection.map(\.name) == ["second"])
  }

  @Test func fullRestoreReconstructsActualManagedOutput() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest(
      """
      version: 1
      components:
        - kind: mcpServer
          name: fixture
          transport: {kind: stdio, executable: fixture-command}
          agents: [codex]
      """)
    let model = await loadedModel(fixture)
    try await reviewed(model) { model.previewUpdate(title: "Initial update") }
    model.confirmUpdate()
    try await idle(model)
    let target = try #require(model.snapshot?.inspection.deployments.first?.location)
    let original = try Data(contentsOf: target)
    try FileManager.default.removeItem(at: target)
    try await reviewed(model) {
      model.previewUpdate(title: "Restore", request: .init(operation: .restore))
    }
    #expect(model.updateSession?.report?.hasChanges == true)
    model.confirmUpdate()
    try await idle(model)
    #expect(try Data(contentsOf: target) == original)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
  }

  @Test func userInstructionDraftPreviewsAppliesAndVerifiesAntigravityFiles() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let source = fixture.root.appendingPathComponent("source/instructions")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for name in ["shared", "antigravity-only"] {
      try Data("---\ndescription: Fixture instruction\n---\n# \(name)\nRule body.\n".utf8)
        .write(to: source.appendingPathComponent(name + ".md"))
    }
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: []
      sources: {fixture: {path: "\(source.deletingLastPathComponent().path)"}}
      """, user: true)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    defer { _ = model.requestTermination() }
    model.refresh()
    try await idle(model)
    model.beginDraft(.component)
    model.manifestDraft?.component.kind = .instructions
    model.manifestDraft?.component.agents = [.codex, .geminiCLI, .antigravity]
    model.manifestDraft?.component.instructions.sectionReferences = [
      .init(name: "shared", source: "fixture"),
      .init(name: "antigravity-only", source: "fixture", condition: .init(agents: [.antigravity])),
    ]
    let before = try fixture.entries()
    try await reviewed(model) { model.previewDraft() }
    let add = try #require(
      model.updateSession?.report, "\(model.updateSession?.messages.map(\.message) ?? [])")
    #expect(add.instructions.advisories.contains { $0.contains("20,000-token") })
    #expect(add.instructions.conflicts.isEmpty)
    let rules = add.instructions.targets.filter { $0.afterAgents == [.antigravity] }
    #expect(rules.count == 2)
    #expect(Set(rules.map(\.url)).count == 2)
    let rulesPath = fixture.home.resolvingSymlinksInPath().path + "/.gemini/config/rules"
    #expect(rules.allSatisfy { $0.url.deletingLastPathComponent().path == rulesPath })
    #expect(rules.allSatisfy { InstructionFileReviewRow(target: $0).action == "Add" })
    let codex = try #require(add.instructions.targets.first { $0.afterAgents == [.codex] })
    #expect(codex.url.lastPathComponent == "AGENTS.md")
    let gemini = try #require(add.instructions.targets.first { $0.afterAgents == [.geminiCLI] })
    #expect(gemini.url.lastPathComponent == "GEMINI.md")
    let geminiText = String(decoding: try #require(gemini.after), as: UTF8.self)
    #expect(geminiText.contains("# shared"))
    #expect(!geminiText.contains("# antigravity-only"))
    #expect(try fixture.entries() == before)
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    for rule in rules {
      #expect(try Data(contentsOf: rule.url) == rule.after)
      let deployment = model.snapshot?.inspection.deployments.first { $0.location == rule.url }
      #expect(deployment?.status == .current)
    }
    model.closeUpdateReview()
    try await reviewed(model) { model.previewUpdate(title: "Repeat update") }
    let repeatReport = try #require(model.updateSession?.report)
    #expect(!repeatReport.hasChanges)
    let verification = repeatReport.instructions.targets.filter { $0.afterAgents == [.antigravity] }
    #expect(verification.count == 2)
    #expect(
      verification.allSatisfy {
        InstructionFileReviewRow(target: $0).verification == "Matches lock"
      })

    model.closeUpdateReview()
    model.selectedItem = try #require(model.snapshot?.instructions.first?.id)
    model.editSelectedDeclaration()
    model.manifestDraft?.component.instructions.sectionReferences.removeLast()
    try await reviewed(model) { model.previewDraft() }
    let removal = try #require(model.updateSession?.report)
    let removed = try #require(
      removal.instructions.targets.first { $0.after == nil && $0.beforeAgents == [.antigravity] })
    #expect(InstructionFileReviewRow(target: removed).action == "Remove")
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    #expect(!FileManager.default.fileExists(atPath: removed.url.path))
    #expect(try Data(contentsOf: codex.url) == codex.after)
    #expect(try Data(contentsOf: gemini.url) == gemini.after)

    let remaining = try #require(rules.first { $0.url != removed.url })
    let unmanaged = Data("# Handwritten instructions\n".utf8)
    try unmanaged.write(to: remaining.url)
    model.closeUpdateReview()
    try await reviewed(model) { model.previewUpdate(title: "Review conflicting file") }
    let conflicted = try #require(model.updateSession)
    let conflict = try #require(conflicted.report)
    #expect(conflict.instructions.conflicts.contains { $0.contains(remaining.url.path) })
    let conflictedTarget = try #require(
      conflict.instructions.targets.first { $0.url == remaining.url })
    #expect(InstructionFileReviewRow(target: conflictedTarget).verification == "Conflict")
    #expect(!conflicted.canApplyReport)
    model.confirmUpdate()
    #expect(model.operations.isEmpty)
    #expect(try Data(contentsOf: remaining.url) == unmanaged)
  }

  @Test func rejectsOversizedAntigravityRuleInAppPreview() throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let source = fixture.root.appendingPathComponent("source/instructions")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let instruction =
      "---\ndescription: Large fixture\n---\n# Oversized\n"
      + String(repeating: "é", count: 12_001) + "\n"
    try Data(instruction.utf8).write(to: source.appendingPathComponent("oversized.md"))
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: []
      sources: {fixture: {path: "\(source.deletingLastPathComponent().path)"}}
      components:
        - kind: instructions
          agents: [antigravity]
          sections: [{name: oversized, source: fixture}]
      """, user: true)
    let scope = WorkspaceScope(kind: .user, root: fixture.home)
    let before = try fixture.entries()
    let completion = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
      .preview(.init(id: UUID(), scope: scope, title: "Review Instructions", request: .init()))
    #expect(completion.disposition == .failed)
    #expect(
      completion.diagnostics.contains {
        $0.message.contains("oversized") && $0.message.contains("UTF-8 bytes")
          && $0.message.contains("24000")
      })
    #expect(try fixture.entries() == before)
  }

  @Test func discoveryIsReadOnlyAndRejectsChangedSourceBeforePreview() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let boundary = try FixtureEventBoundary(root: fixture.root)
    defer { boundary.stop() }
    let source = fixture.project.appendingPathComponent("content/skills/demo")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let file = source.appendingPathComponent("SKILL.md")
    try Data("---\nname: demo\ndescription: Fixture skill.\n---\n# Demo\nBefore\n".utf8).write(
      to: file)
    try fixture.writeManifest(
      """
      version: 1
      defaultAgents: []
      sources: {local: {path: ./content}}
      components: [{kind: skills, source: local, select: all}]
      """)
    try await boundary.settle(
      creation: fixture.project.appendingPathComponent(".agent/agents.yaml"), root: fixture.root)
    let model = await loadedModel(fixture)
    defer { _ = model.requestTermination() }
    let before = try fixture.entries()
    let declaration = try #require(model.snapshot?.inspection.declaration)
    do {
      _ = try UpdateOperations.discover(
        declaration, scope: .project,
        environment: .init(
          projectDirectory: fixture.project, homeDirectory: fixture.home,
          environment: fixture.environment))
    } catch { Issue.record("Direct public discovery failed: \(error)") }
    model.discoverComponents()
    try await idle(model)
    #expect(
      model.discoverySession?.discovery?.components.map(\.name) == ["demo"],
      "Discovery: \(model.discoverySession?.messages.map(\.message) ?? [])")
    #expect(try fixture.entries() == before)
    try Data("---\nname: demo\ndescription: Fixture skill.\n---\n# Demo\nAfter\n".utf8).write(
      to: file)
    model.previewDiscovery()
    try await idle(model)
    #expect(model.updateSession?.report == nil)
    #expect(model.updateSession?.messages.isEmpty == false)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent(".agent/agents.resolved").path))
  }

  @Test func runtimeInputIsExplicitEphemeralAndSymbolicInspectionRemainsPrivate() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let model = await loadedModel(fixture)
    model.beginDraft(.component)
    model.manifestDraft?.component.name = "private-fixture"
    model.manifestDraft?.component.agents = [.codex]
    model.manifestDraft?.component.transport = .stdio(
      .init(executable: "fixture-command", environment: ["TOKEN": .secret("FixtureSecret")]))
    try await reviewed(model) { model.previewDraft() }
    #expect(model.updateSession?.requiredBindings == ["FixtureSecret"])
    let before = try fixture.entries()
    model.confirmUpdate()
    #expect(model.operations.isEmpty)
    #expect(try fixture.entries() == before)
    let secret = "task-only-fixture-secret"
    model.updateSession?.bindingInputs["FixtureSecret"] = secret
    model.confirmUpdate()
    #expect(model.updateSession?.bindingInputs.isEmpty == true)
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    #expect(model.snapshot?.inspection.deployments.first?.privateMaterialization == true)
    let symbolic = String(describing: model.snapshot?.inspection.components.first?.configuration)
    #expect(!symbolic.contains(secret))
    #expect(!model.diagnostics.map(\.message).joined().contains(secret))
  }

  @Test func cancelledRunningPreparationStillDeliversActualCoreTerminalBeforeQuit() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: 1\ndefaultAgents: []\n")
    let model = await loadedModel(fixture)
    let request = UpdateRequest(expectedDeclarationDigest: model.snapshot?.document?.digest)
    let proposal = UpdateProposal(id: UUID(), scope: model.scope, title: "Update", request: request)
    let actions = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
    let report = try UpdateOperations.preview(
      request, scope: .project,
      environment: .init(
        projectDirectory: fixture.project, homeDirectory: fixture.home,
        environment: fixture.environment))
    let admission = OperationAdmission()
    let gate = UpdatePreparationGate()
    defer { gate.release() }
    var events = gate.events.makeAsyncIterator()
    let (stream, replies) = AsyncStream.makeStream(of: Bool.self)
    model.terminationReply = { replies.yield($0) }
    model.startOperation(
      title: "Apply", scope: model.scope, purpose: .apply(proposal.id), admission: admission
    ) {
      gate.wait()
      return actions.apply(proposal, fingerprint: report.displayedFingerprint, admission: admission)
    }
    #expect(await events.next() == "waiting")
    #expect(model.requestTermination() == .later)
    #expect(!model.operations.isEmpty)
    gate.release()
    var results = stream.makeAsyncIterator()
    #expect(await results.next() == true)
    #expect(model.operations.isEmpty)
    #expect(model.updateRecords.last?.terminal.cancelledBeforeApply == true)
    #expect(model.updateRecords.last?.terminal.disposition == .unchanged)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent(".agent/agents.resolved").path))
  }

  @Test func earlierScopeFailureRetainsActualOuterTerminalWithoutReplacingSelection() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    try fixture.writeManifest("version: 1\ndefaultAgents: []\n", user: true)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.refresh()
    try await idle(model)
    let earlier = model.scope
    let proposal = UpdateProposal(
      id: UUID(), scope: earlier, title: "Earlier update", request: .init())
    let actions = CoreActions(home: fixture.home, processEnvironment: fixture.environment)
    let admission = OperationAdmission()
    let gate = UpdatePreparationGate()
    defer { gate.release() }
    var events = gate.events.makeAsyncIterator()
    model.startOperation(title: proposal.title, scope: earlier) {
      gate.wait()
      return actions.apply(
        proposal, fingerprint: "a superseded displayed fingerprint", admission: admission)
    }
    #expect(await events.next() == "waiting")
    let selected = WorkspaceScope(kind: .project, root: fixture.project)
    model.select(selected)
    gate.release()
    try await idle(model)
    #expect(model.snapshot?.scope == selected)
    #expect(model.updateRecords.last?.scope == earlier)
    #expect(model.updateRecords.last?.terminal.disposition == .unchanged)
    #expect(model.updateRecords.last?.terminal.succeeded == false)
    #expect(model.diagnostics.contains { $0.scope == earlier && $0.severity == .error })
  }

  @Test func draftFromAnotherScopeCannotBeAppliedToAnIdenticalDocument() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let bytes = "version: 1\ndefaultAgents: []\n"
    try fixture.writeManifest(bytes, user: true)
    try fixture.writeManifest(bytes)
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.refresh()
    try await idle(model)
    model.beginDraft(.defaults)
    model.manifestDraft?.defaultAgents = [.codex]
    model.select(.init(kind: .project, root: fixture.project))
    try await idle(model)
    let before = try fixture.entries()
    try await reviewed(model) { model.previewDraft() }
    #expect(model.updateSession == nil)
    #expect(try fixture.entries() == before)
    #expect(model.manifestDraft?.scope.kind == .user)
  }

  @Test func marketplaceBundlePublishesThroughTheDisplayedReview() async throws {
    let author = try TestFixture()
    let consumer = try TestFixture()
    defer {
      try? author.remove()
      try? consumer.remove()
    }
    try author.writeManifest(
      """
      version: 1
      components:
        - kind: mcpServer
          name: handbook
          transport: {kind: stdio, executable: fixture-command}
          agents: [codex]
      """)
    let producer = RuntimeEnvironment(
      projectDirectory: author.project, homeDirectory: author.home, environment: author.environment)
    _ = try UpdateOperations.withPreparedUpdate(environment: producer) { try $0.apply() }
    let selections = try UpdateOperations.inspect(environment: producer).components.map(\.selection)
    let archive = try BundleOperations.export(
      BundlePackage(name: "team-kit", version: "1.0.0"), selections: selections,
      scope: .project, environment: producer)
    let catalog = author.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
    let release = try MarketplaceOperations.publishBundle(archive, to: catalog)
    let model = await loadedModel(consumer)
    let environment = model.actions.environment(for: model.scope)
    let package = try MarketplaceOperations.acquire(release, environment: environment)
    let bundle = try package.inspectBundle()
    let preview = try package.previewImport(
      as: "team-kit",
      selections: bundle.components.map {
        BundleImportSelection(componentID: $0.id, targets: [.codex])
      }, scope: .project, environment: environment)
    let before = try consumer.entries()
    try await reviewed(model) {
      model.previewUpdate(UpdateProposal(scope: model.scope, bundle: preview))
    }
    #expect(model.updateSession?.stage == .review)
    #expect(try consumer.entries() == before)
    model.confirmUpdate()
    try await idle(model)
    #expect(model.updateRecords.last?.terminal.disposition == .committed)
    #expect(
      try MarketplaceOperations.installed(scope: .project, environment: environment).first?
        .archiveDigest == release.archiveDigest)
    #expect(model.snapshot?.inspection.components.contains { $0.name == "handbook" } == true)
  }

  @Test func bundleDependencyDraftUsesCoreVersionAndPortableCatalogValidation() throws {
    var draft = BundleDependencyDraft()
    draft.package = "shared-workflows"
    draft.requirement = .range(from: "1.2.3", to: "2.5.0")
    #expect(try draft.dependency().catalog == nil)
    draft.source = .hosted
    draft.indexURL = "https://team.example.invalid/main/marketplace.json"
    #expect(try draft.dependency().catalog?.hostedIndex?.absoluteString == draft.indexURL)
    draft.source = .git
    draft.gitURL = "https://example.invalid/team/catalog.git"
    draft.gitRef = "stable"
    draft.gitSubpath = "packages"
    let dependency = try draft.dependency()
    #expect(dependency.requirement == .range(from: "1.2.3", to: "2.5.0"))
    #expect(dependency.catalog?.ref == "stable")
    #expect(dependency.catalog?.subpath == "packages")
    draft.requirement = .range(from: "2.5.0", to: "1.2.3")
    #expect(throws: CoreError.self) { try draft.dependency() }
    draft.requirement = .exact("1.2.3")
    draft.gitURL = "./catalog"
    #expect(throws: MarketplaceError.self) { try draft.dependency() }
  }

  @Test nonisolated func marketplaceGraphRetainsEachRootsClientsThroughReviewUpgradeAndRemoval()
    throws
  {
    let author = try TestFixture()
    let consumer = try TestFixture()
    defer {
      try? author.remove()
      try? consumer.remove()
    }
    let authorEnvironment = RuntimeEnvironment(
      projectDirectory: author.project, homeDirectory: author.home, environment: author.environment)
    let content = author.project.appendingPathComponent("content")
    let skill = content.appendingPathComponent("skills/shared-skill")
    let instructions = content.appendingPathComponent("instructions")
    for directory in [skill, instructions] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("---\nname: shared-skill\ndescription: A fixture.\n---\n# Shared\n".utf8)
      .write(to: skill.appendingPathComponent("SKILL.md"))
    try Data("---\ndescription: A fixture.\n---\n# Shared instructions\n".utf8)
      .write(to: instructions.appendingPathComponent("shared.md"))
    try author.writeManifest(
      """
      version: 1
      sources: {content: {path: ./content}}
      components:
        - {kind: skills, source: content, select: all, agents: [codex]}
        - kind: instructions
          agents: [codex]
          sections: [{name: shared, source: content}]
        - kind: mcpServer
          name: handbook
          transport: {kind: sse, url: "https://example.invalid/sse"}
          agents: [claude-code]
      """)
    _ = try UpdateOperations.withPreparedUpdate(environment: authorEnvironment) { try $0.apply() }
    let components = try UpdateOperations.inspect(environment: authorEnvironment).components
    let catalog = author.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)

    func publish(
      _ package: String, _ version: String, dependencies: [MarketplacePackageRequirement] = []
    ) throws -> MarketplaceRelease {
      let selections = components.filter { ($0.kind == .mcpServer) == (package == "starter") }
      let archive = try BundleOperations.export(
        BundlePackage(name: package, version: version, dependencies: dependencies),
        selections: selections.map(\.selection), scope: .project, environment: authorEnvironment)
      return try MarketplaceOperations.publishBundle(archive, to: catalog)
    }

    let first = try publish("shared", "1.0.0")
    var dependency = BundleDependencyDraft()
    dependency.package = "shared"
    dependency.requirement = .upToNextMajor(from: "1.0.0")
    let starter = try publish("starter", "1.0.0", dependencies: [dependency.dependency()])
    let scope = WorkspaceScope(kind: .project, root: consumer.project)
    let actions = CoreActions(home: consumer.home, processEnvironment: consumer.environment)
    let environment = actions.environment(for: scope)
    let registration = try MarketplaceRegistration(name: "team", origin: first.origin)
    try MarketplaceDirectory.register(registration, scope: .project, environment: environment)
    let registered = try MarketplaceDirectory.lookup(
      "team", scope: .project, environment: environment)
    let releases = try MarketplaceOperations.browse(registered, environment: environment)

    func resolve(_ draft: inout MarketplacePackageDraft) throws {
      draft.capture(try MarketplaceOperations.resolve(draft.request(), environment: environment))
    }

    func apply(_ checked: MarketplaceResolutionPreview, title: String) throws {
      let before = try consumer.entries()
      let proposal = UpdateProposal(scope: scope, title: title, marketplace: checked)
      let review = actions.preview(proposal)
      guard case .updatePreview(let id, let report) = review.output else {
        throw CoreError.invalidState(review.diagnostics.map(\.message).joined(separator: "\n"))
      }
      #expect(id == proposal.id)
      #expect(report == checked.report)
      #expect(try consumer.entries() == before)
      let applied = actions.apply(
        proposal, fingerprint: report.displayedFingerprint, admission: OperationAdmission())
      #expect(applied.updateTerminal?.disposition == .committed, "\(applied.diagnostics)")
    }

    var sharedDraft = MarketplacePackageDraft(release: try releases.select(package: "shared"))
    sharedDraft.requirement = .upToNextMajor(from: "1.0.0")
    try resolve(&sharedDraft)
    let shared = try #require(sharedDraft.reachableNodes.first)
    let members = try #require(shared.availableMembers)
    let sharedSkill = try #require(members.first { $0.kind == .skills }?.marketplaceKey)
    #expect(Set(members.map(\.kind)) == [.skills, .instructions])
    for member in members {
      try sharedDraft.setTargets([.codex], for: member.marketplaceKey, in: shared)
    }
    let lock = try sharedDraft.previewLock(scope: .project, environment: environment)
    _ = try MarketplaceOperations.writeLockOnly(lock)
    let instructionFile = consumer.project.appendingPathComponent("AGENTS.md")
    #expect(!FileManager.default.fileExists(atPath: instructionFile.path))
    let pending = try UpdateOperations.inspect(environment: environment).pendingMarketplaceDeployment
    #expect(pending?.digest == lock.report.pendingDeployment.digest)
    let deployment = UpdateProposal(id: UUID(), scope: scope, title: "Deploy Locked Packages",
                                    request: MarketplaceOperations.frozenDeploymentRequest())
    let prepared = actions.preview(deployment)
    guard case .updatePreview(_, let report) = prepared.output else {
      throw CoreError.invalidState(prepared.diagnostics.map(\.message).joined(separator: "\n"))
    }
    let deployed = actions.apply(deployment, fingerprint: report.displayedFingerprint,
                                 admission: OperationAdmission())
    #expect(deployed.updateTerminal?.disposition == .committed)
    #expect(FileManager.default.fileExists(atPath: instructionFile.path))
    #expect(try UpdateOperations.inspect(environment: environment).pendingMarketplaceDeployment == nil)

    var starterDraft = MarketplacePackageDraft(release: starter)
    try resolve(&starterDraft)
    let starterNode = try #require(starterDraft.reachableNodes.first)
    let dependencyNode = try #require(
      starterDraft.reachableNodes.first {
        $0.versions.node == shared.versions.node
      })
    let server = try #require(starterNode.availableMembers?.first)
    #expect(server.kind == .mcpServer)
    try starterDraft.setTargets(
      [.claudeCode, .antigravity], for: server.marketplaceKey, in: starterNode)
    let unavailable = try #require(starterDraft.unavailableSelections(in: .project).first)
    #expect(!starterDraft.canReview(in: .project))
    try starterDraft.removeUnavailableTargets(from: unavailable, in: .project)
    #expect(
      starterDraft.targets(for: server.marketplaceKey, in: starterNode.versions.node)
        == [.claudeCode])
    try starterDraft.setTargets([.claudeCode], for: sharedSkill, in: dependencyNode)
    starterDraft.pinOnly = true
    let lockOnly = try starterDraft.preview(scope: .project, environment: environment)
    #expect(
      lockOnly.resolution.roots.first { $0.intent.name == "starter" }?.intent.selections == [])
    #expect(
      lockOnly.report.marketplaceGraphChange?.after?.recipientsByRoot(
        for: sharedSkill, in: dependencyNode.versions.node) == ["shared": [.codex]])

    starterDraft.pinOnly = false
    #expect(
      starterDraft.targets(for: sharedSkill, in: dependencyNode.versions.node) == [.claudeCode])
    try apply(
      starterDraft.preview(scope: .project, environment: environment), title: starterDraft.title)

    _ = try publish("shared", "1.1.0")
    _ = try publish("shared", "2.0.0")
    let installed = try #require(
      UpdateOperations.inspect(environment: environment).marketplaceGraph)
    let root = try #require(installed.roots.first { $0.intent.name == "starter" }?.intent)
    var upgrade = MarketplacePackageDraft(upgrading: root)
    try resolve(&upgrade)
    let versions = try #require(
      upgrade.reachableNodes.first {
        $0.versions.node == dependencyNode.versions.node
      }?.versions)
    #expect(versions.locked?.version == "1.0.0")
    #expect(versions.eligible.version == "1.1.0")
    #expect(versions.latest?.version == "2.0.0")
    #expect(upgrade.selections == root.selections)
    let checked = try upgrade.preview(scope: .project, environment: environment)
    #expect(checked.report.marketplaceGraphChange?.affectedRoots == ["shared", "starter"])
    let beforeCatalogChange = try consumer.entries()
    _ = try publish("shared", "2.1.0")
    let refused = actions.apply(
      .init(scope: scope, title: upgrade.title, marketplace: checked),
      fingerprint: checked.report.displayedFingerprint, admission: OperationAdmission())
    #expect(refused.disposition == .failed)
    #expect(refused.diagnostics.contains { $0.message.contains("marketplace catalog changed") })
    #expect(try consumer.entries() == beforeCatalogChange)
    try resolve(&upgrade)
    try apply(
      upgrade.preview(scope: .project, environment: environment), title: upgrade.title)

    let removal = try MarketplaceOperations.previewResolution(
      .remove("starter"), environment: environment)
    try apply(removal, title: "Remove starter")
    let afterRemoval = try UpdateOperations.inspect(environment: environment)
    let remaining = try #require(afterRemoval.marketplaceGraph)
    #expect(remaining.roots.map(\.intent.name) == ["shared"])
    #expect(remaining.nodes.map(\.coordinate.version) == ["1.1.0"])
    #expect(
      remaining.recipientsByRoot(for: sharedSkill, in: dependencyNode.versions.node)
        == ["shared": [.codex]])
    #expect(!afterRemoval.components.contains { $0.name == "handbook" })

    var pinDraft = MarketplacePackageDraft(release: starter)
    pinDraft.pinOnly = true
    try resolve(&pinDraft)
    let pinPreview = try pinDraft.preview(scope: .project, environment: environment)
    #expect(pinPreview.report.hasChanges)
    #expect(pinPreview.report.components.filter(\.changed).isEmpty)
    #expect(pinPreview.report.skills.filter(\.changed).isEmpty)
    try apply(pinPreview, title: pinDraft.title)
    let pinned = try #require(UpdateOperations.inspect(environment: environment).marketplaceGraph)
    #expect(pinned.roots.first { $0.intent.name == "starter" }?.intent.selections == [])
    #expect(
      pinned.recipientsByRoot(for: sharedSkill, in: dependencyNode.versions.node)
        == ["shared": [.codex]])
    let pinnedRoot = try #require(pinned.roots.first { $0.intent.name == "starter" }?.intent)
    _ = try publish("starter", "1.1.0", dependencies: [dependency.dependency()])
    var pinUpgrade = MarketplacePackageDraft(upgrading: pinnedRoot)
    #expect(pinUpgrade.pinOnly)
    pinUpgrade.requirement = .upToNextMajor(from: "1.0.0")
    try resolve(&pinUpgrade)
    let pinUpgradePreview = try pinUpgrade.preview(scope: .project, environment: environment)
    #expect(pinUpgradePreview.report.components.filter(\.changed).isEmpty)
    #expect(pinUpgradePreview.report.skills.filter(\.changed).isEmpty)
    try apply(pinUpgradePreview, title: pinUpgrade.title)
    let afterPinUpgrade = try UpdateOperations.inspect(environment: environment)
    #expect(
      afterPinUpgrade.marketplaceGraph?.nodes.first {
        $0.id == starterNode.versions.node
      }?.coordinate.version == "1.1.0")
  }

  private func loadedModel(_ fixture: TestFixture) async -> AppModel {
    let model = AppModel(
      home: fixture.home, preferences: AppPreferences(defaults: nil),
      processEnvironment: fixture.environment)
    model.select(.init(kind: .project, root: fixture.project))
    try? await idle(model)
    for _ in 0..<2000 {
      if model.canModify { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return model
  }

  private func reviewed(_ model: AppModel, prepare: () -> Void) async throws {
    // Native events can invalidate a preview between preparation and a user click. Exercise
    // explicit re-review against the unchanged document, never bypassing the App's stale gate.
    for _ in 0..<4 {
      for _ in 0..<2000 {
        if model.canModify { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      prepare()
      try await idle(model)
      if model.updateSession?.stage == .review { return }
      guard model.updateSession?.stage == .stale else { return }
      model.closeUpdateReview()
    }
    Issue.record("Native inputs did not settle enough to review the Core report")
  }

  private func idle(_ model: AppModel) async throws {
    for _ in 0..<2000 {
      if model.operations.isEmpty { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Core operation failed to reach an outer terminal")
  }
}

private final class UpdatePreparationGate: @unchecked Sendable {
  let events: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private let semaphore = DispatchSemaphore(value: 0)
  init() { (events, continuation) = AsyncStream.makeStream(of: String.self) }
  func wait() {
    continuation.yield("waiting")
    semaphore.wait()
  }
  func release() { semaphore.signal() }
}

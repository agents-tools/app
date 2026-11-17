import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsApp

struct NativeCoordinateTests {
  @Test func nativeLinkedSkillAndRelativeMCPImportUseCapturedCoordinatesWithoutExecution() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let input = f.root.appendingPathComponent("producer")
    let container = input.appendingPathComponent("bundle")
    let file = container.appendingPathComponent("gemini-extension.json")
    try write(
      #"{"name":"producer","version":"1.2.3","mcpServers":{"review":{"command":"${extensionPath}/bin/server","cwd":"./cwd"}}}"#,
      to: file)
    try write(
      "---\nname: helper\ndescription: Helper\n---\nFrozen helper\n",
      to: container.appendingPathComponent("skills/helper/SKILL.md"))
    let support = container.appendingPathComponent("shared/tool.txt")
    try write("Frozen support\n", to: support)
    try FileManager.default.createSymbolicLink(
      atPath: container.appendingPathComponent("skills/helper/reference.txt").path,
      withDestinationPath: "../../shared/tool.txt")
    let program = container.appendingPathComponent("bin/server")
    try write("Fixture bytes; never execute\n", to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    try write("Working directory support", to: container.appendingPathComponent("cwd/config.txt"))
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let scope = WorkspaceScope(kind: .project, root: f.project)
    func inspect() throws -> SourceImportInspection {
      let result = actions.inspectImport(
        id: UUID(), scope: scope, file: file, format: "geminiExtensionV1", inputRoot: input)
      guard case .sourceImport(_, let report) = result.output else {
        throw ProbeError.failed(String(describing: result.diagnostics))
      }
      return report
    }
    func proposal(_ report: SourceImportInspection) throws -> UpdateProposal {
      let read = try #require(
        CoreReader(home: f.home, processEnvironment: f.environment).read(scope: scope).snapshot)
      let result = actions.importRequest(
        id: UUID(), scope: scope, imported: report, inspection: read.inspection)
      guard case .importRequest(_, let request) = result.output else {
        throw ProbeError.failed(String(describing: result.diagnostics))
      }
      return .init(id: UUID(), scope: scope, title: "Native import", request: request)
    }
    let original = try inspect()
    #expect(original.diagnostics.isEmpty)
    #expect(original.sources.first?.declaration?.location == "bundle")
    let skill = try #require(original.components.first { $0.declaration.kind == .skills })
    #expect(ComponentDraft(skill.declaration).skills.path == "skills/helper")
    let server = try #require(original.components.first { $0.declaration.kind == .mcpServer })
    guard case .stdio(let run) = ComponentDraft(server.declaration).transport else {
      Issue.record("Expected imported stdio declaration")
      return
    }
    #expect(run.executableSource == "native-input")
    #expect(run.workingDirectory?.source == "native-input")
    let captured = try proposal(original)
    try write("Changed support\n", to: support)
    #expect(actions.preview(captured).disposition == .failed)
    let refreshed = try inspect()
    let proposed = try proposal(refreshed)
    guard case .updatePreview(_, let review) = actions.preview(proposed).output else {
      Issue.record("Native public import did not produce a review")
      return
    }
    #expect(
      actions.apply(
        proposed, fingerprint: review.displayedFingerprint,
        admission: OperationAdmission()
      ).updateTerminal?.disposition == .committed)
    let readback = try #require(
      CoreReader(home: f.home, processEnvironment: f.environment).read(scope: scope).snapshot)
    #expect(readback.inspection.deployments.allSatisfy { $0.status == .current })
    let installed = try #require(
      readback.inspection.deployments.first { $0.location.lastPathComponent == "helper" })
    #expect(
      try String(
        contentsOf: installed.location.appendingPathComponent("reference.txt"), encoding: .utf8)
        == "Changed support\n")
    let selected = try #require(readback.inspection.components.first { $0.kind == .mcpServer })
    let connection = actions.connectionSnapshot(
      id: UUID(), scope: scope, selection: selected.selection)
    guard case .connectionSnapshot(_, _, let description) = connection.output else {
      Issue.record("Native executable snapshot missing")
      return
    }
    #expect(description.executableIsCaptured && description.workingDirectoryIsCaptured)
    #expect(description.executable == "bin/server" && description.workingDirectory == "cwd")
  }

  private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }
  private enum ProbeError: Error { case failed(String) }
}

import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation

enum WebInstructionPreview {
  static func render(
    _ references: [String], scope: WorkspaceScope, environment: RuntimeEnvironment
  ) throws -> (Data, [ReadDependency]) {
    let store = StateStore(scope: scope.installScope, environment: environment)
    let digest = try store.loadManifest()?.digest
    let declaration = try store.loadDeclaration()
    var dependencies: [ReadDependency] = [.entry(store.declarationURL)]
    var unitsBySource: [String: [InstructionUnit]] = [:]

    let sections = try references.map { reference in
      let selection = SectionDeclaration(reference: reference)
      let source = selection.source ?? "."
      if unitsBySource[source] == nil {
        if source == "." {
          guard scope.kind == .project else {
            throw CoreError.invalidState("Project instruction files are unavailable in user scope.")
          }
          let own = try InstructionOperations.inspectOwnInstructions(environment: environment)
          unitsBySource[source] = own.units
          dependencies += own.readLocations.map(ReadDependency.subtree)
        } else {
          // If the alias disappears during the read, the Core command must fail rather than
          // interpreting it as a direct source coordinate or a selector.
          guard source == source.trimmingCharacters(in: .whitespacesAndNewlines),
            let declared = declaration.sources[source]
          else {
            throw CoreError.invalidSource("Expected a declared instruction source: " + source)
          }
          let coordinate = try? SourceParser.parse(
            source, currentDirectory: environment.projectDirectory,
            homeDirectory: environment.homeDirectory, sourceAccess: .init())
          guard coordinate == nil else {
            throw CoreError.invalidSource(
              "This instruction source alias also names a location: " + source)
          }
          let sourceID = try declared.identity(environment: environment)
          let result = try InstructionOperations.add(
            .init(
              source: source, listOnly: true, scope: scope.installScope, environment: environment))
          guard result.sourceID == sourceID else { throw changed }
          unitsBySource[source] = result.available
          if declared.kind == .local {
            dependencies.append(
              .subtree(URL(fileURLWithPath: String(sourceID.dropFirst("local:".count)))))
          }
        }
      }
      guard let unit = unitsBySource[source]?.first(where: { $0.record.name == selection.name })
      else { throw CoreError.notFound("instruction unit “\(reference)”") }
      return unit.section
    }

    guard try store.loadManifest()?.digest == digest else { throw changed }
    return (try Instructions.renderChatGPT(sections: sections), dependencies)
  }

  private static var changed: CoreError {
    .invalidState("Instruction sources changed. Refresh and generate a new preview.")
  }
}

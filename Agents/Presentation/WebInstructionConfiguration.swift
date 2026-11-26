import AgentsCore
import AgentsManifest
import AgentsUpdates

enum WebInstructionDestination: String, CaseIterable, Identifiable {
  case chatGPT = "chatgpt-web"
  case gemini = "gemini-web"

  var id: String { rawValue }
  var title: String { self == .chatGPT ? "ChatGPT Web" : "Gemini Web" }
}

struct WebInstructionConfiguration {
  let destination: WebInstructionDestination
  let scope: WorkspaceScope
  let documentDigest: String
  let choices: [String]
  let selected: [String]
  let hasPreview: Bool
  let canConfigure: Bool

  private let owner: NodeID?
  private let prompt: PromptDeclaration

  init(
    _ destination: WebInstructionDestination, snapshot: WorkspaceSnapshot,
    environment: RuntimeEnvironment
  ) {
    self.destination = destination
    scope = snapshot.scope
    documentDigest = snapshot.document?.digest ?? "absent"
    let declaration = snapshot.inspection.declaration ?? Declaration()
    let containers =
      [("/components", declaration.components)]
      + declaration.groups.enumerated().map {
        ("/groups/\($0.offset)/components", $0.element.components)
      }
    var authored: [SectionDeclaration] = []
    var matches: [(NodeID, PromptDeclaration)] = []
    for (path, components) in containers {
      for (index, component) in components.enumerated() {
        guard case .instructions(let instructions) = component else { continue }
        authored +=
          instructions.sectionReferences + instructions.prompts.flatMap(\.prompt.sectionReferences)
        if let node = snapshot.document?.node(at: path + "/\(index)") {
          matches += instructions.prompts.filter { $0.name == destination.rawValue }.map {
            (node, $0.prompt)
          }
        }
      }
    }
    let resolved = snapshot.inspection.components.filter { $0.kind == .instructions }
    for entry in declaration.sourceDeclarations {
      guard let identity = try? entry.source.identity(environment: environment) else { continue }
      authored += resolved.filter { $0.source == identity }.map {
        SectionDeclaration(name: $0.name, source: entry.name)
      }
    }
    authored += (snapshot.ownInstructions ?? []).map { SectionDeclaration(name: $0.id.name) }
    choices = Set(authored.map(\.reference)).sorted()

    hasPreview =
      snapshot.mappings.first { $0.scope == snapshot.scope }?
      .prompts[destination.rawValue] != nil
    canConfigure = matches.count == 1 || (matches.isEmpty && !hasPreview)
    owner = matches.first?.0
    prompt = matches.first?.1 ?? .init(sections: [])
    var seen = Set<String>()
    selected = prompt.sections.filter { seen.insert($0).inserted }
  }

  func updateRequest(selecting references: [String]) -> UpdateRequest? {
    guard canConfigure, references != selected, Set(references).count == references.count,
      Set(references).isSubset(of: Set(choices))
    else { return nil }

    var updated = prompt
    updated.sectionReferences = references.flatMap { reference -> [SectionDeclaration] in
      let existing = prompt.sectionReferences.filter { $0.reference == reference }
      return existing.isEmpty ? [.init(reference: reference)] : existing
    }
    let named = NamedPromptDeclaration(name: destination.rawValue, prompt: updated)
    let component = ComponentDeclaration.instructions(
      .init(agents: [], chatgpt: [named.name: named.prompt]))
    let operation: UpdateOperation
    if let owner {
      operation = .edit([.upsertPrompt(owner, named)])
    } else if documentDigest == "absent" {
      var declaration = Declaration()
      declaration.components = [component]
      operation = .declaration(declaration)
    } else {
      operation = .edit([.insertComponent(component, into: .root, at: .last)])
    }
    return .init(
      operation: operation, kinds: [.instructions], expectedDeclarationDigest: documentDigest)
  }
}

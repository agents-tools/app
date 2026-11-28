import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation

struct WorkspaceScope: Hashable, Codable, Sendable, Identifiable {
  enum Kind: String, Codable, Sendable { case user, project }
  let kind: Kind
  let root: URL
  var id: String { kind.rawValue + ":" + root.standardizedFileURL.path }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
  var title: String { kind == .user ? "User Configuration" : root.lastPathComponent }
  var installScope: InstallScope { kind == .user ? .user : .project }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
  case overview, skills, instructions, mcp, other, packages, sources, installedComponents, backups, diagnostics
  case components

  var id: Self { self }
  var title: String {
    switch self {
    case .overview: "Overview"
    case .skills: "Skills"
    case .instructions: "Instructions & Rules"
    case .mcp: "MCP Servers"
    case .other: "Other Configuration"
    case .packages: "Packages"
    case .sources: "Sources"
    case .installedComponents: "Components"
    case .diagnostics: "Diagnostics"
    case .backups: "Backups"
    case .components: "Declaration"
    }
  }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .skills: "sparkles"
    case .instructions: "doc.text"
    case .mcp: "point.3.connected.trianglepath.dotted"
    case .other: "slider.horizontal.3"
    case .packages: "shippingbox"
    case .sources: "externaldrive"
    case .installedComponents: "square.stack.3d.up"
    case .diagnostics: "stethoscope"
    case .backups: "archivebox"
    case .components: "doc.text.magnifyingglass"
    }
  }

  var showsClientFilter: Bool {
    switch self {
    case .overview, .skills, .instructions, .mcp, .other: true
    default: false
    }
  }

  var hasInspector: Bool {
    switch self {
    case .skills, .components, .sources: true
    default: false
    }
  }
}

struct AppDiagnostic: Sendable, Identifiable, Equatable {
  enum Severity: String, Sendable { case information, warning, error }
  let id: UUID
  let scope: WorkspaceScope
  let operation: String
  let severity: Severity
  let message: String
  let path: String?
  let blocksTermination: Bool
  let coreRecovery: Bool

  init(
    scope: WorkspaceScope, operation: String, severity: Severity = .error,
    message: String, path: String? = nil, blocksTermination: Bool = false,
    coreRecovery: Bool = false
  ) {
    id = UUID()
    self.scope = scope
    self.operation = operation
    self.severity = severity
    self.message = message
    self.path = path
    self.blocksTermination = blocksTermination
    self.coreRecovery = coreRecovery
  }
}

struct DeclarationItem: Identifiable, Sendable {
  // Node identity is meaningful only within this exact declaration generation.
  let id: NodeID
  let pointer: String
  let title: String
  let category: String
  let record: DeclarationRecord
  let container: String
}

struct InventoryItem: Identifiable, Sendable {
  struct ID: Hashable, Sendable {
    let name: String
    let agent: AgentID
    let scope: InstallScope
    let path: String
  }
  let id: ID
  let status: String
  let mode: InstallMode?
  let source: String?
  var revision: String? = nil
  var version: String? = nil
}

struct MappingItem: Identifiable, Sendable {
  let id: String
  let title: String
  let scope: WorkspaceScope
  let status: String
  let targets: [MappingTarget]
  let unplaced: [LockedSection]
  let prompts: [String: [LockedSection]]
}

struct MappingTarget: Identifiable, Equatable, Sendable {
  let id: String
  let recipients: [AgentID]
  let sections: [LockedSection]
  let importedFile: String?

  var agents: String { recipients.map(\.displayName).joined(separator: ", ") }
}

struct OwnInstructionItem: Identifiable, Sendable {
  struct ID: Hashable, Sendable {
    let source: String
    let name: String
    let path: String
  }
  let id: ID
  let heading: String
  let description: String
  let paths: [String]
  let hash: String
  let authorFile: URL
}

struct SourceListRow: Identifiable, Sendable {
  enum ID: Hashable, Sendable {
    case declaration(NodeID)
    case resolved(String)
  }

  let id: ID
  let name: String
  let kind: String
  let versions: [SourceInspection]

  var versionLabel: String {
    guard let first = versions.first else { return "Not resolved" }
    if versions.count > 1 { return "\(versions.count) revisions" }
    if let version = first.version { return version }
    let revision = first.revision
    return [40, 64].contains(revision.count) && revision.allSatisfy(\.isHexDigit)
      ? String(revision.prefix(12)) : revision
  }

  static func rows(
    items: [DeclarationItem], inspection: ScopeInspection, environment: RuntimeEnvironment
  ) -> [Self] {
    let byIdentity = Dictionary(grouping: inspection.sources, by: \.identity)
    let declarations = inspection.declaration?.sources ?? [:]
    var matched = Set<String>()
    var rows = items.filter { $0.category == "Source" }.map { item in
      let source = declarations[item.record["name"]?.string ?? item.title]
      let identity = try? source?.identity(environment: environment)
      let versions = identity.flatMap { byIdentity[$0] }?.filter { record in
        record.container == nil && (record.uses.isEmpty || record.uses.contains {
          $0.root == (source?.path ?? ".") && $0.requirement == source?.requirement
        })
      } ?? []
      matched.formUnion(versions.map(\.record))
      return Self(id: .declaration(item.id), name: item.title,
                  kind: DeclarationLabels.kind(item.record.kind), versions: versions)
    }
    for source in inspection.sources where !matched.contains(source.record) {
      rows.append(Self(id: .resolved(source.record), name: source.identity,
                       kind: DeclarationLabels.kind(source.kind.rawValue), versions: [source]))
    }
    return rows
  }
}

struct WorkspaceSnapshot: Sendable {
  let scope: WorkspaceScope
  let manifestURL: URL
  let resolvedURL: URL
  let watchURL: URL
  let document: DeclarationDocument?
  let effectiveDefaultAgents: [AgentID]
  let items: [DeclarationItem]
  let inventory: [InventoryItem]?
  let inspection: ScopeInspection
  let watch: WatchState?
  let mappings: [MappingItem]
  let ownInstructions: [OwnInstructionItem]?
  let diagnostics: [AppDiagnostic]
  let readAt: Date
  var skillWorkspaceItems: [SkillWorkspaceItem] = []
  var sourceRows: [SourceListRow] = []

  func hasNoDeclaredAppInstructions(for recipient: InstructionRecipient) -> Bool {
    // Indirect selections are resolved by the instruction builder.
    guard scope.kind == .user, let declaration = inspection.declaration,
      declaration.uses.isEmpty, declaration.packages.isEmpty, declaration.marketplaceRoots.isEmpty
    else { return false }
    return !declaration.components.contains { component in
      guard case .instructions(let instructions) = component else { return false }
      return instructions.sectionReferences.contains { $0.recipients?.contains(recipient) == true }
    }
  }

  var isEmpty: Bool { document == nil && !inspection.recovery.pending }
  var components: [DeclarationItem] { items.filter { $0.category == "Component" } }
  var sources: [DeclarationItem] { items.filter { $0.category == "Source" } }
  var instructions: [DeclarationItem] { components.filter { $0.record.kind == "instructions" } }
}

enum WorkspaceLoadState {
  case idle
  case loading
  case loaded(WorkspaceSnapshot)
  case existingConfigurationAvailable
  case failed([AppDiagnostic])
}

import AgentsCore
import AgentsManifest
import Foundation

struct WorkspaceScope: Hashable, Codable, Sendable, Identifiable {
  enum Kind: String, Codable, Sendable { case user, project }
  let kind: Kind
  let root: URL
  var id: String { kind.rawValue + ":" + root.standardizedFileURL.path }
  var title: String { kind == .user ? "User Configuration" : root.lastPathComponent }
  var installScope: InstallScope { kind == .user ? .user : .project }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
  case overview, components, instructions, sources, changes, diagnostics
  var id: Self { self }
  var title: String {
    switch self {
    case .overview: "Overview"
    case .components: "Components"
    case .instructions: "Instructions / Rules"
    case .sources: "Sources"
    case .changes: "Changes"
    case .diagnostics: "Diagnostics"
    }
  }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .components: "puzzlepiece.extension"
    case .instructions: "doc.text"
    case .sources: "externaldrive"
    case .changes: "arrow.triangle.2.circlepath"
    case .diagnostics: "stethoscope"
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

  init(
    scope: WorkspaceScope, operation: String, severity: Severity = .error,
    message: String, path: String? = nil, blocksTermination: Bool = false
  ) {
    id = UUID()
    self.scope = scope
    self.operation = operation
    self.severity = severity
    self.message = message
    self.path = path
    self.blocksTermination = blocksTermination
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
  let mode: String?
  let source: String?
}

struct MappingItem: Identifiable, Sendable {
  let id: String
  let title: String
  let scope: WorkspaceScope
  let status: String
  let targets: [MappingTarget]
  let unplaced: [String]
  let prompts: [String: [String]]
}

struct MappingTarget: Identifiable, Sendable {
  let id: String
  let agents: String
  let sections: [String]
  let importedFile: String?
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

struct WorkspaceSnapshot: Sendable {
  let scope: WorkspaceScope
  let manifestURL: URL
  let resolvedURL: URL
  let watchURL: URL
  let document: DeclarationDocument?
  let effectiveDefaultAgents: [AgentID]
  let items: [DeclarationItem]
  let inventory: [InventoryItem]?
  let resolved: ResolvedState?
  let watch: WatchState?
  let mappings: [MappingItem]
  let ownInstructions: [OwnInstructionItem]?
  let diagnostics: [AppDiagnostic]
  let readAt: Date

  var isEmpty: Bool { document == nil }
  var components: [DeclarationItem] { items.filter { $0.category == "Component" } }
  var sources: [DeclarationItem] { items.filter { $0.category == "Source" } }
  var instructions: [DeclarationItem] { components.filter { $0.record.kind == "instructions" } }
}

enum WorkspaceLoadState {
  case idle
  case loading
  case loaded(WorkspaceSnapshot)
  case failed([AppDiagnostic])
}

enum WorkspaceIntent: String, Identifiable {
  case importConfiguration, reviewChanges, testConnection
  var id: Self { self }
  var title: String {
    switch self {
    case .reviewChanges: "Review Changes"
    case .importConfiguration: "Import Configuration"
    case .testConnection: "Test Connection"
    }
  }
  var unavailableReason: String {
    switch self {
    case .reviewChanges:
      "Previewing and applying configuration changes is not available in this build. Local declaration drafts can be validated separately."
    case .importConfiguration:
      "Configuration import is not available in this build."
    case .testConnection:
      "Connection testing is not available in this build. Viewing this component does not start a server or connect to an endpoint."
    }
  }
}

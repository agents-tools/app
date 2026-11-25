import AgentsCore
import AgentsUpdates
import Foundation

struct CreationRequest: Sendable {
  enum Kind: String, CaseIterable, Identifiable, Sendable {
    case skill, instructions
    var id: Self { self }
    var title: String { self == .skill ? "Local Skill" : "Local Instructions" }
  }
  let id: UUID
  let scope: WorkspaceScope
  let kind: Kind
  let directory: URL
  let name: String
}

struct CreationSession: Identifiable {
  enum Stage {
    case input, describing, confirmation, running
    case created(URL)
    case failed, cancelled
  }
  let id = UUID()
  let scope: WorkspaceScope
  let kind: CreationRequest.Kind
  var directory: URL
  var name = ""
  var directorySelected = false
  var stage: Stage = .input
  var description: InitializationDescription?
  var terminal: UpdateTerminal?
  var stale = false
  var messages: [AppDiagnostic] = []

  var request: CreationRequest {
    CreationRequest(id: id, scope: scope, kind: kind, directory: directory, name: name)
  }
}

struct PromptRequest: Sendable {
  let id: UUID
  let scope: WorkspaceScope
  let name: String
}

struct PromptSession: Identifiable {
  enum Stage {
    case loading
    case ready(String)
    case failed, outdated, cancelled
  }
  let id: UUID
  let scope: WorkspaceScope
  let name: String
  var stage: Stage = .loading
  var messages: [AppDiagnostic] = []
}

enum ContentOutput: Sendable {
  case clientInspection(UUID, AgentClientInspection)
  case clientInspectionFailed(UUID, String)
  case clientBackup([ClientBackupOutcome])
  case clientRestoreInspection(BackupClient, projects: [String], destinations: [String: URL])
  case clientRestoreReview(ClientRestoreReview)
  case creationDescription(UUID, InitializationDescription)
  case watchStatus(UUID, [WatchStatus])
  case watchPreview(UUID, WatchMutationPreview)
  case catalog(UUID, SourceCatalogInspection)
  case catalogRequest(UUID, UpdateRequest?)
  case sourceImport(UUID, SourceImportInspection)
  case importRequest(UUID, UpdateRequest)
  case connectionSnapshot(UUID, MCPConnectionSnapshot, MCPConnectionDescription)
  case connectionResult(UUID, MCPConnectionTestResult)
  case assistance(UUID, String)
  case created(CreationRequest, URL)
  case prompt(PromptRequest, String)
  case discovery(UUID, ComponentDiscovery)
  case updatePreview(UUID, CombinedUpdateReport)
  case existingConfigurationAvailable
  case existingConfigurationPreview(ExistingConfigurationReview)
  case mappings(UUID, [MappingItem])
}

struct MappingSession: Identifiable {
  enum Stage {
    case input, loading
    case loaded([MappingItem])
    case outdated, cancelled
  }
  let id = UUID()
  let scope: WorkspaceScope
  let availableProjects: [URL]
  var selectedProjects: [URL]
  var stage: Stage = .input
}

struct MappingRequest: Sendable {
  let id: UUID
  let context: WorkspaceScope
  let projects: [URL]
}

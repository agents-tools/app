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
    case input, confirmation, running
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
  case created(CreationRequest, URL)
  case prompt(PromptRequest, String)
  case validatedDraft(UUID, String)
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

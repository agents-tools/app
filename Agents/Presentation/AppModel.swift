import AgentsCore
import AgentsManifest
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
  enum TerminationDecision { case now, later, cancel }
  enum OperationPurpose {
    case workspace
    case creation(UUID)
    case prompt(UUID)
    case draft(UUID)
    case mappings(UUID)
    case other
  }
  struct ActiveOperation {
    let id: UUID
    let scope: WorkspaceScope
    let selectionScope: WorkspaceScope
    let purpose: OperationPurpose
    let generation: UUID
    let title: String
    let admission: OperationAdmission
  }

  let preferences: AppPreferences
  let home: URL
  private let executor: CoreExecutor
  private let reader: CoreReader
  private let actions: CoreActions
  private(set) var scope: WorkspaceScope
  private(set) var loadState: WorkspaceLoadState = .idle
  private(set) var operations: [UUID: ActiveOperation] = [:]
  private(set) var diagnostics: [AppDiagnostic] = []
  private(set) var isTerminating = false
  private(set) var terminationBlocked = false
  private var generation = UUID()
  var page: WorkspacePage = .overview
  var selectedItem: NodeID?
  var search = ""
  var presentedIntent: WorkspaceIntent?
  var creationSession: CreationSession?
  var promptSession: PromptSession?
  var manifestDraft: ManifestDraft?
  var mappingSession: MappingSession?
  @ObservationIgnored var terminationReply: (@MainActor (Bool) -> Void)?

  init(
    home: URL, preferences: AppPreferences, executor: CoreExecutor = CoreExecutor(),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.home = home
    self.preferences = preferences
    self.executor = executor
    reader = CoreReader(home: home, processEnvironment: processEnvironment)
    actions = CoreActions(home: home, processEnvironment: processEnvironment)
    let user = WorkspaceScope(kind: .user, root: home)
    scope =
      preferences.projects.map { WorkspaceScope(kind: .project, root: $0) }
      .first { $0.id == preferences.selectedScopeID } ?? user
  }

  var scopes: [WorkspaceScope] {
    [WorkspaceScope(kind: .user, root: home)]
      + preferences.projects.map { .init(kind: .project, root: $0) }
  }
  var snapshot: WorkspaceSnapshot? {
    if case .loaded(let value) = loadState { return value }
    return nil
  }
  var selectedDeclaration: DeclarationItem? { snapshot?.items.first { $0.id == selectedItem } }
  var currentDiagnostics: [AppDiagnostic] { diagnostics.filter { $0.scope == scope } }
  var filteredItems: [DeclarationItem] {
    guard let snapshot else { return [] }
    let items: [DeclarationItem]
    switch page {
    case .components: items = snapshot.items.filter { $0.category != "Source" }
    case .instructions: items = snapshot.instructions
    case .sources: items = snapshot.sources
    default: items = []
    }
    return items.filter { item in
      search.isEmpty
        || [item.title, item.record.kind, item.container].contains {
          $0.localizedStandardContains(search)
        }
    }
  }

  func select(_ scope: WorkspaceScope) {
    guard self.scope != scope, !isTerminating else { return }
    self.scope = scope
    preferences.selectedScopeID = scope.id
    selectedItem = nil
    search = ""
    refresh()
  }

  func addProject(_ url: URL) {
    guard !isTerminating else { return }
    preferences.addProject(url)
    select(WorkspaceScope(kind: .project, root: url.standardizedFileURL))
  }

  func removeProject(_ url: URL) {
    guard !isTerminating else { return }
    preferences.removeProject(url)
    if scope.root == url, scope.kind == .project {
      select(WorkspaceScope(kind: .user, root: home))
    }
  }

  func refresh() {
    guard !isTerminating else { return }
    // Superseded queued reads still report a terminal; running reads are allowed to finish.
    for operation in operations.values where operation.title == "Read configuration" {
      operation.admission.cancel()
    }
    generation = UUID()
    selectedItem = nil
    loadState = .loading
    let scope = scope
    let reader = reader
    startOperation(
      title: "Read configuration", scope: scope, generation: generation, purpose: .workspace
    ) {
      reader.read(scope: scope)
    }
  }

  @discardableResult
  func startOperation(
    title: String, scope: WorkspaceScope, generation: UUID? = nil,
    purpose: OperationPurpose = .other,
    work: @escaping @Sendable () -> CoreCompletion
  ) -> UUID? {
    guard !isTerminating else { return nil }
    let id = UUID()
    let operation = ActiveOperation(
      id: id, scope: scope, selectionScope: self.scope, purpose: purpose,
      generation: generation ?? self.generation,
      title: title, admission: OperationAdmission())
    operations[id] = operation
    executor.submit(admission: operation.admission, work: work) { result in
      Task { @MainActor [self] in finish(id, result: result) }
    }
    return id
  }

  func beginCreation(_ kind: CreationRequest.Kind) {
    guard !isTerminating, kind != .instructions || scope.kind == .project else { return }
    creationSession = CreationSession(scope: scope, kind: kind, directory: scope.root)
  }

  func selectCreationDirectory(_ url: URL) {
    guard creationSession?.kind == .skill else { return }
    creationSession?.directory = url
    creationSession?.directorySelected = true
  }

  func confirmCreation() {
    guard !isTerminating, let session = creationSession, case .confirmation = session.stage,
      session.kind == .instructions || session.directorySelected
    else {
      return
    }
    let request = session.request
    creationSession?.stage = .running
    let actions = actions
    startOperation(
      title: "Create " + request.kind.title, scope: request.scope, purpose: .creation(request.id)
    ) {
      actions.create(request)
    }
  }

  func previewPrompt(name: String, in scope: WorkspaceScope) {
    guard !isTerminating else { return }
    let request = PromptRequest(id: UUID(), scope: scope, name: name)
    promptSession = PromptSession(id: request.id, scope: scope, name: name)
    let actions = actions
    startOperation(title: "Generate prompt “\(name)”", scope: scope, purpose: .prompt(request.id)) {
      actions.render(request)
    }
  }

  func beginDraft(_ kind: ManifestDraft.Kind = .component) {
    guard !isTerminating else { return }
    var draft = ManifestDraft(scope: scope, document: snapshot?.document)
    draft.kind = kind
    draft.defaultAgents = snapshot?.document?.declaration.defaultAgents?.compactMap(
      AgentID.init(rawValue:))
    draft.exports = snapshot?.document?.declaration.exports ?? []
    manifestDraft = draft
  }

  func validateDraft() {
    guard !isTerminating, let draft = manifestDraft, !draft.isValidating,
      draft.kind != .structure || draft.structuralNode != nil,
      let document = draft.document
    else { return }
    manifestDraft?.isValidating = true
    let request = DraftValidationRequest(
      id: draft.id, document: document, edits: draft.edits(home: home), scope: draft.scope)
    let actions = actions
    startOperation(
      title: "Validate declaration draft", scope: draft.scope, purpose: .draft(draft.id)
    ) {
      actions.validate(request)
    }
  }

  func chooseMappings() {
    guard !isTerminating else { return }
    var roots = preferences.projects
    if scope.kind == .project, !roots.contains(scope.root) { roots.append(scope.root) }
    mappingSession = MappingSession(
      scope: scope, availableProjects: roots,
      selectedProjects: scope.kind == .project ? [scope.root] : [])
  }

  func readMappings() {
    guard !isTerminating, let session = mappingSession, case .input = session.stage else { return }
    mappingSession?.stage = .loading
    let request = MappingRequest(
      id: session.id, context: session.scope, projects: session.selectedProjects)
    let actions = actions
    startOperation(
      title: "Read instruction mappings", scope: session.scope, purpose: .mappings(session.id)
    ) {
      actions.mappings(request)
    }
  }

  private func finishContent(
    _ operation: ActiveOperation, result: CoreCompletion, currentSelection: Bool
  ) {
    switch operation.purpose {
    case .creation(let id) where creationSession?.id == id:
      creationSession?.messages = result.diagnostics
      switch result.output {
      case .created(_, let url): creationSession?.stage = .created(url)
      default:
        creationSession?.stage = result.disposition == .cancelled ? .cancelled : .failed
      }
    case .prompt(let id) where promptSession?.id == id:
      promptSession?.messages = result.diagnostics
      if !currentSelection {
        promptSession?.stage = .outdated
      } else if case .prompt(_, let text) = result.output {
        promptSession?.stage = .ready(text)
      } else {
        promptSession?.stage = result.disposition == .cancelled ? .cancelled : .failed
      }
    case .mappings(let id) where mappingSession?.id == id:
      if !currentSelection {
        mappingSession?.stage = .outdated
      } else if case .mappings(_, let mappings) = result.output {
        mappingSession?.stage = .loaded(mappings)
      } else {
        mappingSession?.stage = .cancelled
      }
    case .draft(let id) where manifestDraft?.id == id:
      manifestDraft?.isValidating = false
      if !currentSelection {
        manifestDraft?.validation = "Selection changed. Open a new draft for the current scope."
      } else if case .validatedDraft(_, let message) = result.output {
        manifestDraft?.validation = message
      } else if result.disposition == .cancelled {
        manifestDraft?.validation = "Validation was cancelled before it started."
      } else {
        manifestDraft?.validation = result.diagnostics.map(\.message).joined(separator: "\n")
      }
    default: break
    }
  }

  func cancelQueuedOperations() {
    for operation in operations.values { operation.admission.cancel() }
  }

  func requestTermination() -> TerminationDecision {
    if diagnostics.contains(where: \.blocksTermination) {
      terminationBlocked = true
      return .cancel
    }
    isTerminating = true
    cancelQueuedOperations()
    return operations.isEmpty ? .now : .later
  }

  private func finish(_ id: UUID, result: CoreCompletion) {
    guard let operation = operations[id] else { return }
    // Terminal evidence belongs to the original operation even when its content is obsolete.
    for diagnostic in result.diagnostics + (result.snapshot?.diagnostics ?? []) {
      if !diagnostics.contains(where: {
        $0.scope == diagnostic.scope && $0.operation == diagnostic.operation
          && $0.message == diagnostic.message && $0.path == diagnostic.path
          && $0.blocksTermination == diagnostic.blocksTermination
      }) {
        diagnostics.append(diagnostic)
      }
    }
    operations.removeValue(forKey: id)
    let currentSelection = operation.selectionScope == scope && operation.generation == generation
    finishContent(operation, result: result, currentSelection: currentSelection)
    if currentSelection {
      if let snapshot = result.snapshot {
        loadState = .loaded(snapshot)
      } else if case .workspace = operation.purpose, case .failed = result.disposition {
        loadState = .failed(result.diagnostics)
      } else if case .workspace = operation.purpose, case .cancelled = result.disposition {
        loadState = .idle
      }
    }
    if isTerminating, operations.isEmpty {
      let mayQuit = !diagnostics.contains(where: \.blocksTermination)
      terminationBlocked = !mayQuit
      if !mayQuit { isTerminating = false }
      terminationReply?(mayQuit)
    }
  }
}

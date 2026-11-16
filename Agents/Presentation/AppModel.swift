import AgentsCore
import AgentsManifest
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
  enum TerminationDecision { case now, later, cancel }
  struct ActiveOperation {
    let id: UUID
    let scope: WorkspaceScope
    let generation: UUID
    let title: String
    let admission: OperationAdmission
  }

  let preferences: AppPreferences
  let home: URL
  private let executor: CoreExecutor
  private let reader: CoreReader
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
  @ObservationIgnored var terminationReply: (@MainActor (Bool) -> Void)?

  init(
    home: URL, preferences: AppPreferences, executor: CoreExecutor = CoreExecutor(),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.home = home
    self.preferences = preferences
    self.executor = executor
    reader = CoreReader(home: home, processEnvironment: processEnvironment)
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
    startOperation(title: "Read configuration", scope: scope, generation: generation) {
      reader.read(scope: scope)
    }
  }

  @discardableResult
  func startOperation(
    title: String, scope: WorkspaceScope, generation: UUID? = nil,
    work: @escaping @Sendable () -> CoreCompletion
  ) -> UUID? {
    guard !isTerminating else { return nil }
    let id = UUID()
    let operation = ActiveOperation(
      id: id, scope: scope, generation: generation ?? self.generation,
      title: title, admission: OperationAdmission())
    operations[id] = operation
    executor.submit(admission: operation.admission, work: work) { result in
      Task { @MainActor [self] in finish(id, result: result) }
    }
    return id
  }

  func cancelQueuedReads() {
    for operation in operations.values { operation.admission.cancel() }
  }

  func requestTermination() -> TerminationDecision {
    if diagnostics.contains(where: \.blocksTermination) {
      terminationBlocked = true
      return .cancel
    }
    isTerminating = true
    cancelQueuedReads()
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
    if operation.scope == scope, operation.generation == generation {
      if let snapshot = result.snapshot {
        loadState = .loaded(snapshot)
      } else if case .failed = result.disposition {
        loadState = .failed(result.diagnostics)
      } else if case .cancelled = result.disposition {
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

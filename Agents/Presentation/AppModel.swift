import AgentsCore
import AgentsManifest
import AgentsUpdates
import CoreServices
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
  enum TerminationDecision { case now, later, cancel }
  enum OperationPurpose {
    case assistance(UUID)
    case workspace
    case creation(UUID)
    case prompt(UUID)
    case discovery(UUID)
    case preview(UUID)
    case apply(UUID)
    case mappings(UUID)
    case other
  }
  struct ActiveOperation {
    let id: UUID
    let scope: WorkspaceScope
    let selectionScope: WorkspaceScope
    let purpose: OperationPurpose
    let generation: UUID
    let sequence: Int
    let title: String
    let admission: OperationAdmission
  }

  let preferences: AppPreferences
  let home: URL
  private let executor: CoreExecutor
  private let reader: CoreReader
  private let actions: CoreActions
  private let assistance: AssistanceService
  @ObservationIgnored private var assistanceTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var readMonitor: ReadMonitor?
  private var monitoredScope: WorkspaceScope?
  private var readBoundary: FSEventStreamEventId = 0
  private(set) var readsStale = false
  private var refreshScheduled = false
  var assistanceSession: AssistanceSession?
  var assistanceAvailable: Bool { preferences.assistanceEnabled && assistance.available() }

  private(set) var scope: WorkspaceScope
  private(set) var loadState: WorkspaceLoadState = .idle
  private(set) var operations: [UUID: ActiveOperation] = [:]
  private(set) var diagnostics: [AppDiagnostic] = []
  private(set) var isTerminating = false
  private(set) var terminationBlocked = false
  private var generation = UUID()
  private var operationSequence = 0
  private var recoverySequence: [WorkspaceScope: Int] = [:]
  private var unresolvedCoreRecovery: Set<WorkspaceScope> = []
  var page: WorkspacePage = .overview
  var selectedItem: NodeID?
  var search = ""
  var presentedIntent: WorkspaceIntent?
  var creationSession: CreationSession?
  var promptSession: PromptSession?
  var manifestDraft: ManifestDraft?
  var mappingSession: MappingSession?
  var updateSession: UpdateSession?
  var discoverySession: DiscoverySession?
  private(set) var updateRecords: [UpdateRecord] = []
  var isApplying: Bool {
    operations.values.contains {
      if case .apply = $0.purpose { return true }
      return false
    }
  }
  var canModify: Bool {
    !isTerminating && !isApplying && !readsStale && snapshot?.inspection.recovery.pending == false
  }
  var availableComponentSelection: [ComponentInspection] { snapshot?.inspection.components ?? [] }
  @ObservationIgnored var terminationReply: (@MainActor (Bool) -> Void)?

  init(
    home: URL, preferences: AppPreferences, executor: CoreExecutor = CoreExecutor(),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    assistance: AssistanceService = .onDevice
  ) {
    self.home = home
    self.preferences = preferences
    self.executor = executor
    self.assistance = assistance
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
    guard self.scope != scope, !isTerminating, !isApplying else { return }
    stopMonitoring()
    cancelAssistance()
    self.scope = scope
    preferences.selectedScopeID = scope.id
    selectedItem = nil
    search = ""
    refresh()
  }

  func addProject(_ url: URL) {
    guard !isTerminating, !isApplying else { return }
    preferences.addProject(url)
    select(WorkspaceScope(kind: .project, root: url.standardizedFileURL))
  }

  func removeProject(_ url: URL) {
    guard !isTerminating, !isApplying else { return }
    preferences.removeProject(url)
    if scope.root == url, scope.kind == .project {
      select(WorkspaceScope(kind: .user, root: home))
    }
  }

  func refresh() {
    guard !isTerminating, !isApplying else { return }
    // Superseded queued reads still report a terminal; running reads are allowed to finish.
    for operation in operations.values where operation.title == "Read configuration" {
      operation.admission.cancel()
    }
    if case .review = updateSession?.stage { updateSession?.stage = .stale }
    generation = UUID()
    readsStale = true
    if snapshot?.scope != scope { loadState = .loading }
    readBoundary = FSEventsGetCurrentEventId()
    monitor(reader.stateLocations(scope: scope), since: readBoundary)
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
    purpose: OperationPurpose = .other, admission: OperationAdmission? = nil,
    work: @escaping @Sendable () -> CoreCompletion
  ) -> UUID? {
    guard !isTerminating else { return nil }
    let id = UUID()
    operationSequence += 1
    let operation = ActiveOperation(
      id: id, scope: scope, selectionScope: self.scope, purpose: purpose,
      generation: generation ?? self.generation, sequence: operationSequence,
      title: title, admission: admission ?? OperationAdmission())
    operations[id] = operation
    executor.submit(admission: operation.admission, work: work) { result in
      Task { @MainActor [self] in finish(id, result: result) }
    }
    return id
  }

  func beginCreation(_ kind: CreationRequest.Kind) {
    guard !isTerminating, !isApplying, snapshot?.inspection.recovery.pending != true,
      kind != .instructions || scope.kind == .project
    else { return }
    creationSession = CreationSession(scope: scope, kind: kind, directory: scope.root)
  }

  func selectCreationDirectory(_ url: URL) {
    guard creationSession?.kind == .skill else { return }
    creationSession?.directory = url
    creationSession?.directorySelected = true
  }

  func confirmCreation() {
    guard !isTerminating, !isApplying, snapshot?.inspection.recovery.pending != true,
      let session = creationSession, case .confirmation = session.stage,
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
    guard canModify else { return }
    var draft = ManifestDraft(scope: scope, document: snapshot?.document)
    draft.kind = kind
    draft.defaultAgents = snapshot?.document?.declaration.defaultAgents?.compactMap(
      AgentID.init(rawValue:))
    draft.exports = snapshot?.document?.declaration.exports ?? []
    if let declaration = snapshot?.inspection.declaration {
      draft.captureReferences(from: declaration)
    }
    manifestDraft = draft
  }

  func editSelectedDeclaration() {
    guard canModify, let item = selectedDeclaration,
      let declaration = snapshot?.inspection.declaration
    else { return }
    beginDraft()
    manifestDraft?.load(item, from: declaration)
  }

  func discoverComponents() {
    guard canModify, let declaration = snapshot?.inspection.declaration else { return }
    let id = UUID()
    let scope = scope
    let actions = actions
    discoverySession = .init(id: id, scope: scope)
    startOperation(title: "Discover declared components", scope: scope, purpose: .discovery(id)) {
      actions.discover(id: id, scope: scope, declaration: declaration)
    }
  }

  func previewDiscovery() {
    guard let session = discoverySession, session.scope == scope,
      let discovery = session.discovery, canModify
    else { return }
    discoverySession = nil
    previewUpdate(title: "Apply Discovered Components", request: discovery.updateRequest())
  }

  func previewDraft() {
    guard canModify, let draft = manifestDraft, draft.canReview(against: snapshot),
      draft.scope == scope,
      draft.kind != .structure || draft.structuralReady
    else { return }
    manifestDraft?.isStale = false
    previewUpdate(title: "Edit Configuration", request: draft.updateRequest(home: home))
  }

  func previewUpdate(title: String, request: UpdateRequest = UpdateRequest()) {
    guard canModify else { return }
    let proposal = UpdateProposal(id: UUID(), scope: scope, title: title, request: request)
    updateSession = UpdateSession(proposal: proposal)
    let actions = actions
    startOperation(title: "Prepare " + title, scope: scope, purpose: .preview(proposal.id)) {
      actions.preview(proposal)
    }
  }

  func confirmUpdate() {
    guard canModify, let session = updateSession, case .review = session.stage,
      session.proposal.scope == scope, session.bindingsReady, let report = session.report
    else { return }
    updateSession?.stage = .applying
    let proposal = session.proposal
    let actions = actions
    let admission = OperationAdmission()
    let bindings = session.bindingInputs.mapValues { Data($0.utf8) }
    updateSession?.bindingInputs = [:]
    startOperation(
      title: proposal.title, scope: proposal.scope, purpose: .apply(proposal.id),
      admission: admission
    ) {
      actions.apply(
        proposal, fingerprint: report.displayedFingerprint, admission: admission, bindings: bindings
      )
    }
  }

  func closeUpdateReview() {
    guard !isApplying else { return }
    let committed = updateSession?.terminal?.disposition == .committed
    updateSession = nil
    if committed { manifestDraft = nil }
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
    case .assistance(let id) where assistanceSession?.id == id:
      if !currentSelection || !preferences.assistanceEnabled {
        assistanceSession?.stage = .outdated
      } else if result.disposition == .cancelled {
        assistanceSession?.stage = .cancelled
      } else if case .assistance(_, let text) = result.output {
        assistanceSession?.stage = .finished(text)
      } else {
        assistanceSession?.stage = .failed
      }
    case .creation(let id) where creationSession?.id == id:
      creationSession?.messages = result.diagnostics
      switch result.output {
      case .created(_, let url): creationSession?.stage = .created(url)
      case .creationUnconfirmed: creationSession?.stage = .unconfirmed
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
    case .discovery(let id) where discoverySession?.id == id:
      discoverySession?.isLoading = false
      discoverySession?.messages = result.diagnostics
      if currentSelection, case .discovery(_, let value) = result.output {
        discoverySession?.discovery = value
      } else if !currentSelection {
        discoverySession?.messages.append(
          .init(
            scope: operation.scope, operation: "Discovery",
            message: "Selection changed. Discover again for the selected scope."))
      }
    case .preview(let id) where updateSession?.id == id:
      updateSession?.messages = result.diagnostics
      if !currentSelection {
        updateSession?.stage = .stale
      } else if case .updatePreview(_, let report) = result.output {
        updateSession?.report = report
        updateSession?.stage = .review
      } else {
        updateSession?.stage = result.disposition == .cancelled ? .cancelled : .failed
      }
    case .apply(let id) where updateSession?.id == id:
      updateSession?.messages = result.diagnostics
      updateSession?.terminal = result.updateTerminal
      updateSession?.stage = result.disposition == .cancelled ? .cancelled : .finished
    default: break
    }
  }

  func recoverScope(in confirmedScope: WorkspaceScope) {
    guard confirmedScope == scope, !isTerminating, !isApplying,
      snapshot?.inspection.recovery.pending == true
    else { return }
    let proposal = UpdateProposal(
      id: UUID(), scope: scope, title: "Recover Configuration", request: .init())
    updateSession = UpdateSession(proposal: proposal, stage: .applying)
    let admission = OperationAdmission()
    let actions = actions
    startOperation(
      title: proposal.title, scope: scope, purpose: .apply(proposal.id), admission: admission
    ) {
      actions.apply(proposal, fingerprint: "", admission: admission, recoveryOnly: true)
    }
  }

  private var hasBlockingCleanup: Bool {
    diagnostics.contains {
      $0.blocksTermination && (!$0.coreRecovery || unresolvedCoreRecovery.contains($0.scope))
    }
  }

  func setAssistanceEnabled(_ enabled: Bool) {
    preferences.assistanceEnabled = enabled
    if !enabled {
      cancelAssistance()
      assistanceSession = nil
    }
  }

  func reviewAssistance(_ input: AssistanceInput) {
    guard assistanceAvailable, !isTerminating, assistanceTasks.isEmpty else { return }
    assistanceSession = .init(scope: scope, input: input)
  }

  func generateAssistance() {
    guard assistanceAvailable, !isTerminating, let session = assistanceSession,
      session.scope == scope, case .review = session.stage, session.input.withinLimit,
      assistanceTasks.isEmpty
    else { return }
    let id = UUID()
    operationSequence += 1
    let operation = ActiveOperation(
      id: id, scope: scope, selectionScope: scope,
      purpose: .assistance(session.id), generation: generation, sequence: operationSequence,
      title: session.input.action.rawValue, admission: OperationAdmission())
    operations[id] = operation
    assistanceSession?.stage = .running
    let service = assistance
    assistanceTasks[id] = Task { [self] in
      let result: CoreCompletion
      do {
        try Task.checkCancellation()
        let text = try await service.generate(session.input)
        try Task.checkCancellation()
        result = .init(disposition: .completed, output: .assistance(session.id, text))
      } catch is CancellationError { result = .cancelled } catch {
        // Model errors can quote prompt text; diagnostics intentionally retain no provider payload.
        result = .init(
          disposition: .failed,
          diagnostics: [
            .init(
              scope: operation.scope,
              operation: operation.title,
              message: "On-device assistance could not complete. No changes were applied.")
          ])
      }
      assistanceTasks[id] = nil
      finish(id, result: result)
    }
  }

  func cancelAssistance() { for task in assistanceTasks.values { task.cancel() } }

  private func monitor(_ locations: [URL], since: FSEventStreamEventId) {
    guard !isTerminating else { return }
    if readMonitor == nil || monitoredScope != scope {
      stopMonitoring()
      let watchedScope = scope
      readMonitor = ReadMonitor { [weak self] in
        Task { @MainActor [weak self] in self?.inputsChanged(in: watchedScope) }
      }
      monitoredScope = scope
    }
    do { try readMonitor?.replace(locations: locations, since: since) } catch {
      diagnostics.append(
        .init(
          scope: scope, operation: "Automatic refresh", severity: .warning,
          message: error.localizedDescription))
    }
  }

  private func stopMonitoring() {
    readMonitor?.stop()
    readMonitor = nil
    monitoredScope = nil
  }

  private func inputsChanged(in watchedScope: WorkspaceScope) {
    guard watchedScope == scope, !isTerminating else { return }
    readsStale = true
    manifestDraft?.isStale = true
    if let session = updateSession, session.stage == .review || session.stage == .preparing {
      updateSession?.stage = .stale
      updateSession?.bindingInputs = [:]
    }
    guard !isApplying, !refreshScheduled else { return }
    refreshScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      // Coalesce one native event batch without polling the file system.
      await Task.yield()
      refreshScheduled = false
      if !isTerminating && !isApplying { refresh() }
    }
  }

  func cancelQueuedOperations() {
    for operation in operations.values { operation.admission.cancel() }
    cancelAssistance()
  }

  func requestTermination() -> TerminationDecision {
    if hasBlockingCleanup {
      terminationBlocked = true
      return .cancel
    }
    isTerminating = true
    stopMonitoring()
    cancelQueuedOperations()
    return operations.isEmpty ? .now : .later
  }

  private func observeRecovery(_ recovery: RecoveryInspection, scope: WorkspaceScope, sequence: Int)
  {
    guard sequence >= (recoverySequence[scope] ?? 0) else { return }
    recoverySequence[scope] = sequence
    if recovery.pending {
      unresolvedCoreRecovery.insert(scope)
    } else {
      unresolvedCoreRecovery.remove(scope)
    }
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
    if let terminal = result.updateTerminal {
      observeRecovery(terminal.recovery, scope: operation.scope, sequence: operation.sequence)
      updateRecords.append(
        .init(id: id, scope: operation.scope, title: operation.title, terminal: terminal))
    }
    if let snapshot = result.snapshot {
      observeRecovery(
        snapshot.inspection.recovery, scope: snapshot.scope, sequence: operation.sequence)
    }
    operations.removeValue(forKey: id)
    let currentSelection = operation.selectionScope == scope && operation.generation == generation
    finishContent(operation, result: result, currentSelection: currentSelection)
    if currentSelection {
      if let snapshot = result.snapshot {
        loadState = .loaded(snapshot)
        readsStale = false
        if let selectedItem, !snapshot.items.contains(where: { $0.id == selectedItem }) {
          self.selectedItem = nil
        }
        monitor(snapshot.inspection.readLocations, since: readBoundary)
      } else if case .workspace = operation.purpose, case .failed = result.disposition {
        loadState = .failed(result.diagnostics)
      } else if case .workspace = operation.purpose, case .cancelled = result.disposition {
        loadState = .idle
      }
    }
    if case .apply = operation.purpose, !isTerminating, currentSelection {
      refresh()
    }
    if isTerminating, operations.isEmpty {
      let mayQuit = !hasBlockingCleanup
      terminationBlocked = !mayQuit
      if !mayQuit {
        isTerminating = false
        monitor(
          snapshot?.inspection.readLocations ?? reader.stateLocations(scope: scope),
          since: readBoundary)
      }
      terminationReply?(mayQuit)
    }
  }
}

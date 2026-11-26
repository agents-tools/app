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
    case clients(UUID)
    case clientBackup
    case clientRestoreRead(UUID)
    case clientRestoreWrite(UUID)
    case watchSeen(UUID)
    case assistance(UUID)
    case workspace
    case creation(UUID)
    case creationPreview(UUID)
    case watchStatus(UUID)
    case watchPreview(UUID)
    case watchApply(UUID)
    case catalog(UUID)
    case catalogSelection(UUID)
    case sourceAccessInspection(SourceAccessSelection.ID)
    case sourceAccessValidation(SourceAccessSelection.ID)
    case sourceAccessSettings(UUID)
    case sourceImport(UUID)
    case importRequest(UUID)
    case connectionSnapshot(UUID)
    case connectionTest(UUID)
    case prompt(UUID)
    case discovery(UUID)
    case preview(UUID)
    case apply(UUID)
    case packageActionTest
    case packageActionWrite
    case existingConfigurationPreview(UUID)
    case existingConfigurationApply(UUID)
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
  let clientSettings = ClientSettingsModel()
  let sourceAccessSettings = SourceAccessSettingsModel()
  let home: URL
  private let executor: CoreExecutor
  private let sourceAccessValidationExecutor = CoreExecutor()
  let processEnvironment: [String: String]
  private var reader: CoreReader {
    CoreReader(
      home: home, processEnvironment: processEnvironment,
      policyFiles: preferences.organizationPolicyFiles)
  }
  var actions: CoreActions {
    CoreActions(
      home: home, processEnvironment: processEnvironment,
      policyFiles: preferences.organizationPolicyFiles)
  }
  private let assistance: AssistanceService
  private let connectionTest:
    @Sendable (MCPConnectionSnapshot, RuntimeEnvironment, [String: Data]) async ->
      MCPConnectionTestResult
  @ObservationIgnored private var asyncTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var readMonitor: ReadMonitor?
  private var supplementalReadDependencies: Set<ReadDependency> = []
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
  var page: WorkspacePage = .overview {
    didSet {
      guard page != oldValue else { return }
      if selectedItem != nil {
        selectedItem = nil
      } else {
        discardSourceAccess()
      }
    }
  }
  var clientFilter: AgentID?
  var selectedSkillID: String?
  var selectedItem: NodeID? {
    didSet { if selectedItem != oldValue { discardSourceAccess() } }
  }
  private(set) var sourceAccessSession: SourceAccessSession?
  private var sourceAccessPresentation = UUID()
  var search = ""
  var creationSession: CreationSession?
  var promptSession: PromptSession?
  var manifestDraft: ManifestDraft?
  var mappingSession: MappingSession?
  var updateSession: UpdateSession?
  var existingConfigurationSession: ExistingConfigurationSession?
  private(set) var didApplyExistingConfiguration = false
  var registrySession: RegistrySession?
  var packageScope: WorkspaceScope?
  var catalogSession: CatalogSession?
  var discoverySession: DiscoverySession?
  var watchSession: WatchSession?
  var watchStatusSession: WatchStatusSession?
  var importSession: ImportSession?
  var connectionSession: ConnectionSession?
  var backupClients: Set<BackupClient> = []
  var backupProjects: Set<URL> = []
  var backupDirectory: URL?
  var backupOutcomes: [ClientBackupOutcome] = []
  var isBackingUp = false
  var restoreSession: ClientRestoreSession?
  private(set) var updateRecords: [UpdateRecord] = []
  var isApplying: Bool {
    operations.values.contains {
      switch $0.purpose {
      case .apply, .existingConfigurationApply, .creation, .watchApply, .watchSeen,
        .clientRestoreWrite, .packageActionTest, .packageActionWrite:
        return true
      default: return false
      }
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
    assistance: AssistanceService = .onDevice,
    connectionTest:
      @escaping @Sendable (MCPConnectionSnapshot, RuntimeEnvironment, [String: Data]) async ->
      MCPConnectionTestResult = { snapshot, environment, values in
        await MCPConnectionOperations.test(
          snapshot, environment: environment, bindings: EphemeralBindings(values: values))
      }
  ) {
    self.home = home
    self.preferences = preferences
    self.executor = executor
    self.assistance = assistance
    self.connectionTest = connectionTest
    self.processEnvironment = processEnvironment
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
    if case .loaded(let value) = loadState, value.scope == scope { return value }
    return nil
  }
  var selectedDeclaration: DeclarationItem? { snapshot?.items.first { $0.id == selectedItem } }
  var currentDiagnostics: [AppDiagnostic] { diagnostics.filter { $0.scope == scope } }
  var currentScopeProblems: [AppDiagnostic] {
    if case .failed(let diagnostics) = loadState { return diagnostics }
    return snapshot?.diagnostics.filter { $0.severity != .information } ?? []
  }
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

  func showClientOverview(_ agent: AgentID) {
    clientFilter = agent
    page = .overview
  }

  func select(_ scope: WorkspaceScope) {
    guard self.scope != scope, !isTerminating, !isApplying else { return }
    stopMonitoring()
    supplementalReadDependencies = []
    cancelAssistance()
    cancelConnection()
    cancelExistingConfiguration()
    didApplyExistingConfiguration = false
    self.scope = scope
    preferences.selectedScopeID = scope.id
    selectedItem = nil
    selectedSkillID = nil
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
    backupProjects.remove(url.standardizedFileURL)
    if scope.root == url, scope.kind == .project {
      select(WorkspaceScope(kind: .user, root: home))
    }
  }

  func refresh() {
    guard !isTerminating, !isApplying else { return }
    discardSourceAccess()
    // Superseded queued reads still report a terminal; running reads are allowed to finish.
    for operation in operations.values where operation.title == "Read configuration" {
      operation.admission.cancel()
    }
    if case .review = updateSession?.stage {
      updateSession?.stage = .stale
      updateSession?.packageReview = nil
      updateSession?.bindingInputs = [:]
    }
    generation = UUID()
    readsStale = true
    if snapshot?.scope != scope { loadState = .loading }
    readBoundary = FSEventsGetCurrentEventId()
    monitor(reader.stateDependencies(scope: scope), since: readBoundary)
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
    executor: CoreExecutor? = nil,
    work: @escaping @Sendable () -> CoreCompletion
  ) -> UUID? {
    guard let operation = registerOperation(
      title: title, scope: scope, generation: generation ?? self.generation,
      purpose: purpose, admission: admission ?? OperationAdmission())
    else { return nil }
    (executor ?? self.executor).submit(admission: operation.admission, work: work) { result in
      Task { @MainActor [self] in finish(operation.id, result: result) }
    }
    return operation.id
  }

  @discardableResult
  func startPackageActionEffect(
    title: String, scope: WorkspaceScope, writes: Bool,
    work: @escaping @Sendable () async -> CoreCompletion,
    receive: @escaping @MainActor (CoreCompletion) -> Void
  ) -> Bool {
    guard !isApplying, self.scope == scope else { return false }
    return startAsyncOperation(
      title: title, scope: scope, purpose: writes ? .packageActionWrite : .packageActionTest,
      work: work, receive: receive)
  }

  @discardableResult
  private func startAsyncOperation(
    title: String, scope: WorkspaceScope, purpose: OperationPurpose,
    work: @escaping @Sendable () async -> CoreCompletion,
    receive: @escaping @MainActor (CoreCompletion) -> Void = { _ in }
  ) -> Bool {
    guard let operation = registerOperation(
      title: title, scope: scope, generation: generation, purpose: purpose,
      admission: OperationAdmission())
    else { return false }
    executor.submitAsync(admission: operation.admission, work: work) { result in
      Task { @MainActor [self] in
        finish(operation.id, result: result)
        if !isTerminating { receive(result) }
      }
    }
    return true
  }

  private func registerOperation(
    title: String, scope: WorkspaceScope, generation: UUID,
    purpose: OperationPurpose, admission: OperationAdmission
  ) -> ActiveOperation? {
    guard !isTerminating else { return nil }
    let id = UUID()
    operationSequence += 1
    let operation = ActiveOperation(
      id: id, scope: scope, selectionScope: self.scope, purpose: purpose,
      generation: generation, sequence: operationSequence, title: title, admission: admission)
    operations[id] = operation
    if sourceAccessSession != nil, isApplying { discardSourceAccess() }
    return operation
  }

  func beginCreation(_ kind: CreationRequest.Kind) {
    guard !isTerminating, !isApplying, snapshot?.inspection.recovery.pending != true,
      kind != .instructions || scope.kind == .project
    else { return }
    creationSession = CreationSession(scope: scope, kind: kind, directory: scope.root)
  }

  func selectCreationDirectory(_ url: URL, for original: CreationSession) {
    guard !isTerminating, !isApplying, snapshot?.inspection.recovery.pending != true,
      let session = creationSession, session.id == original.id, session.scope == original.scope,
      session.scope == scope, case .input = session.stage
    else { return }
    selectCreationDirectory(url)
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
    guard !session.stale, session.scope == scope, let description = session.description else {
      return
    }
    let request = session.request
    creationSession?.stage = .running
    let actions = actions
    startOperation(
      title: "Create " + request.kind.title, scope: request.scope, purpose: .creation(request.id)
    ) {
      actions.initialize(description, request: request)
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
      let discovery = session.discovery, !session.stale, canModify
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

  func previewUpdate(
    title: String, request: UpdateRequest = UpdateRequest(), intent: LifecycleOperationIntent? = nil
  ) {
    guard canModify else { return }
    previewUpdate(UpdateProposal(
      id: UUID(), scope: scope, title: title, request: request, intent: intent))
  }

  func previewUpdate(_ proposal: UpdateProposal) {
    guard canModify, proposal.scope == scope else { return }
    updateSession = UpdateSession(proposal: proposal)
    let actions = actions
    startOperation(title: "Prepare " + proposal.title, scope: scope, purpose: .preview(proposal.id))
    {
      actions.preview(proposal)
    }
  }

  func confirmUpdate() {
    guard canModify, let session = updateSession, case .review = session.stage,
      session.proposal.scope == scope, session.bindingsReady, session.canApplyReport,
      let report = session.report
    else { return }
    updateSession?.stage = .applying
    let proposal = session.proposal
    let actions = actions
    let bindings = session.bindingInputs.mapValues { Data($0.utf8) }
    updateSession?.bindingInputs = [:]
    if let review = session.packageReview {
      updateSession?.packageReview = nil
      startAsyncOperation(title: proposal.title, scope: proposal.scope, purpose: .apply(proposal.id)) {
        await review.apply(proposal.title, EphemeralBindings(values: bindings))
      }
      return
    }
    let admission = OperationAdmission()
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
      creationSession?.terminal = result.updateTerminal
      switch result.output {
      case .created(_, let url): creationSession?.stage = .created(url)
      default:
        creationSession?.stage = result.disposition == .cancelled ? .cancelled : .failed
      }
    case .creationPreview(let id) where creationSession?.id == id:
      creationSession?.messages = result.diagnostics
      if currentSelection, case .creationDescription(_, let description) = result.output {
        creationSession?.description = description
        creationSession?.stale = false
        creationSession?.stage = .confirmation
      } else {
        creationSession?.stage = result.disposition == .cancelled ? .cancelled : .failed
      }
    case .clients(let id):
      clientSettings.finish(id: id, result: result)
    case .sourceAccessSettings(let id):
      sourceAccessSettings.finish(id: id, result: result)
      switch result.output {
      case .sourceAccessSettings(.saved), .sourceAccessSettings(.failed(.core(.changed))):
        inputsChanged(in: scope)
      default: break
      }
    case .clientBackup:
      isBackingUp = false
      if case .clientBackup(let outcomes) = result.output { backupOutcomes = outcomes }
    case .clientRestoreRead(let id), .clientRestoreWrite(let id):
      finishClientRestore(id: id, result: result)
    case .watchSeen(let id) where watchStatusSession?.id == id:
      watchStatusSession?.busy = false
      watchStatusSession?.terminal = result.updateTerminal
      watchStatusSession?.messages = result.diagnostics
      if result.disposition == .cancelled {
        watchStatusSession?.messages.append(
          .init(
            scope: operation.scope, operation: operation.title, severity: .information,
            message: "Acknowledgment was cancelled before it started."))
      }
      watchStatusSession?.stale = true
    case .watchStatus(let id) where watchStatusSession?.id == id:
      watchStatusSession?.busy = false
      watchStatusSession?.messages = result.diagnostics
      if currentSelection, case .watchStatus(_, let values) = result.output {
        watchStatusSession?.statuses = values
        watchStatusSession?.hasResult = true
        watchStatusSession?.stale = false
      } else if result.disposition == .cancelled {
        watchStatusSession?.messages.append(
          .init(
            scope: operation.scope, operation: "Check subscriptions",
            severity: .information, message: "Check was cancelled before results were available."))
      } else if !currentSelection {
        watchStatusSession?.stale = true
      }
    case .watchPreview(let id) where watchSession?.id == id:
      watchSession?.busy = false
      watchSession?.messages = result.diagnostics
      if currentSelection, case .watchPreview(_, let preview) = result.output {
        watchSession?.preview = preview
        watchSession?.stale = false
      }
    case .watchApply(let id) where watchSession?.id == id:
      watchSession?.busy = false
      watchSession?.terminal = result.updateTerminal
      watchSession?.messages = result.diagnostics
    case .catalog(let id) where catalogSession?.id == id:
      catalogSession?.busy = false
      catalogSession?.messages = result.diagnostics
      if result.disposition == .cancelled {
        catalogSession?.messages.append(
          .init(
            scope: operation.scope, operation: operation.title,
            severity: .information, message: "Queued source operation was cancelled."))
      }
      if currentSelection, case .catalog(_, let value) = result.output {
        catalogSession?.capture(value)
      } else if !currentSelection {
        catalogSession?.stale = true
      }
    case .catalogSelection(let id) where catalogSession?.id == id:
      catalogSession?.busy = false
      catalogSession?.messages = result.diagnostics
      if result.disposition == .cancelled {
        catalogSession?.messages.append(
          .init(
            scope: operation.scope, operation: operation.title,
            severity: .information, message: "Queued source operation was cancelled."))
      }
      if currentSelection, case .catalogRequest(_, let request) = result.output, let request {
        catalogSession = nil
        previewUpdate(title: "Add Selected Source Content", request: request)
      } else if !currentSelection {
        catalogSession?.stale = true
      }
    case .sourceAccessInspection(let selection) where sourceAccessSession?.selection == selection:
      guard currentSelection, sourceAccessSelection?.id == selection else { return }
      if case .sourceAccessInspection(let inspection) = result.output {
        sourceAccessSession?.inspection = inspection
      } else {
        sourceAccessSession?.inspection = .failure(.unavailable)
      }
    case .sourceAccessValidation(let selection) where sourceAccessSession?.selection == selection:
      guard currentSelection, sourceAccessSelection?.id == selection,
        sourceAccessSession?.validationOperation == operation.id
      else { return }
      sourceAccessSession?.validationOperation = nil
      if case .sourceAccessValidation(let validation) = result.output {
        sourceAccessSession?.validation = validation
      }
    case .sourceImport(let id) where importSession?.id == id:
      importSession?.busy = false
      importSession?.messages = result.diagnostics
      if currentSelection, case .sourceImport(_, let value) = result.output {
        importSession?.capture(value)
      } else if !currentSelection {
        importSession?.stale = true
      }
    case .importRequest(let id) where importSession?.id == id:
      importSession?.busy = false
      importSession?.messages = result.diagnostics
      if currentSelection, case .importRequest(_, let request) = result.output {
        importSession = nil
        previewUpdate(title: "Import Configuration", request: request)
      }
    case .connectionSnapshot(let id) where connectionSession?.id == id:
      connectionSession?.busy = false
      connectionSession?.messages = result.diagnostics
      if currentSelection, case .connectionSnapshot(_, let value, let description) = result.output {
        connectionSession?.snapshot = value
        connectionSession?.description = description
        connectionSession?.stale = false
      }
    case .connectionTest(let id) where connectionSession?.id == id:
      connectionSession?.busy = false
      connectionSession?.testing = false
      connectionSession?.messages = result.diagnostics
      if case .connectionResult(_, let value) = result.output { connectionSession?.result = value }
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
      if !currentSelection || updateSession?.stage == .stale {
        updateSession?.stage = .stale
      } else if case .packageUpdatePreview(_, let review) = result.output {
        updateSession?.report = review.report
        updateSession?.packageReview = review
        updateSession?.stage = .review
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
    case .existingConfigurationPreview(let id) where existingConfigurationSession?.id == id:
      existingConfigurationSession?.messages = result.diagnostics
      if case .existingConfigurationPreview(let review) = result.output {
        existingConfigurationSession?.review = review
        existingConfigurationSession?.stage = .review
        invalidateExistingConfigurationIfChanged()
      } else {
        existingConfigurationSession?.stage = .failed
      }
    case .existingConfigurationApply(let id) where existingConfigurationSession?.id == id:
      if result.disposition == .completed {
        existingConfigurationSession = nil
        didApplyExistingConfiguration = true
        page = .overview
      } else {
        existingConfigurationSession?.messages = result.diagnostics
        existingConfigurationSession?.stage = .failed
      }
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
    guard assistanceAvailable, !isTerminating, asyncTasks.isEmpty else { return }
    assistanceSession = .init(scope: scope, input: input)
  }

  func generateAssistance() {
    guard assistanceAvailable, !isTerminating, let session = assistanceSession,
      session.scope == scope, case .review = session.stage, session.input.withinLimit,
      asyncTasks.isEmpty
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
    asyncTasks[id] = Task { [self] in
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
      asyncTasks[id] = nil
      finish(id, result: result)
    }
  }

  func cancelAssistance() {
    for (id, task) in asyncTasks {
      if case .assistance = operations[id]?.purpose { task.cancel() }
    }
  }

  private func monitor(_ dependencies: [ReadDependency], since: FSEventStreamEventId) {
    guard !isTerminating else { return }
    if readMonitor == nil || monitoredScope != scope {
      stopMonitoring()
      let watchedScope = scope
      readMonitor = ReadMonitor { [weak self] in
        Task { @MainActor [weak self] in self?.inputsChanged(in: watchedScope) }
      }
      monitoredScope = scope
    }
    do {
      try readMonitor?.replace(
        dependencies: Array(Set(dependencies).union(supplementalReadDependencies)), since: since)
    } catch {
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
    discardSourceAccess()
    readsStale = true
    manifestDraft?.isStale = true
    creationSession?.stale = true
    watchStatusSession?.stale = true
    catalogSession?.stale = true
    discoverySession?.stale = true
    watchSession?.stale = true
    importSession?.stale = true
    connectionSession?.stale = true
    connectionSession?.inputs = [:]
    invalidateExistingConfigurationIfChanged()
    if let session = updateSession, session.stage == .review || session.stage == .preparing {
      updateSession?.stage = .stale
      updateSession?.packageReview = nil
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

  private func invalidateExistingConfigurationIfChanged() {
    guard let session = existingConfigurationSession, session.stage == .review,
      !session.stale, session.review?.inputs.hasChanged == true
    else { return }
    existingConfigurationSession?.stale = true
  }

  func cancelQueuedOperations() {
    for operation in operations.values { operation.admission.cancel() }
    for task in asyncTasks.values { task.cancel() }
    if let selection = sourceAccessSession?.selection { cancelSourceAccessValidation(selection) }
  }

  func requestTermination() -> TerminationDecision {
    if hasBlockingCleanup {
      terminationBlocked = true
      return .cancel
    }
    isTerminating = true
    discardSourceAccess()
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
    if currentSelection && !result.readDependencies.isEmpty {
      supplementalReadDependencies.formUnion(result.readDependencies)
      monitor(
        snapshot?.inspection.readLocations.map(ReadDependency.subtree)
          ?? reader.stateDependencies(scope: scope),
        since: readBoundary)
    }
    if currentSelection {
      if let snapshot = result.snapshot, snapshot.scope == scope {
        loadState = .loaded(snapshot)
        readsStale = false
        if let selectedItem, !snapshot.items.contains(where: { $0.id == selectedItem }) {
          self.selectedItem = nil
        }
        if let selectedSkillID, !snapshot.skillWorkspaceItems.contains(where: { $0.id == selectedSkillID }) {
          self.selectedSkillID = nil
        }
        monitor(snapshot.inspection.readLocations.map(ReadDependency.subtree), since: readBoundary)
      } else if case .workspace = operation.purpose,
        case .existingConfigurationAvailable = result.output
      {
        loadState = .existingConfigurationAvailable
        readsStale = false
        selectedSkillID = nil
      } else if case .workspace = operation.purpose, case .failed = result.disposition {
        loadState = .failed(result.diagnostics)
        selectedSkillID = nil
      } else if case .workspace = operation.purpose, case .cancelled = result.disposition {
        loadState = .idle
      }
      if case .workspace = operation.purpose { invalidateExistingConfigurationIfChanged() }
    }
    if !isTerminating && currentSelection {
      switch operation.purpose {
      case .apply, .existingConfigurationApply, .creation, .watchApply, .watchSeen,
        .clientRestoreWrite, .packageActionWrite:
        refresh()
      default: break
      }
    }
    if isTerminating, operations.isEmpty {
      let mayQuit = !hasBlockingCleanup
      terminationBlocked = !mayQuit
      if !mayQuit {
        isTerminating = false
        monitor(
          snapshot?.inspection.readLocations.map(ReadDependency.subtree)
            ?? reader.stateDependencies(scope: scope),
          since: readBoundary)
      }
      terminationReply?(mayQuit)
    }
  }
}

extension AppModel {
  var sourceAccessSelection: SourceAccessSelection? {
    guard page == .sources, preferences.inspectorVisible, !isTerminating, !isApplying, !readsStale,
      let selectedItem, let snapshot, snapshot.scope == scope
    else { return nil }
    return SourceAccessSelection(
      snapshot: snapshot, node: selectedItem, presentation: sourceAccessPresentation)
  }

  var isSourceAccessValidationOutstanding: Bool {
    operations.values.contains {
      if case .sourceAccessValidation = $0.purpose { return true }
      return false
    }
  }

  func setInspectorVisible(_ visible: Bool) {
    if !visible { discardSourceAccess() }
    preferences.inspectorVisible = visible
  }

  func inspectSourceAccess(_ selection: SourceAccessSelection) {
    guard selection.id == sourceAccessSelection?.id,
      selection.id != sourceAccessSession?.selection
    else { return }
    sourceAccessSession = SourceAccessSession(selection: selection.id)
    let environment = actions.environment(for: selection.id.scope)
    startOperation(
      title: "Inspect source access", scope: selection.id.scope,
      purpose: .sourceAccessInspection(selection.id)
    ) {
      selection.inspect(environment: environment)
    }
  }

  func validateSourceAccess(_ selection: SourceAccessSelection) {
    guard selection.id == sourceAccessSelection?.id,
      let session = sourceAccessSession, selection.id == session.selection,
      let inspection = session.inspectionForValidation,
      !isSourceAccessValidationOutstanding
    else { return }
    let environment = actions.environment(for: selection.id.scope)
    let admission = OperationAdmission()
    sourceAccessSession?.validation = nil
    let operation = startOperation(
      title: "Validate source access", scope: selection.id.scope,
      purpose: .sourceAccessValidation(selection.id), admission: admission,
      executor: sourceAccessValidationExecutor
    ) {
      selection.validate(inspection: inspection, environment: environment, admission: admission)
    }
    sourceAccessSession?.validationOperation = operation
  }

  func cancelSourceAccessValidation(_ selection: SourceAccessSelection.ID) {
    guard let session = sourceAccessSession, session.selection == selection,
      let operation = session.validationOperation
    else { return }
    operations[operation]?.admission.cancel()
    sourceAccessSession?.validationOperation = nil
  }

  func discardSourceAccess() {
    sourceAccessPresentation = UUID()
    guard let session = sourceAccessSession else { return }
    for operation in operations.values {
      switch operation.purpose {
      case .sourceAccessInspection(let id), .sourceAccessValidation(let id):
        if id == session.selection { operation.admission.cancel() }
      default: break
      }
    }
    sourceAccessSession = nil
  }
}

extension AppModel {
  func reviewCreation() {
    guard !isTerminating, !isApplying, let session = creationSession, session.scope == scope,
      session.kind == .instructions || session.directorySelected
    else {
      return
    }
    creationSession?.stage = .describing
    creationSession?.description = nil
    let request = session.request
    let actions = actions
    startOperation(
      title: "Review starter content", scope: scope, purpose: .creationPreview(session.id)
    ) {
      actions.describeCreation(request)
    }
  }

  func redetectClients() {
    guard !isTerminating else { return }
    for operation in operations.values {
      if case .clients = operation.purpose { operation.admission.cancel() }
    }
    let id = clientSettings.begin()
    let actions = actions
    startOperation(
      title: "Detect agent clients", scope: .init(kind: .user, root: home), purpose: .clients(id)
    ) {
      actions.inspectClients(id: id)
    }
  }

  func cancelClientDetection() {
    for operation in operations.values {
      if case .clients = operation.purpose { operation.admission.cancel() }
    }
  }

  func markSubscriptionRead(_ status: WatchStatus) {
    guard canModify, let session = watchStatusSession, session.scope == scope,
      !session.stale, !session.busy, session.terminal == nil,
      session.statuses.contains(status)
    else { return }
    watchStatusSession?.busy = true
    let actions = actions
    startOperation(
      title: "Mark subscription as read", scope: session.scope, purpose: .watchSeen(session.id)
    ) {
      actions.acknowledgeWatch(status, scope: session.scope)
    }
  }

  func checkSubscriptions(source: String? = nil) {
    guard canModify else { return }
    let session = WatchStatusSession(scope: scope, source: source)
    watchStatusSession = session
    let actions = actions
    startOperation(title: "Check subscriptions", scope: scope, purpose: .watchStatus(session.id)) {
      actions.watchStatus(id: session.id, scope: session.scope, source: source)
    }
  }

  func beginWatch(source: String = "", removing: Bool = false) {
    guard canModify else { return }
    watchSession = .init(scope: scope, source: source, removing: removing)
  }

  func reviewWatch() {
    guard canModify, let session = watchSession, session.scope == scope, !session.busy else {
      return
    }
    watchSession?.busy = true
    watchSession?.preview = nil
    watchSession?.terminal = nil
    let actions = actions
    startOperation(title: "Review subscription", scope: scope, purpose: .watchPreview(session.id)) {
      actions.watchPreview(
        id: session.id, scope: session.scope, source: session.source, removing: session.removing)
    }
  }

  func confirmWatch() {
    guard canModify, let session = watchSession, !session.stale, !session.busy,
      session.scope == scope, let preview = session.preview
    else { return }
    watchSession?.busy = true
    let actions = actions
    startOperation(title: "Change subscription", scope: scope, purpose: .watchApply(session.id)) {
      actions.applyWatch(preview, scope: session.scope)
    }
  }

  func beginImport() {
    guard canModify else { return }
    importSession = .init(scope: scope)
  }

  func selectImportFile(_ url: URL, for original: ImportSession) {
    guard canSelectImportInput(for: original) else { return }
    importSession?.file = url
    importSession?.clearInspection()
  }

  func selectImportDirectory(_ url: URL, for original: ImportSession) {
    guard canSelectImportInput(for: original) else { return }
    importSession?.inputRoot = url
    importSession?.clearInspection()
  }

  private func canSelectImportInput(for original: ImportSession) -> Bool {
    guard canModify, let session = importSession else { return false }
    return session.id == original.id && session.scope == original.scope
      && session.scope == scope && !session.busy
  }

  func inspectImport() {
    guard canModify, let session = importSession, session.scope == scope, let file = session.file,
      !session.busy
    else { return }
    importSession?.busy = true
    importSession?.clearInspection()
    let actions = actions
    startOperation(title: "Inspect import", scope: scope, purpose: .sourceImport(session.id)) {
      actions.inspectImport(
        id: session.id, scope: session.scope, file: file, format: session.format,
        inputRoot: session.inputRoot)
    }
  }

  func reviewImport() {
    guard canModify, let session = importSession, session.scope == scope, !session.stale,
      !session.busy, !session.hasPendingResolution, !session.rawResourcesBlocked,
      let imported = session.inspection, let inspection = snapshot?.inspection
    else { return }
    importSession?.busy = true
    let actions = actions
    startOperation(title: "Review import", scope: scope, purpose: .importRequest(session.id)) {
      actions.importRequest(
        id: session.id, scope: session.scope, imported: imported, inspection: inspection)
    }
  }

  func beginConnection(_ component: ComponentInspection) {
    guard !isTerminating, !isApplying, component.kind == .mcpServer else { return }
    let session = ConnectionSession(
      scope: scope, name: component.name, selection: component.selection)
    connectionSession = session
    let actions = actions
    startOperation(
      title: "Prepare connection test", scope: scope, purpose: .connectionSnapshot(session.id)
    ) {
      actions.connectionSnapshot(id: session.id, scope: session.scope, selection: session.selection)
    }
  }

  func testConnection() {
    guard !isTerminating, let session = connectionSession, session.scope == scope, !session.busy,
      !session.stale, session.result == nil, session.bindingsReady, let snapshot = session.snapshot
    else { return }
    let id = UUID()
    operationSequence += 1
    let operation = ActiveOperation(
      id: id, scope: scope, selectionScope: scope, purpose: .connectionTest(session.id),
      generation: generation, sequence: operationSequence, title: "Test MCP connection",
      admission: OperationAdmission())
    operations[id] = operation
    connectionSession?.busy = true
    connectionSession?.testing = true
    let bindings = session.inputs.mapValues { Data($0.utf8) }
    connectionSession?.inputs = [:]
    let runtime = actions.environment(for: session.scope)
    let test = connectionTest
    let sessionID = session.id
    let operationScope = operation.scope
    asyncTasks[id] = Task.detached { [self] in
      let value = await test(snapshot, runtime, bindings)
      var messages: [AppDiagnostic] = []
      if let issue = value.issue, issue != .cancelled || !value.cleanupComplete {
        messages.append(
          .init(
            scope: operationScope, operation: "Test MCP connection",
            message: "Connection test: " + ConnectionLabels.issue(issue),
            blocksTermination: !value.cleanupComplete
          ))
      } else if !value.cleanupComplete {
        messages.append(
          .init(
            scope: operationScope, operation: "Test MCP connection",
            message: "Connection resources require cleanup.", blocksTermination: true))
      }
      await completeConnection(
        id,
        result: .init(
          disposition: value.issue == .cancelled
            ? .cancelled : (value.issue == nil ? .completed : .failed), diagnostics: messages,
          output: .connectionResult(sessionID, value)))
    }
  }

  private func completeConnection(_ id: UUID, result: CoreCompletion) {
    asyncTasks[id] = nil
    finish(id, result: result)
  }

  func cancelConnection() {
    for (id, task) in asyncTasks {
      if case .connectionTest = operations[id]?.purpose { task.cancel() }
    }
  }
}

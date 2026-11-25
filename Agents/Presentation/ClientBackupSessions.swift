import AgentsCore
import Foundation

struct ClientBackupOutcome: Identifiable, Sendable {
  let client: BackupClient
  let package: URL?
  var id: BackupClient { client }
}

struct ClientRestoreReview: Sendable {
  struct Row: Identifiable, Sendable {
    let id: Int
    let path: String
    let kind: ClientBackupChangeKind
  }

  let preview: ClientBackupPreview
  let rows: [Row]
  let hasReplacements: Bool

  init(preview: ClientBackupPreview) {
    self.preview = preview
    let rows = preview.files.enumerated().map { index, change in
      Row(id: index, path: change.path, kind: change.kind)
    }
    let replacements = rows.filter { $0.kind == .replace }
    self.rows = replacements + rows.filter { $0.kind != .replace }
    hasReplacements = !replacements.isEmpty
  }
}

struct ClientRestoreSession: Identifiable {
  enum Stage {
    case inspecting, mapping, previewing, restoring, restored, failed
    case review(ClientRestoreReview)
  }

  let id = UUID()
  let package: URL
  var client: BackupClient?
  var projects: [String] = []
  var destinations: [String: URL] = [:]
  var stage = Stage.inspecting
  var message: String?

  var isBusy: Bool {
    switch stage {
    case .inspecting, .previewing, .restoring: true
    default: false
    }
  }

  var hasAllDestinations: Bool { projects.allSatisfy { destinations[$0] != nil } }
}

extension AppModel {
  var canStartBackup: Bool {
    !isTerminating && !isApplying && !isBackingUp && restoreSession == nil
  }

  func backUpSelectedClients() {
    let clients = BackupClient.allCases.filter { backupClients.contains($0) }
    guard canStartBackup, !clients.isEmpty, let directory = backupDirectory else { return }
    let projects = preferences.projects.filter { backupProjects.contains($0) }
    let userScope = WorkspaceScope(kind: .user, root: home)
    let actions = actions
    backupOutcomes = []
    isBackingUp = true
    startOperation(title: "Back up clients", scope: userScope, purpose: .clientBackup) {
      actions.backUp(clients, projects: projects, to: directory, scope: userScope)
    }
  }

  func openBackupPackage(_ package: URL) {
    guard canStartBackup else { return }
    let session = ClientRestoreSession(package: package)
    restoreSession = session
    let userScope = WorkspaceScope(kind: .user, root: home)
    let actions = actions
    startOperation(
      title: "Inspect backup package", scope: userScope, purpose: .clientRestoreRead(session.id)
    ) {
      actions.inspectBackup(package, scope: userScope)
    }
  }

  func mapBackupProject(_ original: String, to destination: URL, sessionID: UUID) {
    guard let session = restoreSession, session.id == sessionID, case .mapping = session.stage,
      session.projects.contains(original), destination.isFileURL
    else { return }
    restoreSession?.destinations[original] = destination.standardizedFileURL
    restoreSession?.message = nil
  }

  func reviewBackupRestore() {
    guard !isTerminating, !isApplying, let session = restoreSession, case .mapping = session.stage,
      let client = session.client, session.hasAllDestinations
    else { return }
    restoreSession?.stage = .previewing
    restoreSession?.message = nil
    let userScope = WorkspaceScope(kind: .user, root: home)
    let actions = actions
    let (package, destinations) = (session.package, session.destinations)
    startOperation(
      title: "Preview backup restore", scope: userScope, purpose: .clientRestoreRead(session.id)
    ) {
      actions.previewBackup(package, client: client, destinations: destinations, scope: userScope)
    }
  }

  func editBackupDestinations() {
    guard let session = restoreSession, case .review = session.stage else { return }
    restoreSession?.stage = .mapping
  }

  func confirmBackupRestore() {
    guard !isTerminating, !isApplying, let session = restoreSession,
      case .review(let review) = session.stage
    else { return }
    restoreSession?.stage = .restoring
    let userScope = WorkspaceScope(kind: .user, root: home)
    let actions = actions
    let preview = review.preview
    startOperation(
      title: "Restore backup", scope: userScope, purpose: .clientRestoreWrite(session.id)
    ) {
      actions.restoreBackup(preview, scope: userScope)
    }
  }

  func finishClientRestore(id: UUID, result: CoreCompletion) {
    guard let session = restoreSession, session.id == id else { return }
    switch result.output {
    case .clientRestoreInspection(let client, let projects, let destinations):
      restoreSession?.client = client
      restoreSession?.projects = projects
      restoreSession?.destinations = destinations
      restoreSession?.stage = .mapping
    case .clientRestoreReview(let review):
      restoreSession?.stage = .review(review)
    default:
      switch session.stage {
      case .restoring where result.disposition == .completed:
        restoreSession?.stage = .restored
      case .previewing, .restoring:
        restoreSession?.stage = .mapping
      default:
        restoreSession?.stage = .failed
      }
      restoreSession?.message =
        result.disposition == .cancelled
        ? "The operation was cancelled." : result.diagnostics.first?.message
    }
  }
}

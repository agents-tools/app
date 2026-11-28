import AgentsCore
import AgentsUpdates
import Foundation

struct RegistrySession: Identifiable {
  let id = UUID()
  let scope: WorkspaceScope
  let inspection: ScopeInspection
}

extension AppModel {
  func browseRegistry() {
    guard canModify, let snapshot, snapshot.scope == scope else { return }
    registrySession = RegistrySession(scope: scope, inspection: snapshot.inspection)
  }

  func beginCatalog(alias: String = "", source: SourceDeclaration? = nil) {
    guard canModify else { return }
    catalogSession = .init(
      scope: scope, alias: alias, source: source ?? .init(kind: .local, location: ""))
  }

  func inspectCatalog() {
    guard canModify, let session = catalogSession, session.scope == scope, !session.busy else {
      return
    }
    catalogSession?.busy = true
    catalogSession?.clearInspection()
    let actions = actions
    startOperation(title: "Inspect source", scope: scope, purpose: .catalog(session.id)) {
      actions.inspectCatalog(session)
    }
  }

  func previewCatalogSelection() {
    guard canModify, let session = catalogSession, session.scope == scope,
      !session.busy, !session.stale, session.catalog != nil, !session.selected.isEmpty
    else { return }
    catalogSession?.busy = true
    let actions = actions
    startOperation(
      title: "Select source content", scope: scope, purpose: .catalogSelection(session.id)
    ) {
      actions.selectCatalog(session)
    }
  }

  func resolveImportSelection() {
    guard canModify, let session = importSession, session.scope == scope,
      !session.busy, !session.stale, session.inspection != nil, session.hasPendingResolution
    else { return }
    importSession?.busy = true
    let actions = actions
    startOperation(title: "Resolve import inputs", scope: scope, purpose: .sourceImport(session.id))
    {
      actions.resolveImport(session)
    }
  }
}

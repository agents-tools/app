import AgentsCore
import AgentsUpdates
import Foundation

extension CoreActions {
  func inspectCatalog(_ session: CatalogSession) -> CoreCompletion {
    do {
      try ProjectRootAccess.requireAvailable(session.scope)
      let value = try UpdateOperations.inspectSource(
        alias: session.alias, source: session.source,
        importing: session.importing
          ? .init(format: session.format, document: session.document) : nil,
        scope: session.scope.installScope, environment: environment(for: session.scope))
      return .init(disposition: .completed, output: .catalog(session.id, value))
    } catch { return failure(error, scope: session.scope, title: "Inspect source") }
  }

  func selectCatalog(_ session: CatalogSession) -> CoreCompletion {
    do {
      guard let catalog = session.catalog else {
        throw CoreError.invalidState("Inspect the source first.")
      }
      let choices = catalog.availableChoices.filter { session.selected.contains($0.id) }.map(\.id)
      guard choices.count == session.selected.count else {
        throw CoreError.invalidState("Source choices belong to another inspection. Inspect again.")
      }
      let discovery = try catalog.select(
        choices,
        options: session.selectionOptions, inputs: session.inputResolutions)
      return .init(
        disposition: .completed,
        output: .catalogRequest(session.id, discovery?.updateRequest()),
        readLocations: discovery?.readLocations ?? [])
    } catch { return failure(error, scope: session.scope, title: "Select source content") }
  }

  func resolveImport(_ session: ImportSession) -> CoreCompletion {
    do {
      guard let inspection = session.inspection else {
        throw CoreError.invalidState("Inspect the import first.")
      }
      let choices = session.selectedChoices.map(Array.init)
      let value = try inspection.resolving(choices: choices, inputs: session.inputResolutions)
      return .init(
        disposition: .completed, output: .sourceImport(session.id, value),
        readLocations: value.readLocations)
    } catch { return failure(error, scope: session.scope, title: "Resolve import inputs") }
  }
}

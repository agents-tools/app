import AgentsCore
import AgentsUpdates
import Foundation

struct WatchSession: Identifiable {
  let id = UUID()
  let scope: WorkspaceScope
  var source = ""
  var removing = false
  var preview: WatchMutationPreview?
  var busy = false
  var stale = false
  var terminal: UpdateTerminal?
  var messages: [AppDiagnostic] = []
}

struct ImportSession: Identifiable {
  let id = UUID()
  let scope: WorkspaceScope
  var file: URL?
  var format = ""
  var inspection: SourceImportInspection?
  var busy = false
  var stale = false
  var messages: [AppDiagnostic] = []
}

struct ConnectionSession: Identifiable {
  let id = UUID()
  let scope: WorkspaceScope
  let name: String
  let selection: ComponentSelection
  var snapshot: MCPConnectionSnapshot?
  var description: MCPConnectionDescription?
  var inputs: [String: String] = [:]
  var result: MCPConnectionTestResult?
  var busy = true
  var testing = false
  var stale = false
  var messages: [AppDiagnostic] = []
  var bindingsReady: Bool {
    description?.requiredBindings.allSatisfy { inputs[$0] != nil } == true
  }
}

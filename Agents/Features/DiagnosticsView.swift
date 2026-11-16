import SwiftUI

struct DiagnosticsView: View {
  let model: AppModel

  var body: some View {
    List {
      Section("Current Scope") {
        if model.currentDiagnostics.isEmpty {
          Label("No diagnostics reported in this session", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
        }
        ForEach(model.currentDiagnostics) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
      }
      let other = model.diagnostics.filter { $0.scope != model.scope }
      if !other.isEmpty {
        Section("Other Operations in This Session") {
          ForEach(other) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
        }
      }
      Section {
        Text(
          "Reports retain Core reads and operation outcomes in their original scope. Reading diagnostics does not change configuration."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .textSelection(.enabled)
  }
}

private struct DiagnosticRow: View {
  let diagnostic: AppDiagnostic

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        diagnostic.operation,
        systemImage: diagnostic.severity == .error
          ? "exclamationmark.triangle" : "info.circle"
      )
      .font(.headline)
      Text(diagnostic.message)
      Text(diagnostic.scope.title + " · " + diagnostic.scope.root.path)
        .font(.caption).foregroundStyle(.secondary)
      if let path = diagnostic.path { Text(path).font(.caption).foregroundStyle(.secondary) }
      if diagnostic.blocksTermination {
        Text("This operation reported a cleanup failure.").foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
  }
}

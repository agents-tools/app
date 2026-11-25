import AgentsCore
import AgentsUpdates
import SwiftUI
import UniformTypeIdentifiers

struct SourceStateView: View {
  let snapshot: WorkspaceSnapshot
  let model: AppModel
  @State private var inventory: InventoryFile?
  @State private var inventoryFilename = "inventory.cdx.json"
  @State private var exportingInventory = false
  @State private var exportError: String?
  @State private var editingPolicy = false

  var body: some View {
    Form {
      Section("Recorded Source State") {
        Button("Edit Source Policy…") { editingPolicy = true }.disabled(!model.canModify)
        Button("Review Declared Sources…") { model.discoverComponents() }
          .disabled(!model.canModify || snapshot.inspection.declaration == nil)
        Menu("Export Component Inventory…") {
          Button("CycloneDX 1.6 (JSON)…") { exportInventory(.cycloneDX) }
          Button("SPDX 2.3 (JSON)…") { exportInventory(.spdx) }
        }
        .disabled(snapshot.inspection.recovery.pending)
        Button("Import Configuration…") { model.beginImport() }
        Button("Subscribe to Source…") { model.beginWatch() }
        ForEach(snapshot.inspection.sources, id: \.record) { source in
          DetailsGroup(source.identity) {
            LabeledContent("Kind", value: DeclarationLabels.kind(source.kind.rawValue))
            LabeledContent("Revision") { CompactText(text: source.revision) }
            if let version = source.version { LabeledContent("Version", value: version) }
            if let location = source.location {
              LabeledContent("Location") { PathView(url: location, scope: snapshot.scope) }
            }
          }
        }
        if snapshot.inspection.sources.isEmpty {
          Text("No sources recorded in resolved state.").foregroundStyle(.secondary)
        }
      }
      Section("Subscription Baselines") {
        Button("Check Updates…") { model.checkSubscriptions() }
          .disabled(!model.canModify)
        if let watch = snapshot.watch {
          ForEach(watch.sources.keys.sorted(), id: \.self) { id in
            if let state = watch.sources[id] {
              DetailsGroup(id) {
                switch state.seen {
                case .revision(let revision): LabeledContent("Seen revision", value: revision)
                case .artifacts(let artifacts):
                  ForEach(artifacts.keys.sorted(), id: \.self) { name in
                    LabeledContent(name, value: artifacts[name] ?? "")
                  }
                }
              }
            }
          }
          ForEach(snapshot.inspection.declaration?.watch ?? [], id: \.self) { alias in
            Button("View Changes for “" + alias + "”…") { model.checkSubscriptions(source: alias) }
              .disabled(!model.canModify)
            Button("Unsubscribe “" + alias + "”…") {
              model.beginWatch(source: alias, removing: true)
            }
          }
          if watch.sources.isEmpty {
            Text("No subscription baselines recorded.").foregroundStyle(.secondary)
          }
        } else {
          Text("Subscription baselines are unavailable. See Diagnostics.").foregroundStyle(
            .secondary)
        }
        Text("Recorded baselines do not indicate whether a source has newer content.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $editingPolicy) {
      SourcePolicySheet(
        scope: snapshot.scope, environment: model.actions.environment(for: snapshot.scope)
      ) {
        model.refresh()
      }
    }
    .fileExporter(
      isPresented: $exportingInventory, document: inventory, contentType: .json,
      defaultFilename: inventoryFilename
    ) { result in
      if case .failure(let error) = result { exportError = error.localizedDescription }
    }
    .alert(
      "Couldn’t Export Inventory",
      isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    ) {
      Button("OK") { exportError = nil }
    } message: {
      Text(exportError ?? "")
    }
  }

  private func exportInventory(_ format: InventoryFormat) {
    do {
      inventory = try InventoryFile(data: snapshot.inspection.inventory(format: format))
      inventoryFilename = format == .spdx ? "inventory.spdx.json" : "inventory.cdx.json"
      exportingInventory = true
    } catch { exportError = error.localizedDescription }
  }
}

private struct InventoryFile: FileDocument {
  static let readableContentTypes: [UTType] = [.json]
  let data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let contents = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    data = contents
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

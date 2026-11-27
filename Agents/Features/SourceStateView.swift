import AgentsCore
import AgentsUpdates
import SwiftUI
import UniformTypeIdentifiers

struct SourceStateView: View {
  let snapshot: WorkspaceSnapshot
  let model: AppModel
  var body: some View {
    Form {
      Section("Resolved Versions") {
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
          Text("No source versions have been recorded yet.").foregroundStyle(.secondary)
        }
      }
      Section("Subscriptions") {
        Button("Subscribe to Source…") { model.beginWatch() }
        Button("Check Updates…") { model.checkSubscriptions() }
          .disabled(!model.canModify)
        if let watch = snapshot.watch {
          ForEach(watch.sources.keys.sorted(), id: \.self) { id in
            if let state = watch.sources[id] {
              DetailsGroup(id) {
                switch state.seen {
                case .revision(let revision): LabeledContent("Last seen revision", value: revision)
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
            Text("No subscription history yet.").foregroundStyle(.secondary)
          }
        } else {
          Text("Subscription history is unavailable. See Diagnostics.").foregroundStyle(
            .secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

struct SourceOptionsMenu: View {
  let model: AppModel
  let openAccess: () -> Void
  let openCache: () -> Void
  @State private var inventory: InventoryFile?
  @State private var inventoryFilename = "inventory.cdx.json"
  @State private var exportingInventory = false
  @State private var exportError: String?
  @State private var editingPolicy = false

  var body: some View {
    Menu("Source Options", systemImage: "slider.horizontal.3") {
      if let snapshot = model.snapshot {
        Button("Edit Source Policy…") { editingPolicy = true }.disabled(!model.canModify)
        Button("Review Declared Sources…") { model.discoverComponents() }
          .disabled(!model.canModify || snapshot.inspection.declaration == nil)
        Menu("Export Component Inventory…") {
          Button("CycloneDX 1.6 (JSON)…") { exportInventory(.cycloneDX, snapshot: snapshot) }
          Button("SPDX 2.3 (JSON)…") { exportInventory(.spdx, snapshot: snapshot) }
        }
        .disabled(snapshot.inspection.recovery.pending)
        Button("Import Configuration…") { model.beginImport() }
        Divider()
      }
      Button("User Source Access…", action: openAccess)
      Button("Source Cache…", action: openCache)
    }
    .accessibilityIdentifier("sources.options")
    .sheet(isPresented: $editingPolicy) {
      SourcePolicySheet(
        scope: model.scope, environment: model.actions.environment(for: model.scope)
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

  private func exportInventory(_ format: InventoryFormat, snapshot: WorkspaceSnapshot) {
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

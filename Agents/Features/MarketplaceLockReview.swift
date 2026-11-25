import AgentsCore
import AgentsUpdates
import SwiftUI

struct MarketplaceLockReview: View {
  let preview: MarketplaceLockPreview
  let saved: (MarketplaceLockReport) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var working = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Review Package Lock").font(.title2.bold())
      Text("Save these releases and client assignments for later deployment.")
        .foregroundStyle(.secondary)
      Form {
        if let change = preview.report.marketplaceGraphChange {
          MarketplaceGraphReview(change: change)
        } else {
          Section("Locked Releases") {
            ForEach(preview.resolution.nodes, id: \.versions.node) { node in
              LabeledContent(node.versions.node.package, value: node.versions.eligible.version)
            }
          }
        }
        if let findings = preview.report.organizationPolicy?.findings, !findings.isEmpty {
          Section("Organization Policy") {
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
              Text(finding.identity + " · " + finding.message)
            }
          }
        }
      }.formStyle(.grouped)
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if working { ProgressView().controlSize(.small) }
        Button("Save Lock") {
          working = true
          Task {
            defer { working = false }
            do {
              let result = try await Task.detached(priority: .userInitiated) { [preview] in
                try MarketplaceOperations.writeLockOnly(preview)
              }.value
              saved(result)
            } catch {
              self.error = String(describing: error)
            }
          }
        }
        .keyboardShortcut(.defaultAction).disabled(!preview.report.hasChanges)
      }
    }.padding(20).frame(minWidth: 500, minHeight: 380)
      .disabled(working).interactiveDismissDisabled(working)
  }
}

import AgentsCore
import AgentsUpdates
import SwiftUI

struct MarketplaceLockReview: View {
  let model: AppModel
  let scope: WorkspaceScope
  let review: LifecyclePackageReview<MarketplaceLockPreview, MarketplaceLockReport>
  let saved: (MarketplaceLockReport) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var working = false
  @State private var completion: CoreCompletion?

  private var preview: MarketplaceLockPreview { review.report }

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
        PackageActionPreview(inspection: review.lifecycle)
      }.formStyle(.grouped)
      if let completion {
        if let terminal = completion.updateTerminal {
          Text(terminal.message)
          PackageActionResults(results: terminal.packageActions)
        } else if completion.disposition == .cancelled {
          Text("Cancelled before the operation started.")
        }
        ForEach(completion.diagnostics.filter { $0.message != completion.updateTerminal?.message })
        {
          diagnostic in
          Text(verbatim: diagnostic.message)
            .foregroundStyle(diagnostic.severity == .error ? .red : .secondary)
            .textSelection(.enabled)
        }
      }
      HStack {
        Button(completion == nil ? "Cancel" : "Done") {
          if working {
            model.cancelQueuedOperations()
          } else {
            dismiss()
          }
        }.keyboardShortcut(.cancelAction)
        Spacer()
        if working { ProgressView().controlSize(.small) }
        if completion == nil {
          Button(preview.report.hasChanges ? "Save Lock" : "Run Package Actions") { save() }
            .keyboardShortcut(.defaultAction)
            .disabled(
              working || !model.canModify
                || (!preview.report.hasChanges && !review.lifecycle.hasRunnableActions))
        }
      }
    }.padding(20).frame(minWidth: 500, minHeight: 380)
      .interactiveDismissDisabled(working)
  }

  private func save() {
    working = model.startPackageActionEffect(title: "Save Package Lock", scope: scope, writes: true)
    {
      [review, scope] in
      await CoreActions.performPackage(
        review, scope: scope, title: "Save Package Lock",
        output: ContentOutput.packageLock)
    } receive: { result in
      working = false
      if case .packageLock(let report) = result.output {
        saved(report)
        if result.updateTerminal?.packageActions.isEmpty != false,
          result.updateTerminal?.recovery.pending != true
        {
          dismiss()
          return
        }
      }
      completion = result
    }
  }
}

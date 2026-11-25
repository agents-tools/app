import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct ProducerPatchSheet: View {
  let scope: InstallScope
  let environment: RuntimeEnvironment
  @Environment(\.dismiss) private var dismiss
  @State private var preview: ProducerPatchPreview?
  @State private var selection: String?
  @State private var report: ProducerPatchExport?
  @State private var busy = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Export Patches").font(.title2.bold())
      if let errorMessage {
        Label {
          Text(verbatim: errorMessage).textSelection(.enabled)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
      }
      if let report {
        Form {
          results("Exported", urls: report.written)
          results("Already Present", urls: report.reused)
          if !report.failures.isEmpty {
            Section("Couldn’t Export") {
              ForEach(report.failures, id: \.file) { failure in
                LabeledContent(
                  failure.file.lastPathComponent, value: title(failure.reason.rawValue)
                )
                .help(failure.file.path)
              }
            }
          }
        }.formStyle(.grouped)
      } else if let preview {
        if preview.patches.isEmpty && preview.skipped.isEmpty {
          ContentUnavailableView("No Edits to Export", systemImage: "doc.text")
        } else {
          HSplitView {
            List(selection: $selection) {
              ForEach(preview.patches, id: \.filename) { patch in
                VStack(alignment: .leading) {
                  Text(verbatim: patch.filename)
                  Text(verbatim: patch.producer.source).foregroundStyle(.secondary).font(.caption)
                }.tag(patch.filename)
              }
              if !preview.skipped.isEmpty {
                Section("Skipped") {
                  ForEach(Array(preview.skipped.enumerated()), id: \.offset) { _, skip in
                    VStack(alignment: .leading) {
                      Text(verbatim: skip.path.lastPathComponent).help(skip.path.path)
                      Text(verbatim: title(skip.reason.rawValue)).font(.caption).foregroundStyle(
                        .secondary)
                    }
                  }
                }
              }
            }.frame(minWidth: 170, idealWidth: 230)
            if let patch = preview.patches.first(where: { $0.filename == selection }) {
              ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 6) {
                  Text(verbatim: patch.producer.source).font(.headline)
                  Text(verbatim: baseLabel(patch.producer.base)).foregroundStyle(.secondary)
                  ForEach(patch.paths, id: \.self) { path in Text(verbatim: path).font(.caption) }
                  Divider()
                  Text(verbatim: patch.content).font(.system(.body, design: .monospaced))
                }.padding().textSelection(.enabled)
              }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
              ContentUnavailableView("No Patch Selected", systemImage: "doc.text")
            }
          }
        }
      } else {
        Spacer()
      }
      HStack {
        if busy { ProgressView().controlSize(.small) }
        Button("Refresh") { Task { await refresh() } }.disabled(busy)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
        if report == nil {
          Button("Export…") { selectFolder() }.keyboardShortcut(.defaultAction)
            .disabled(busy || preview?.patches.isEmpty != false)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 650, idealWidth: 760, minHeight: 400, idealHeight: 500)
    .interactiveDismissDisabled(busy)
    .task { await refresh() }
  }

  @ViewBuilder private func results(_ heading: String, urls: [URL]) -> some View {
    if !urls.isEmpty {
      Section(heading) {
        ForEach(urls, id: \.self) { url in Text(verbatim: url.path).textSelection(.enabled) }
      }
    }
  }

  private func baseLabel(_ base: ProducerPatchBase) -> String {
    switch base {
    case .git(let commit): return commit
    case .release(let version, let digest): return version + " · " + digest
    }
  }

  private func title(_ reason: String) -> String {
    let words = reason.replacingOccurrences(
      of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    return words.prefix(1).uppercased() + words.dropFirst().lowercased()
  }

  @MainActor private func refresh() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    errorMessage = nil
    preview = nil
    report = nil
    do {
      let value = try await Task.detached { [scope, environment] in
        try UpdateOperations.previewProducerPatches(scope: scope, environment: environment)
      }.value
      preview = value
      selection = value.patches.first?.filename
    } catch { errorMessage = error.localizedDescription }
  }

  @MainActor private func selectFolder() {
    guard !busy, let preview, !preview.patches.isEmpty else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Export"
    guard panel.runModal() == .OK, let directory = panel.url else { return }
    busy = true
    errorMessage = nil
    Task {
      defer { busy = false }
      do {
        report = try await Task.detached {
          try UpdateOperations.exportProducerPatches(preview, to: directory)
        }.value
      } catch {
        self.preview = nil
        errorMessage = error.localizedDescription
      }
    }
  }
}

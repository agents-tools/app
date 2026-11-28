import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct PromptAuditSheet: View {
  let scope: WorkspaceScope
  let environment: RuntimeEnvironment
  @Environment(\.dismiss) private var dismiss
  @State private var report: ContentAuditReport?
  @State private var selectedFile: URL?
  @State private var strip: ContentAuditStripPreview?
  @State private var activity: String?
  private var busy: Bool { activity != nil }
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Prompt Audit").font(.title2.bold())
      Text(scope.title).foregroundStyle(.secondary)
      HStack {
        Button("Scan Scope") { scan(file: nil) }
        Button("Choose File…") { chooseFile() }
        if let activity { ProgressView(activity).controlSize(.small) }
        Spacer()
        if let report {
          Menu("Export Report") {
            Button("Markdown…") { export(report, as: .markdown, filename: "prompt-audit.md") }
            Button("JSON…") { export(report, as: .json, filename: "prompt-audit.json") }
            Button("SARIF…") { export(report, as: .sarif, filename: "prompt-audit.sarif") }
          }
        }
      }.disabled(busy)
      if let strip {
        Text("Review deletions in " + strip.file.lastPathComponent).font(.headline)
        List(strip.edits.indices, id: \.self) { index in
          let edit = strip.edits[index]
          VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "U+%04X", edit.codePoint) + " · " + edit.reason.message)
            Text("Line \(edit.line), column \(edit.column)").font(.caption).foregroundStyle(
              .secondary)
          }
        }
        HStack {
          Button("Cancel Review") { self.strip = nil }
          Button("Apply Reviewed Changes") { apply(strip) }
        }.disabled(busy)
      } else if let report {
        Text(
          "Files scanned: \(report.targets.filter { $0.status == .scanned }.count) · Findings: \(report.findings.count)"
        )
        .font(.headline)
        if let file = selectedFile { Text(file.lastPathComponent).foregroundStyle(.secondary) }
        List(report.findings.indices, id: \.self) { index in
          let finding = report.findings[index]
          VStack(alignment: .leading, spacing: 3) {
            Text(finding.severity.rawValue.capitalized + " · " + finding.message)
            Text(location(finding.location)).font(.caption).foregroundStyle(.secondary)
          }
        }
        if let file = selectedFile,
          report.findings.contains(where: {
            $0.codePoint != nil && $0.severity != .info && $0.location.field == nil
          })
        {
          Button("Review Character Removal…") { review(file) }.disabled(busy)
        }
      } else {
        ContentUnavailableView(
          "Choose What to Audit", systemImage: "doc.text.magnifyingglass",
          description: Text("Scan the prompts in this scope or choose one of its files.")
        )
        .frame(maxHeight: .infinity)
      }
      if let message { Text(message).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
      }
    }
    .interactiveDismissDisabled(busy)
    .textSelection(.enabled)
    .padding(20)
    .frame(minWidth: 550, idealWidth: 640, minHeight: 360, idealHeight: 450)
  }

  private func location(_ item: ContentAuditLocation) -> String {
    var text = item.path
    if let line = item.line { text += ":\(line)" }
    if let column = item.column { text += ":\(column)" }
    if let field = item.field { text += " · " + field }
    return text
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.directoryURL = scope.root
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let file = panel.url else { return }
    scan(file: file)
  }

  private func scan(file: URL?) {
    selectedFile = file
    strip = nil
    report = nil
    work("Scanning prompt content…") {
      if let file {
        return ContentAuditOperations.scan(
          file: file, scope: scope.installScope, environment: environment)
      }
      return ContentAuditOperations.scan(scope: scope.installScope, environment: environment)
    } receive: {
      report = $0
    }
  }

  private func review(_ file: URL) {
    work("Reviewing file changes…") {
      try ContentAuditOperations.previewStrip(
        file: file, scope: scope.installScope, environment: environment)
    } receive: { preview in
      if preview.edits.isEmpty { message = "No characters to remove." } else { strip = preview }
    }
  }

  private func apply(_ preview: ContentAuditStripPreview) {
    work("Applying reviewed changes…") {
      try ContentAuditOperations.applyStrip(preview)
      return ContentAuditOperations.scan(
        file: preview.file, scope: scope.installScope, environment: environment)
    } receive: {
      strip = nil
      report = $0
      message = "Characters removed: \(preview.edits.count)"
    }
  }

  private func export(
    _ report: ContentAuditReport, as format: ContentAuditReportFormat, filename: String
  ) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = filename
    guard panel.runModal() == .OK, let file = panel.url else { return }
    work("Exporting the report…") {
      try report.export(format).write(to: file, options: .atomic)
    } receive: { _ in
      message = "Exported " + file.lastPathComponent
    }
  }

  private func work<T: Sendable>(
    _ label: String,
    _ operation: @escaping @Sendable () throws -> T, receive: @escaping (T) -> Void
  ) {
    guard !busy else { return }
    activity = label
    message = nil
    Task {
      defer { activity = nil }
      do {
        receive(try await Task.detached(priority: .userInitiated, operation: operation).value)
      } catch { message = String(describing: error) }
    }
  }
}

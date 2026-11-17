import AppKit
import SwiftUI

struct WatchView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.watchSession {
      VStack(alignment: .leading, spacing: 16) {
        Text(session.removing ? "Unsubscribe from Source" : "Subscribe to Source").font(.headline)
        PathView(url: session.scope.root, scope: session.scope)
        if session.preview == nil {
          TextField(
            "Source alias or location",
            text: Binding(
              get: { model.watchSession?.source ?? "" }, set: { model.watchSession?.source = $0 }))
          Button("Review Subscription…") { model.reviewWatch() }.disabled(
            session.busy || session.source.isEmpty || !model.canModify)
        }
        if let preview = session.preview {
          Form {
            LabeledContent("Source", value: preview.alias)
            LabeledContent("Identity") { CompactText(text: preview.sourceID) }
            Text(
              session.removing
                ? "Removes the subscription and its baseline. Source declarations and installed content remain."
                : "Records this source's current baseline without installing its content.")
            if let seen = preview.seen {
              switch seen {
              case .revision(let revision):
                LabeledContent("Baseline") { CompactText(text: revision) }
              case .artifacts(let values):
                ForEach(values.keys.sorted(), id: \.self) { name in
                  LabeledContent(name) { CompactText(text: values[name] ?? "") }
                }
              }
            }
          }.formStyle(.grouped)
          if session.stale { Text("Inputs changed. Review the subscription again.") }
          if session.terminal == nil {
            Button("Review Again…") { model.reviewWatch() }.disabled(
              session.busy || !model.canModify)
            Button(session.removing ? "Unsubscribe" : "Subscribe") { model.confirmWatch() }
              .disabled(
                session.busy || session.stale || session.scope != model.scope || !model.canModify)
          }
        }
        if session.busy { ProgressView("Waiting for the complete operation…") }
        if let terminal = session.terminal { Text(terminal.message) }
        ForEach(session.messages.filter { $0.message != session.terminal?.message }) {
          Text($0.message)
        }
        Spacer()
        Button(session.terminal == nil ? "Cancel" : "Done") {
          if session.busy { model.cancelQueuedOperations() } else { model.watchSession = nil }
        }.keyboardShortcut(.cancelAction)
      }.padding(24).frame(width: 580, height: 500).interactiveDismissDisabled(session.busy)
    }
  }
}

struct ImportView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.importSession {
      VStack(alignment: .leading, spacing: 16) {
        Text("Import Configuration").font(.headline)
        Form {
          Picker(
            "Input Format",
            selection: Binding(
              get: { model.importSession?.format ?? "" },
              set: {
                model.importSession?.format = $0
                model.importSession?.inspection = nil
              })
          ) {
            Text("Choose a format").tag("")
            ForEach(ImportFormatChoice.allCases) { format in Text(format.title).tag(format.rawValue)
            }
          }
          Button("Choose Input File…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if panel.runModal() == .OK {
              model.importSession?.file = panel.url
              model.importSession?.inspection = nil
            }
          }
          if let file = session.file { PathView(url: file) }
          Button("Inspect Import") { model.inspectImport() }.disabled(
            session.file == nil || session.format.isEmpty || session.busy || !model.canModify)
          if let value = session.inspection {
            LabeledContent("Format", value: value.format)
            Text(value.specificationStatus).foregroundStyle(.secondary)
            if let revision = value.producerRevision {
              LabeledContent("Producer revision") { CompactText(text: revision) }
            }
            ForEach(Array(value.sources.enumerated()), id: \.offset) { _, source in
              DetailsGroup(source.alias) {
                if let version = source.version { LabeledContent("Version", value: version) }
                if let commit = source.commit {
                  LabeledContent("Commit") { CompactText(text: commit) }
                }
                if let integrity = source.integrity {
                  LabeledContent("Claimed integrity") { CompactText(text: integrity) }
                }
                if let url = source.resolvedURL {
                  LabeledContent("Resolved source") { CompactText(text: url) }
                }
              }
            }
            ForEach(Array(value.components.enumerated()), id: \.offset) { _, component in
              Text(ComponentDraft(component.declaration).name)
            }
            ForEach(Array(value.resources.enumerated()), id: \.offset) { _, resource in
              DetailsGroup(resource.producerName) {
                if let hash = resource.hash {
                  LabeledContent("Captured content") { CompactText(text: hash) }
                }
                if let integrity = resource.integrity {
                  LabeledContent("Producer claim") { CompactText(text: integrity) }
                }
                Text(
                  resource.requiresStandaloneSource
                    ? "Requires a standalone source." : "Uses the captured source.")
              }
            }
            ForEach(Array(value.diagnostics.enumerated()), id: \.offset) { _, issue in
              Text(issue.message)
            }
            ForEach(Array(value.bindings.enumerated()), id: \.offset) { _, binding in
              Text(binding.reason)
            }
            if !value.deployments.isEmpty {
              Text("Existing deployment claims do not grant ownership of installed files.")
            }
            if session.stale { Text("Import inputs changed. Inspect again.") }
            Button("Review Changes…") { model.reviewImport() }.disabled(
              session.stale || session.busy || !model.canModify)
          }
        }.formStyle(.grouped).disabled(session.busy)
        if session.busy { ProgressView("Inspecting captured input…") }
        ForEach(session.messages) { Text($0.message) }
        Button("Cancel") {
          if session.busy { model.cancelQueuedOperations() } else { model.importSession = nil }
        }.keyboardShortcut(.cancelAction)
      }.padding(24).frame(width: 640, height: 620).interactiveDismissDisabled(session.busy)
    }
  }
}

struct ConnectionView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.connectionSession {
      VStack(alignment: .leading, spacing: 16) {
        Text("Test “" + session.name + "”").font(.headline)
        PathView(url: session.scope.root, scope: session.scope)
        if let description = session.description {
          LabeledContent("Transport", value: description.transport.rawValue)
          Text(
            description.startsOwnedProcess
              ? "Test starts an owned process and waits for its cleanup."
              : "Test connects to the configured server. It does not apply configuration.")
          ForEach(description.environmentBindings, id: \.self) {
            Text("Uses environment input “" + $0 + "”.")
          }
          ForEach(description.requiredBindings, id: \.self) { name in
            Toggle(
              "Supply “" + name + "”",
              isOn: Binding(
                get: { model.connectionSession?.inputs[name] != nil },
                set: { model.connectionSession?.inputs[name] = $0 ? "" : nil }))
            if session.inputs[name] != nil {
              SecureField(
                name,
                text: Binding(
                  get: { model.connectionSession?.inputs[name] ?? "" },
                  set: { model.connectionSession?.inputs[name] = $0 }))
            }
          }
          if session.stale {
            Text("Selection or inputs changed. Close and prepare this connection again.")
          }
          if session.result == nil && !session.busy {
            Button("Test Connection") { model.testConnection() }.disabled(
              !session.bindingsReady || session.stale || session.scope != model.scope)
          }
        }
        if session.busy {
          ProgressView(
            session.testing
              ? "Testing and releasing owned resources…" : "Preparing exact managed selection…")
        }
        if let result = session.result {
          LabeledContent(
            "Result", value: result.issue == .cancelled ? "Cancelled" : result.outcome.rawValue)
          LabeledContent("Cleanup", value: result.cleanupComplete ? "Complete" : "Needs attention")
          if let version = result.negotiatedVersion { LabeledContent("Protocol", value: version) }
          List(result.tools, id: \.name) { tool in
            VStack(alignment: .leading) {
              Text(tool.title ?? tool.name)
              if let text = tool.description { Text(text).foregroundStyle(.secondary) }
            }
          }
        }
        ForEach(session.messages) { Text($0.message) }
        Spacer()
        Button(session.busy ? "Cancel" : "Done") {
          if session.busy {
            model.cancelConnection()
            model.cancelQueuedOperations()
          } else {
            model.connectionSession = nil
          }
        }.keyboardShortcut(.cancelAction)
      }.padding(24).frame(width: 600, height: 540).interactiveDismissDisabled(session.busy)
    }
  }
}

private enum ImportFormatChoice: String, CaseIterable, Identifiable {
  case apmManifest, apmLock, rulesyncConfig, rulesyncSourcesV1, rulesyncNpmV1, rulesyncGitHubV1,
    rulesyncAPMV1
  case vercelProjectV2, vercelUserV3, claudeSettingsV1, codexConfigV1, cursorMCPV1,
    geminiSettingsV1, openCodeConfigV2
  case claudePluginV1, cursorPluginV1, geminiExtensionV1, claudeMarketplaceV1
  case claudeCommandV1, claudeAgentV1, geminiCommandV1, geminiAgentV1, openCodeCommandV2,
    openCodeAgentV2, cursorCommandV1, cursorAgentV1, geminiIgnoreV1, cursorIgnoreV1
  var id: String { rawValue }
  var title: String {
    switch self {
    case .apmManifest: "APM Manifest"
    case .apmLock: "APM Lock"
    case .rulesyncConfig: "Rulesync Configuration"
    case .rulesyncSourcesV1: "Rulesync Sources"
    case .rulesyncNpmV1: "Rulesync npm"
    case .rulesyncGitHubV1: "Rulesync GitHub"
    case .rulesyncAPMV1: "Rulesync APM"
    case .vercelProjectV2: "Vercel Project"
    case .vercelUserV3: "Vercel User"
    case .claudeSettingsV1: "Claude Settings"
    case .codexConfigV1: "Codex Configuration"
    case .cursorMCPV1: "Cursor MCP"
    case .geminiSettingsV1: "Gemini Settings"
    case .openCodeConfigV2: "OpenCode Configuration"
    case .claudePluginV1: "Claude Plugin"
    case .cursorPluginV1: "Cursor Plugin"
    case .geminiExtensionV1: "Gemini Extension"
    case .claudeMarketplaceV1: "Claude Marketplace"
    case .claudeCommandV1: "Claude Command"
    case .claudeAgentV1: "Claude Agent"
    case .geminiCommandV1: "Gemini Command"
    case .geminiAgentV1: "Gemini Agent"
    case .openCodeCommandV2: "OpenCode Command"
    case .openCodeAgentV2: "OpenCode Agent"
    case .cursorCommandV1: "Cursor Command"
    case .cursorAgentV1: "Cursor Agent"
    case .geminiIgnoreV1: "Gemini Ignore"
    case .cursorIgnoreV1: "Cursor Ignore"
    }
  }
}

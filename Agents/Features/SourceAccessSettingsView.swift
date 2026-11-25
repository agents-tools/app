import AgentsCore
import SwiftUI

struct SourceAccessSettingsView: View {
  let model: AppModel
  @State private var confirmingReload = false

  private var settings: SourceAccessSettingsModel { model.sourceAccessSettings }
  private var canAct: Bool { !settings.isBusy && !model.isApplying && !model.isTerminating }

  var body: some View {
    Form {
      Section("Operator Profile") {
        if let location = settings.location {
          LabeledContent("Location") { profileValue(location.path) }
        }
        if let document = settings.document {
          if let issue = document.issue {
            Label(issue.message, systemImage: "exclamationmark.circle")
              .foregroundStyle(.secondary)
          } else {
            if !document.isPresent {
              Text("No profile is saved. The editor shows a starting example.")
                .foregroundStyle(.secondary)
            }
            SourceAccessProfileRows(profile: document.profile)
          }
        }
        Button("Reload from Disk") {
          if settings.hasDraftChanges {
            confirmingReload = true
          } else {
            model.reloadSourceAccessSettings()
          }
        }
        .disabled(!canAct)
      }

      if settings.document != nil {
        Section("Profile YAML") {
          TextEditor(text: Binding(get: { settings.draft }, set: settings.setDraft))
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .frame(minHeight: 150)
            .accessibilityLabel("Source access profile YAML")
            .disabled(!canAct)
          HStack {
            Button("Validate and Preview…") { model.previewSourceAccessSettings() }
              .disabled(!canAct || !settings.canPreview)
            Spacer()
            if settings.document?.isPresent == true {
              Button("Reset Profile…") { model.previewSourceAccessSettings(reset: true) }
                .disabled(!canAct || !settings.canReset)
            }
          }
        }
      }

      if settings.isBusy {
        ProgressView().controlSize(.small).accessibilityLabel("Working on source access settings")
      }
      if let issue = settings.issue {
        Label(issue.message, systemImage: "exclamationmark.circle")
          .foregroundStyle(.red)
      }
      if let message = settings.message {
        Text(message).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      if !settings.hasDraftChanges, settings.review == nil {
        model.reloadSourceAccessSettings()
      }
    }
    .alert("Discard YAML Edits?", isPresented: $confirmingReload) {
      Button("Cancel", role: .cancel) {}
      Button("Discard and Reload", role: .destructive) { model.reloadSourceAccessSettings() }
    } message: {
      Text("Reload replaces the draft with the latest saved profile.")
    }
    .sheet(
      item: Binding(
        get: { settings.review },
        set: { if $0 == nil { settings.dismissReview() } })
    ) { review in
      SourceAccessSettingsPreviewView(
        preview: review.preview, canSave: canAct, onCancel: settings.dismissReview,
        onSave: { model.saveSourceAccessSettings(reviewID: review.id) })
    }
  }
}

private struct SourceAccessSettingsPreviewView: View {
  let preview: SourceAccessSettingsPreview
  let canSave: Bool
  let onCancel: () -> Void
  let onSave: () -> Void

  private var isReset: Bool { preview.profile == nil }

  var body: some View {
    VStack(spacing: 12) {
      Form {
        Section(isReset ? "Reset Source Access?" : "Review Source Access") {
          LabeledContent("Location") { profileValue(preview.url.path) }
          if isReset {
            Text("Reset removes the saved profile and discards the draft.")
              .foregroundStyle(.secondary)
          }
          SourceAccessProfileRows(profile: preview.profile)
        }
      }
      .formStyle(.grouped)
      HStack {
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Spacer()
        Button(isReset ? "Reset Profile" : "Save Profile", role: isReset ? .destructive : nil) {
          onSave()
        }
        .disabled(!canSave)
      }
      .padding([.horizontal, .bottom], 20)
    }
    .frame(width: 490, height: 340)
  }
}

private struct SourceAccessProfileRows: View {
  let profile: SourceAccessProfile?

  var body: some View {
    LabeledContent(
      "Network Access", value: profile?.egress == .proxyOnly ? "Proxy Only" : "Direct Allowed")
    if let profile {
      if !profile.providers.isEmpty {
        DisclosureGroup("Provider Registrations") {
          ForEach(profile.providers, id: \.authority) { provider in
            LabeledContent(authority(provider.authority), value: providerName(provider.provider))
          }
        }
      }
      if !profile.mirrors.isEmpty {
        DisclosureGroup("Archive Mirrors") {
          ForEach(profile.mirrors, id: \.source) { mirror in
            DisclosureGroup(authority(mirror.source)) {
              LabeledContent("Mirror") { profileValue(mirror.base.absoluteString) }
              LabeledContent("Type", value: mirrorName(mirror.flavor))
              if mirror.supportsQualifiedGitLabRefs {
                LabeledContent("Qualified GitLab Refs", value: "Enabled")
              }
              if mirror.requiresExactArchiveBytes {
                LabeledContent("Replay Verification", value: "Exact Archive Bytes")
              }
            }
          }
        }
      }
      if !profile.credentials.isEmpty {
        DisclosureGroup("Credential References") {
          ForEach(Array(profile.credentials.enumerated()), id: \.offset) { _, credential in
            DisclosureGroup(credential.environmentVariable) {
              LabeledContent("Route", value: credential.route == .direct ? "Direct" : "Mirror")
              LabeledContent("Authority", value: authority(credential.authority))
              LabeledContent("Path Scope") { profileValue(credential.path ?? "Whole Authority") }
              if let endpoint = credential.validationEndpoint {
                LabeledContent("Validation Endpoint") { profileValue(endpoint.absoluteString) }
              }
              if credential.exportable {
                LabeledContent("Pipe Export", value: "Enabled")
              }
            }
          }
        }
      }
    }
  }

  private func authority(_ value: SourceAuthority) -> String {
    value.port == 443 ? value.host : "\(value.host):\(value.port)"
  }

  private func providerName(_ value: SourceProvider) -> String {
    switch value {
    case .github: "GitHub"
    case .gitlab: "GitLab"
    }
  }

  private func mirrorName(_ value: SourceArchiveMirror.Flavor) -> String {
    switch value {
    case .github: "GitHub"
    case .gitlab: "GitLab"
    case .artifactory: "Artifactory"
    }
  }
}

private func profileValue(_ value: String) -> some View {
  Text(value)
    .multilineTextAlignment(.trailing)
    .textSelection(.enabled)
}

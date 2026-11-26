import AgentsCore
import SwiftUI

struct SourceAccessProfileFields: View {
  @Binding var draft: SourceAccessProfileDraft
  @State private var expanded: Set<UUID> = []

  var body: some View {
    Section("Network Access") {
      Picker("Egress Policy", selection: $draft.egress) {
        Text("Direct Allowed").tag(SourceAccessProfile.Egress.directAllowed)
        Text("Proxy Only").tag(SourceAccessProfile.Egress.proxyOnly)
      }
    }

    Section("Provider Registrations") {
      ForEach($draft.providers) { $provider in
        DisclosureGroup(isExpanded: expansion(for: provider.id)) {
          authorityFields($provider.authority)
          Picker("Provider", selection: $provider.provider) {
            Text("GitHub").tag(SourceProvider.github)
            Text("GitLab").tag(SourceProvider.gitlab)
          }
          Button("Remove Provider", role: .destructive) {
            remove(provider.id, from: $draft.providers)
          }
        } label: {
          Text(provider.authority.host.isEmpty ? "New Provider" : provider.authority.host)
        }
      }
      Button("Add Provider", systemImage: "plus") {
        add(.init(), to: $draft.providers)
      }
    }

    Section("Archive Mirrors") {
      ForEach($draft.mirrors) { $mirror in
        DisclosureGroup(isExpanded: expansion(for: mirror.id)) {
          authorityFields($mirror.source, hostLabel: "Source Host", portLabel: "Source Port")
          TextField("Mirror Base URL", text: $mirror.base, prompt: Text("https://"))
          Picker("Flavor", selection: $mirror.flavor) {
            Text("GitHub").tag(SourceArchiveMirror.Flavor.github)
            Text("GitLab").tag(SourceArchiveMirror.Flavor.gitlab)
          }
          optionalFlag("Qualified GitLab Refs", selection: $mirror.supportsQualifiedGitLabRefs)
          optionalFlag("Exact Archive Bytes", selection: $mirror.requiresExactArchiveBytes)
          Button("Remove Mirror", role: .destructive) { remove(mirror.id, from: $draft.mirrors) }
        } label: {
          Text(mirror.source.host.isEmpty ? "New Mirror" : mirror.source.host)
        }
      }
      Button("Add Mirror", systemImage: "plus") {
        add(.init(), to: $draft.mirrors)
      }
    }

    Section("Credential References") {
      ForEach($draft.credentials) { $credential in
        DisclosureGroup(isExpanded: expansion(for: credential.id)) {
          Picker("Route", selection: $credential.route) {
            Text("Direct").tag(SourceAccessProfile.Credential.Route.direct)
            Text("Mirror").tag(SourceAccessProfile.Credential.Route.mirror)
          }
          authorityFields($credential.authority)
          TextField("Path Scope", text: $credential.path, prompt: Text("Whole authority"))
          TextField(
            "Environment Variable Name", text: $credential.environmentVariable,
            prompt: Text("PACKAGE_TOKEN"))
          TextField(
            "Validation Endpoint", text: $credential.validationEndpoint, prompt: Text("Optional"))
          optionalFlag("Pipe Export", selection: $credential.exportable)
          Button("Remove Credential Reference", role: .destructive) {
            remove(credential.id, from: $draft.credentials)
          }
        } label: {
          Text(
            credential.environmentVariable.isEmpty
              ? "New Credential" : credential.environmentVariable)
        }
      }
      Button("Add Credential Reference", systemImage: "plus") {
        add(.init(), to: $draft.credentials)
      }
    }
  }

  @ViewBuilder private func authorityFields(
    _ authority: Binding<SourceAccessProfileDraft.Authority>,
    hostLabel: LocalizedStringKey = "Host",
    portLabel: LocalizedStringKey = "Port"
  ) -> some View {
    TextField(hostLabel, text: authority.host)
    TextField(portLabel, text: authority.port, prompt: Text("443 (default)"))
  }

  private func optionalFlag(_ label: LocalizedStringKey, selection: Binding<Bool?>) -> some View {
    Picker(label, selection: selection) {
      Text("Default (Off)").tag(nil as Bool?)
      Text("Off").tag(false as Bool?)
      Text("On").tag(true as Bool?)
    }
  }

  private func expansion(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { expanded.contains(id) },
      set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
  }

  private func add<Row: Identifiable>(_ row: Row, to rows: Binding<[Row]>) where Row.ID == UUID {
    rows.wrappedValue.append(row)
    expanded.insert(row.id)
  }

  private func remove<Row: Identifiable>(_ id: UUID, from rows: Binding<[Row]>)
  where Row.ID == UUID {
    rows.wrappedValue.removeAll { $0.id == id }
    expanded.remove(id)
  }
}

import AgentsCore
import AgentsUpdates
import SwiftUI

struct RegistryBrowserSheet: View {
  let inspection: ScopeInspection
  let review: (ComponentDiscovery) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var custom = false
  @State private var endpoint = ""
  @State private var token = ""
  @State private var query = ""
  @State private var page: [MCPRegistryServer] = []
  @State private var cursor: String?
  @State private var selected: String?
  @State private var didSearch = false
  @State private var busy = false
  @State private var message: String?
  @State private var generation = UUID()
  @State private var request: Task<Void, Never>?

  private var server: MCPRegistryServer? { page.first { $0.name == selected } }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Find MCP Server").font(.headline)
          Spacer()
          Picker("Registry", selection: $custom) {
            Text("Public").tag(false)
            Text("Custom").tag(true)
          }.pickerStyle(.segmented).frame(width: 175).labelsHidden()
        }
        if custom {
          TextField("Registry URL", text: $endpoint)
          SecureField("Bearer token (optional)", text: $token)
        }
        HStack {
          TextField("Search MCP servers", text: $query)
            .onSubmit { search() }
          Button("Search") { search() }.disabled(busy || (custom && endpoint.isEmpty))
        }
      }.padding()
      Divider()
      HSplitView {
        VStack(spacing: 0) {
          if !page.isEmpty {
            List(selection: $selected) {
              ForEach(page, id: \.name) { server in
                VStack(alignment: .leading) {
                  Text(server.title ?? server.name)
                  Text(server.name).font(.caption).foregroundStyle(.secondary)
                }.tag(server.name)
              }
            }
          } else if busy {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ContentUnavailableView(
              didSearch ? "No Matching Servers" : "Search the Registry",
              systemImage: "magnifyingglass")
          }
          if let cursor {
            Button("Load More") { search(after: cursor) }.disabled(busy).padding(8)
          }
        }.frame(minWidth: 220, idealWidth: 260)
        if let server {
          RegistryServerDetail(inspection: inspection, server: server, review: review)
            .id(server.name + "@" + server.version)
        } else {
          ContentUnavailableView("Select a Server", systemImage: "server.rack")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      if let message {
        Text(message).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal)
      }
      Divider()
      HStack {
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
      }.padding()
    }
    .frame(minWidth: 730, idealWidth: 830, minHeight: 510, idealHeight: 615)
    .task { search() }
    .onChange(of: custom) {
      token = ""
      resetSearch()
    }
    .onChange(of: endpoint) {
      token = ""
      resetSearch()
    }
    .onChange(of: token) { resetSearch() }
    .onChange(of: query) { resetSearch() }
    .onDisappear {
      request?.cancel()
      token = ""
    }
  }

  private func resetSearch() {
    generation = UUID()
    request?.cancel()
    page = []
    selected = nil
    cursor = nil
    message = nil
    didSearch = false
    busy = false
  }

  private func search(after next: String? = nil) {
    if next == nil { resetSearch() }
    let id = generation
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let credentials = custom && !token.isEmpty ? ["Authorization": "Bearer " + token] : [:]
    let registry: MCPRegistry
    do {
      if custom {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        registry = try MCPRegistry(endpoint: url)
      } else {
        registry = .official
      }
    } catch {
      message = error.localizedDescription
      return
    }
    busy = true
    message = nil
    request = Task { @MainActor in
      defer { if generation == id { busy = false } }
      do {
        let result = try await registry.search(
          text.isEmpty ? nil : text, version: "latest", limit: 30, cursor: next,
          credentials: credentials)
        guard generation == id, !Task.isCancelled else { return }
        var seen = Set(page.map(\.name))
        page += result.servers.filter { seen.insert($0.name).inserted }
        cursor = result.nextCursor
        didSearch = true
      } catch {
        guard generation == id, !Task.isCancelled else { return }
        message = error.localizedDescription
      }
    }
  }
}

private struct RegistryServerDetail: View {
  let inspection: ScopeInspection
  let server: MCPRegistryServer
  let review: (ComponentDiscovery) -> Void
  @State private var index = 0
  @State private var name = ""
  @State private var bindings: [String: String] = [:]
  @State private var command = ""
  @State private var targets: Set<AgentID> = []
  @State private var issue: String?

  var body: some View {
    Form {
      Section(server.title ?? server.name) {
        LabeledContent("Version", value: server.version)
        Text(server.description).textSelection(.enabled)
      }
      if server.choices.indices.contains(index) {
        let choice = server.choices[index]
        Section("Installation") {
          Picker("Connection", selection: $index) {
            ForEach(server.choices.indices, id: \.self) { position in
              Text(label(server.choices[position])).tag(position)
            }
          }
          TextField("Managed name", text: $name)
          if choice.requiresPackageCommand { TextField("Console command", text: $command) }
          if let reason = choice.unavailableReason { Text(reason).foregroundStyle(.secondary) }
        }
        if !choice.bindings.isEmpty {
          Section("Server Inputs") {
            ForEach(choice.bindings, id: \.name) { requirement in
              inputField(requirement)
            }
          }
        }
        if choice.unavailableReason == nil {
          let mappings = inputValues(for: choice)
          let executable = choice.requiresPackageCommand && !command.isEmpty ? command : nil
          let compatibility = Result {
            try choice.compatibleAgents(
              in: inspection.scope, bindings: mappings, packageCommand: executable)
          }
          Section("Clients") {
            switch compatibility {
            case .success(let agents):
              ForEach(agents, id: \.self) { agent in
                Toggle(
                  agent.displayName,
                  isOn: Binding(
                    get: { targets.contains(agent) },
                    set: { enabled in
                      if enabled { targets.insert(agent) } else { targets.remove(agent) }
                    }))
              }
              if agents.isEmpty {
                Text("No compatible clients in this scope.").foregroundStyle(.secondary)
              }
              Button("Review Installation…") {
                do {
                  review(
                    try choice.select(
                      named: name, agents: agents.filter(targets.contains),
                      in: inspection, bindings: mappings, packageCommand: executable))
                } catch {
                  issue = error.localizedDescription
                }
              }.disabled(name.isEmpty || targets.isDisjoint(with: agents))
            case .failure(let error):
              Text(error.localizedDescription).foregroundStyle(.secondary)
            }
          }
        }
      } else {
        Text("This server has no installation choices.").foregroundStyle(.secondary)
      }
      if let issue { Text(issue).foregroundStyle(.red) }
    }.formStyle(.grouped)
      .onAppear { name = server.name.split(separator: "/").last.map(String.init) ?? server.name }
      .onChange(of: index) {
        command = ""
        bindings = [:]
        targets = []
        issue = nil
      }
  }

  @ViewBuilder
  private func inputField(_ input: MCPRegistryBindingRequirement) -> some View {
    let title = input.isRequired ? input.name + " (required)" : input.name
    let value = Binding<String>(
      get: { bindings[input.name] ?? "" }, set: { bindings[input.name] = $0 })
    if input.choices.isEmpty {
      TextField(title, text: value, prompt: Text("Environment variable name"))
        .help(input.description ?? "Environment variable name")
    } else {
      Picker(title, selection: value) {
        Text("Select a value").tag("")
        ForEach(input.choices, id: \.self) { Text($0).tag($0) }
      }
    }
  }

  private func inputValues(for choice: MCPRegistryChoice) -> [String: MCPRegistryBinding] {
    var result: [String: MCPRegistryBinding] = [:]
    for input in choice.bindings {
      guard let value = bindings[input.name], !value.isEmpty else { continue }
      result[input.name] = input.choices.isEmpty ? .environment(value) : .choice(value)
    }
    return result
  }

  private func label(_ choice: MCPRegistryChoice) -> String {
    switch choice.source {
    case .remote(let endpoint):
      return choice.transport + " · " + (endpoint?.absoluteString ?? "Remote")
    case .package(let package): return package.registryType + " · " + package.identifier
    }
  }
}

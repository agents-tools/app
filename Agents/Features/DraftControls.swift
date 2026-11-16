import AgentsCore
import SwiftUI

struct LinesEditor: View {
  let title: String
  @Binding var values: [String]
  var body: some View {
    TextField(
      title + " (one per line)",
      text: Binding(
        get: { values.joined(separator: "\n") },
        set: { values = $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }),
      axis: .vertical
    )
    .lineLimit(2...6)
  }
}

struct OptionalText: View {
  let title: String
  @Binding var value: String?
  var body: some View {
    Toggle("Specify " + title, isOn: Binding(get: { value != nil }, set: { value = $0 ? "" : nil }))
    if value != nil {
      TextField(title, text: Binding(get: { value ?? "" }, set: { value = $0 }))
    }
  }
}

struct OptionalLines: View {
  let title: String
  @Binding var values: [String]?
  var body: some View {
    Toggle(
      "Specify " + title, isOn: Binding(get: { values != nil }, set: { values = $0 ? [] : nil }))
    if values != nil {
      LinesEditor(title: title, values: Binding(get: { values ?? [] }, set: { values = $0 }))
    }
  }
}

struct AgentsEditor: View {
  @Binding var value: [AgentID]?
  var body: some View {
    Toggle("Specify agents", isOn: Binding(get: { value != nil }, set: { value = $0 ? [] : nil }))
    if value != nil {
      ForEach(AgentID.allCases, id: \.self) { agent in
        Toggle(
          agent.displayName,
          isOn: Binding(
            get: { value?.contains(agent) ?? false },
            set: { selected in
              if selected { value?.append(agent) } else { value?.removeAll { $0 == agent } }
            }))
      }
      Text("An empty selection explicitly selects no agents.").font(.caption).foregroundStyle(
        .secondary)
    }
  }
}

struct ConditionEditor: View {
  @Binding var value: DeclarationCondition?
  var body: some View {
    Toggle(
      "Specify conditions",
      isOn: Binding(get: { value != nil }, set: { value = $0 ? .init() : nil }))
    if value != nil {
      DisclosureGroup("Conditions") {
        AgentsEditor(value: Binding(get: { value?.agents }, set: { value?.agents = $0 }))
        Toggle(
          "Restrict scopes",
          isOn: Binding(get: { value?.scopes != nil }, set: { value?.scopes = $0 ? [] : nil }))
        if value?.scopes != nil {
          ForEach([InstallScope.user, .project], id: \.self) { scope in
            Toggle(
              scope == .user ? "User" : "Project",
              isOn: Binding(
                get: { value?.scopes?.contains(scope) ?? false },
                set: {
                  if $0 {
                    value?.scopes?.append(scope)
                  } else {
                    value?.scopes?.removeAll { $0 == scope }
                  }
                }))
          }
        }
        Toggle(
          "Restrict platforms",
          isOn: Binding(get: { value?.platforms != nil }, set: { value?.platforms = $0 ? [] : nil })
        )
        if value?.platforms != nil {
          ForEach([DeclarationPlatform.macOS, .linux], id: \.self) { platform in
            Toggle(
              platform.rawValue,
              isOn: Binding(
                get: { value?.platforms?.contains(platform) ?? false },
                set: {
                  if $0 {
                    value?.platforms?.append(platform)
                  } else {
                    value?.platforms?.removeAll { $0 == platform }
                  }
                }))
          }
        }
      }
    }
  }
}

struct RequirementEditor: View {
  @Binding var value: SourceRequirement?
  var body: some View {
    Toggle(
      "Specify Git requirement",
      isOn: Binding(get: { value != nil }, set: { value = $0 ? .branch("") : nil }))
    if value != nil {
      Picker("Requirement", selection: Binding(get: { kind }, set: { update(kind: $0) })) {
        Text("Branch").tag("branch")
        Text("Revision").tag("revision")
        Text("Exact version").tag("exact")
        Text("From version").tag("major")
        Text("Next minor").tag("minor")
        Text("Version range").tag("range")
      }
      TextField("Value", text: Binding(get: { lower }, set: { update(lower: $0) }))
      if kind == "range" {
        TextField("Upper bound", text: Binding(get: { upper }, set: { update(upper: $0) }))
      }
    }
  }
  private var kind: String {
    switch value {
    case .revision: "revision"
    case .exact: "exact"
    case .upToNextMajor: "major"
    case .upToNextMinor: "minor"
    case .range: "range"
    default: "branch"
    }
  }
  private var lower: String {
    switch value {
    case .branch(let s), .revision(let s), .exact(let s), .upToNextMajor(let s),
      .upToNextMinor(let s), .range(let s, _):
      s
    default: ""
    }
  }
  private var upper: String {
    if case .range(_, let upper) = value { return upper }
    return ""
  }
  private func update(kind: String? = nil, lower: String? = nil, upper: String? = nil) {
    let kind = kind ?? self.kind
    let lower = lower ?? self.lower
    let upper = upper ?? self.upper
    switch kind {
    case "revision": value = .revision(lower)
    case "exact": value = .exact(lower)
    case "major": value = .upToNextMajor(from: lower)
    case "minor": value = .upToNextMinor(from: lower)
    case "range": value = .range(from: lower, to: upper)
    default: value = .branch(lower)
    }
  }
}

struct StringDictionaryEditor: View {
  @Binding var values: [String: String]
  @State private var key = ""
  var body: some View {
    ForEach(values.keys.sorted(), id: \.self) { name in
      HStack {
        TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
        Button("Remove", systemImage: "minus.circle") { values.removeValue(forKey: name) }
          .labelStyle(.iconOnly)
      }
    }
    HStack {
      TextField("New key", text: $key)
      Button("Add") {
        values[key] = ""
        key = ""
      }.disabled(key.isEmpty || values[key] != nil)
    }
  }
}

import AgentsCore
import SwiftUI

struct BindingDictionaryEditor: View {
  @Binding var values: [String: RuntimeBinding]
  @State private var key = ""
  var body: some View {
    ForEach(values.keys.sorted(), id: \.self) { name in
      DisclosureGroup(name) {
        Picker(
          "Binding",
          selection: Binding(
            get: { kind(values[name]) },
            set: { type in
              let text = text(values[name])
              values[name] =
                type == "environment"
                ? .environment(text) : type == "secret" ? .secret(text) : .literal(text)
            })
        ) {
          Text("Literal").tag("literal")
          Text("Environment Variable").tag("environment")
          Text("Secret Reference").tag("secret")
        }
        let binding = Binding(
          get: { text(values[name]) },
          set: { text in
            switch values[name] {
            case .environment: values[name] = .environment(text)
            case .secret: values[name] = .secret(text)
            default: values[name] = .literal(text)
            }
          })
        if case .literal = values[name] {
          SecureField("Value", text: binding)
        } else {
          TextField("Reference", text: binding)
        }
        Button("Remove Binding") { values.removeValue(forKey: name) }
      }
    }
    HStack {
      TextField("New binding name", text: $key)
      Button("Add") {
        values[key] = .literal("")
        key = ""
      }.disabled(key.isEmpty || values[key] != nil)
    }
  }
  private func kind(_ binding: RuntimeBinding?) -> String {
    switch binding {
    case .environment: "environment"
    case .secret: "secret"
    default: "literal"
    }
  }
  private func text(_ binding: RuntimeBinding?) -> String {
    switch binding {
    case .literal(let text), .environment(let text), .secret(let text): text
    default: ""
    }
  }
}

struct ResourceEditor: View {
  @Binding var value: ResourceDeclaration
  var body: some View {
    TextField("Path", text: $value.path)
    OptionalText(title: "source", value: $value.source)
  }
}

struct ExecutableEditor: View {
  @Binding var value: ExecutableDeclaration
  var body: some View {
    TextField("Executable", text: $value.executable)
    LinesEditor(title: "Arguments", values: $value.arguments)
    DisclosureGroup("Environment Bindings") { BindingDictionaryEditor(values: $value.environment) }
    Toggle(
      "Specify working directory",
      isOn: Binding(
        get: { value.workingDirectory != nil },
        set: {
          value.workingDirectory = $0 ? .init(path: "") : nil
        }))
    if value.workingDirectory != nil {
      ResourceEditor(
        value: Binding(
          get: { value.workingDirectory ?? .init(path: "") }, set: { value.workingDirectory = $0 }))
    }
  }
}

struct TransportEditor: View {
  @Binding var value: MCPTransportDeclaration
  var body: some View {
    Picker(
      "Transport",
      selection: Binding(
        get: { kind },
        set: {
          switch $0 {
          case "http": value = .streamableHTTP(url: "")
          case "sse": value = .sse(url: "")
          default: value = .stdio(.init(executable: ""))
          }
        })
    ) {
      Text("Local Process").tag("stdio")
      Text("Streamable HTTP").tag("http")
      Text("Server-Sent Events").tag("sse")
    }
    switch value {
    case .stdio(let executable):
      ExecutableEditor(value: Binding(get: { executable }, set: { value = .stdio($0) }))
    case .streamableHTTP(let url, let headers), .sse(let url, let headers):
      TextField(
        "URL",
        text: Binding(
          get: { url },
          set: {
            value =
              kind == "http"
              ? .streamableHTTP(url: $0, headers: headers) : .sse(url: $0, headers: headers)
          }))
      BindingDictionaryEditor(
        values: Binding(
          get: { headers },
          set: {
            value =
              kind == "http" ? .streamableHTTP(url: url, headers: $0) : .sse(url: url, headers: $0)
          }))
    }
  }
  private var kind: String {
    switch value {
    case .stdio: "stdio"
    case .streamableHTTP: "http"
    case .sse: "sse"
    }
  }
}

struct PromptBodyEditor: View {
  @Binding var value: PromptBody
  var body: some View {
    Picker(
      "Prompt body",
      selection: Binding(
        get: { isFile }, set: { value = $0 ? .file(.init(path: "")) : .literal("") })
    ) {
      Text("Text").tag(false)
      Text("File").tag(true)
    }
    switch value {
    case .literal(let text):
      TextField(
        "Prompt", text: Binding(get: { text }, set: { value = .literal($0) }), axis: .vertical
      ).lineLimit(3...8)
    case .file(let resource):
      ResourceEditor(value: Binding(get: { resource }, set: { value = .file($0) }))
    }
  }
  private var isFile: Bool {
    if case .file = value { return true }
    return false
  }
}

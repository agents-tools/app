import AgentsCore
import SwiftUI

struct NativeValueEditor: View {
  @Binding var value: NativeValue
  var allowsTypeChange = true
  @State private var newKey = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if allowsTypeChange {
        Picker(
          "Value type",
          selection: Binding(
            get: { kind },
            set: { type in
              switch type {
              case "integer": value = .integer(0)
              case "decimal": value = .decimal("0")
              case "boolean": value = .boolean(false)
              case "null": value = .null
              case "array": value = .array([])
              case "object": value = .object([:])
              default: value = .string("")
              }
            })
        ) {
          ForEach(
            ["string", "integer", "decimal", "boolean", "null", "array", "object"], id: \.self
          ) {
            Text($0.capitalized).tag($0)
          }
        }
      }
      switch value {
      case .string(let text):
        TextField("Text", text: Binding(get: { text }, set: { value = .string($0) }))
      case .integer(let integer):
        TextField(
          "Integer", value: Binding(get: { integer }, set: { value = .integer($0) }),
          format: .number)
      case .decimal(let text):
        TextField(
          "Decimal (exact text)", text: Binding(get: { text }, set: { value = .decimal($0) }))
      case .boolean(let flag):
        Toggle("Value", isOn: Binding(get: { flag }, set: { value = .boolean($0) }))
      case .null: Text("Explicit null").foregroundStyle(.secondary)
      case .array(let values):
        DraftRows(
          values: Binding(
            get: {
              if case .array(let items) = value { return items }
              return []
            }, set: { value = .array($0) })
        ) { row, actions in
          DisclosureGroup("Array Item") {
            NativeValueEditor(value: row)
            DraftRowButtons(actions: actions)
          }
        }
        Button("Add Item") { value = .array(values + [.string("")]) }
      case .object(let values):
        ForEach(values.keys.sorted(), id: \.self) { key in
          DisclosureGroup(Self.objectKeyLabel(key)) {
            NativeValueEditor(
              value: objectValue(for: key))
            Button("Remove Value") {
              var values = values
              values.removeValue(forKey: key)
              value = .object(values)
            }
          }
        }
        HStack {
          TextField("New key", text: $newKey)
          Button("Add") {
            addObjectKey(newKey)
            newKey = ""
          }
          .disabled(values[newKey] != nil)
        }
      }
    }
  }

  static func objectKeyLabel(_ key: String) -> String { key.isEmpty ? "Empty key" : key }

  func addObjectKey(_ key: String) {
    guard case .object(var object) = value, object[key] == nil else { return }
    object[key] = .string("")
    value = .object(object)
  }

  func objectValue(for key: String) -> Binding<NativeValue> {
    Binding(
      get: {
        guard case .object(let object) = value else { return .null }
        return object[key] ?? .null
      },
      set: { new in
        guard case .object(var object) = value else { return }
        object[key] = new
        value = .object(object)
      })
  }

  private var kind: String {
    switch value {
    case .string: "string"
    case .integer: "integer"
    case .decimal: "decimal"
    case .boolean: "boolean"
    case .null: "null"
    case .array: "array"
    case .object: "object"
    }
  }
}

struct NativeDictionaryEditor: View {
  @Binding var values: [String: NativeValue]
  var body: some View {
    NativeValueEditor(
      value: Binding(
        get: { .object(values) }, set: { if case .object(let object) = $0 { values = object } }),
      allowsTypeChange: false)
  }
}

struct NativeConfigurationEditor: View {
  @Binding var values: NativeConfiguration
  let allowsAntigravity: Bool
  @State private var client = AgentID.codex
  var body: some View {
    ForEach(values.keys.sorted(), id: \.self) { key in
      DisclosureGroup(AgentID(rawValue: key)?.displayName ?? key) {
        NativeDictionaryEditor(
          values: Binding(get: { values[key] ?? [:] }, set: { values[key] = $0 }))
        Button("Remove Client Options") { values.removeValue(forKey: key) }
      }
    }
    Picker("Client", selection: $client) {
      ForEach(AgentsEditor.choices(allowsAntigravity: allowsAntigravity), id: \.self) {
        Text($0.displayName).tag($0)
      }
    }
    Button("Add Client Options") { values[client.rawValue] = [:] }.disabled(
      values[client.rawValue] != nil || (client == .antigravity && !allowsAntigravity))
  }
}

import AgentsCore
import AgentsManifest
import Foundation
import SwiftUI
import Testing

@testable import AgentsApp

@Suite("Lossless editor bindings")
@MainActor
struct EditorBindingTests {
  @Test func argumentRowBindingsPreserveOccurrencesAndExactStringsThroughCorePreparation() throws {
    var executable = ExecutableDeclaration(executable: "fixture-command")
    let editor = ExecutableEditor(value: Binding(get: { executable }, set: { executable = $0 }))
    var identities: [UUID] = []
    let rows = ArgumentRows(
      values: editor.arguments, identities: Binding(get: { identities }, set: { identities = $0 }))
    for _ in 0..<4 { rows.append() }
    let label = identities[0]
    let empty = identities[1]
    let multiline = identities[2]
    let duplicateEmpty = identities[3]
    rows.text(for: label).wrappedValue = "--label"
    let emptyBinding = rows.text(for: empty)
    emptyBinding.wrappedValue = ""
    rows.text(for: multiline).wrappedValue = "first line\nsecond line\r\nthird line"
    rows.text(for: duplicateEmpty).wrappedValue = ""
    rows.move(multiline, offset: -1)
    emptyBinding.wrappedValue = "edited original empty occurrence"
    #expect(executable.arguments[2] == "edited original empty occurrence")
    #expect(identities[1] == multiline)
    emptyBinding.wrappedValue = ""
    rows.move(multiline, offset: 1)
    #expect(identities == [label, empty, multiline, duplicateEmpty])
    let expected = ["--label", "", "first line\nsecond line\r\nthird line", ""]
    #expect(executable.arguments == expected)

    let document = try DeclarationDocument(
      bytes: Array("version: 1\n".utf8), identity: .init("editor-fixture"))
    let components: [ComponentDeclaration] = [
      .mcpServer(name: "tools", transport: .stdio(executable)),
      .hook(name: "before", event: .beforeTool, run: executable),
      .lspServer(name: "swift", run: executable, languages: [".swift": "swift"]),
    ]
    let change = try document.preparing(
      components.map { .insertComponent($0, into: .root, at: .last) })
    for component in change.expectedDeclaration.components {
      let run = component[component.kind == "mcpServer" ? "transport" : "run"]?.record
      #expect(run?["arguments"]?.elements?.compactMap(\.string) == expected)
    }
    let reparsed = try DeclarationDocument(bytes: change.bytes, identity: .init("roundtrip"))
    #expect(reparsed.declaration == change.expectedDeclaration)
    rows.remove(empty)
    #expect(identities == [label, multiline, duplicateEmpty])
    #expect(executable.arguments == [expected[0], expected[2], ""])
  }

  @Test func nativeObjectControlAllowsVisibleEmptyKeysAndRefusesDuplicateOverwrite() throws {
    var value = NativeValue.object([:])
    let editor = NativeValueEditor(value: Binding(get: { value }, set: { value = $0 }))
    editor.addObjectKey("")
    editor.objectValue(for: "").wrappedValue = .object([:])
    let nested = NativeValueEditor(value: editor.objectValue(for: ""))
    nested.addObjectKey("")
    nested.objectValue(for: "").wrappedValue = .integer(1)
    nested.addObjectKey("")
    editor.addObjectKey("")
    #expect(value == .object(["": .object(["": .integer(1)])]))
    #expect(NativeValueEditor.objectKeyLabel("") == "Empty key")
    let document = try DeclarationDocument(
      bytes: Array("version: 1\n".utf8), identity: .init("editor-fixture"))
    let component = ComponentDeclaration.lspServer(
      name: "swift", run: .init(executable: "fixture-command"), languages: [".swift": "swift"],
      initializationOptions: ["nested": value], native: ["codex": ["nested": value]])
    let change = try document.preparing([.insertComponent(component, into: .root, at: .last)])
    let reparsed = try DeclarationDocument(bytes: change.bytes, identity: .init("roundtrip"))
    #expect(reparsed.declaration == change.expectedDeclaration)
    let record = try #require(reparsed.declaration.components.first)
    guard case .dictionary(let options) = record["initializationOptions"],
      case .dictionary(let clients) = record["native"],
      case .dictionary(let codex) = clients["codex"]
    else {
      Issue.record("Prepared native dictionaries are missing")
      return
    }
    for nestedValue in [options["nested"], codex["nested"]] {
      guard case .record(let outer) = nestedValue,
        case .dictionary(let outerValues) = outer["value"],
        case .record(let inner) = outerValues[""],
        case .dictionary(let innerValues) = inner["value"],
        case .record(let integer) = innerValues[""]
      else {
        Issue.record("Core preparation lost a nested empty key")
        return
      }
      #expect(outer.kind == "object")
      #expect(inner.kind == "object")
      #expect(integer["value"] == .integer(1))
    }
  }
}

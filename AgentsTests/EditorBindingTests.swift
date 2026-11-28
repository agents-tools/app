import AgentsCore
import AgentsManifest
import Foundation
import SwiftUI
import Testing

@testable import AgentsApp

@Suite("Lossless editor bindings")
@MainActor
struct EditorBindingTests {
  @Test func instructionRecipientBindingDistinguishesDefaultsFromAnExplicitEmptySelection() {
    var section = SectionDeclaration(name: "fixture")
    let editor = InstructionRecipientsEditor(
      section: Binding(get: { section }, set: { section = $0 }), scope: .project,
      defaultAgents: [.codex])

    #expect(editor.usesDefaults.wrappedValue)
    #expect(editor.selection(for: .local(.codex)).wrappedValue)
    editor.selection(for: .geminiApp).wrappedValue = true
    #expect(section.recipients == [.local(.codex), .geminiApp])
    #expect(!editor.usesDefaults.wrappedValue)
    editor.selection(for: .local(.codex)).wrappedValue = false
    editor.selection(for: .geminiApp).wrappedValue = false
    #expect(section.recipients == [])
    editor.usesDefaults.wrappedValue = true
    #expect(section.recipients == nil)
  }

  @Test func editingRecipientsCarriesForwardTheLegacyRestrictionAndOtherConditions() {
    let condition = DeclarationCondition(agents: [.codex], scopes: [.project], platforms: [.macOS])
    var section = SectionDeclaration(name: "fixture", source: "team", condition: condition)
    let editor = InstructionRecipientsEditor(
      section: Binding(get: { section }, set: { section = $0 }), scope: .project,
      defaultAgents: [.codex, .claudeCode])

    #expect(editor.usesDefaults.wrappedValue)
    #expect(editor.selection(for: .local(.codex)).wrappedValue)
    #expect(!editor.selection(for: .local(.claudeCode)).wrappedValue)
    #expect(section.recipients == nil && section.condition == condition)

    editor.selection(for: .chatGPTApp).wrappedValue = true
    #expect(section.recipients == [.local(.codex), .chatGPTApp])
    #expect(section.reference == "team:fixture")
    #expect(section.condition == DeclarationCondition(scopes: [.project], platforms: [.macOS]))
    editor.selection(for: .local(.claudeCode)).wrappedValue = true
    #expect(section.recipients == [.local(.codex), .chatGPTApp, .local(.claudeCode)])
  }

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

  @Test func optionalNativeCoordinatesSurviveBindingsDraftLoadAndCorePreparation() throws {
    let root = URL(fileURLWithPath: "/fixture")
    var skill = SkillDeclaration(select: .all)
    var run = ExecutableDeclaration(executable: "bin/server")
    #expect(skill.path == nil && run.executableSource == nil)
    var skillEditor = SkillDraftEditor(value: Binding(get: { skill }, set: { skill = $0 }))
    var runEditor = ExecutableEditor(value: Binding(get: { run }, set: { run = $0 }))
    skillEditor.value.path = "skills/helper"
    runEditor.value.executableSource = "tools"
    runEditor.value.workingDirectory = .init(path: "cwd", source: "workspace")
    runEditor.arguments.wrappedValue = ["", "a\nb"]
    let values: [ComponentDeclaration] = [
      .skills(source: "tools", skill),
      .mcpServer(name: "review", transport: .stdio(run)),
      .hook(name: "before", event: .beforeTool, run: run),
      .lspServer(name: "swift", run: run, languages: [".swift": "swift"]),
    ]
    let empty = try DeclarationDocument(
      bytes: Array("version: 1\n".utf8), identity: .init("native-coordinates"))
    let initial = try empty.preparing(
      [
        .upsertSource(.init(name: "tools", source: .init(kind: .local, location: "./tools"))),
        .upsertSource(
          .init(name: "workspace", source: .init(kind: .local, location: "./workspace"))),
      ] + values.map { .insertComponent($0, into: .root, at: .last) })
    let document = try DeclarationDocument(
      bytes: initial.bytes, identity: .init("native-coordinates"))
    let declaration = Declaration(components: values)
    for (index, component) in values.enumerated() {
      #expect(ComponentDraft(component).value == component)
      let item = try #require(
        CoreReader.items(document).first { $0.pointer == "/components/\(index)" })
      var draft = ManifestDraft(scope: .init(kind: .project, root: root), document: document)
      draft.load(item, from: declaration)
      #expect(draft.component.value == component)
      let prepared = try document.preparing(draft.edits(home: root))
      #expect(prepared.expectedDeclaration == document.declaration)
    }
    skillEditor.value.path = nil
    runEditor.value.executableSource = nil
    #expect(skill.path == nil && run.executableSource == nil)
    #expect(run.workingDirectory?.source == "workspace")
    #expect(DeclarationLabels.field("executableSource") == "Executable Source Alias")
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

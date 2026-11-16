import AgentsManifest
import Foundation
import Testing

@testable import AgentsApp

struct DeclarationPresentationTests {
  @Test func omissionEvidenceHidesSyntheticFieldsAndRetainsExplicitEmptyAndNativeNull() throws {
    let document = try DeclarationDocument(
      bytes: Array(
        """
        version: 1
        components:
          - kind: mcpServer
            name: example
            agents: []
            transport:
              kind: stdio
              executable: fixture-command
            native:
              codex:
                optionalValue: null
        """.utf8), identity: .init("fixture"))
    let authored = AuthoredFields(sourceMap: document.sourceMap)
    #expect(authored.contains("/components/0/agents"))
    #expect(!authored.contains("/components/0/condition"))
    #expect(!authored.contains("/components/0/transport/environment"))
    #expect(authored.contains("/components/0/native/codex/optionalValue"))
    #expect(document.declaration.components.first?["agents"]?.elements == [])
  }
}

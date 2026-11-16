import Foundation
import Testing

@testable import AgentsApp

@MainActor
struct PreferenceTests {
  @Test func addingAndRemovingProjectsChangesOnlyPreferences() async throws {
    let fixture = try TestFixture()
    defer { try? fixture.remove() }
    let before = try fixture.entries()
    let preferences = AppPreferences(defaults: nil)
    let model = AppModel(
      home: fixture.home, preferences: preferences, processEnvironment: fixture.environment)
    model.addProject(fixture.project)
    model.addProject(fixture.project)
    #expect(preferences.projects == [fixture.project])
    model.removeProject(fixture.project)
    #expect(preferences.projects.isEmpty)
    #expect(model.scope.kind == .user)
    for _ in 0..<1000 {
      if model.operations.isEmpty { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.operations.isEmpty)
    #expect(try fixture.entries() == before)
  }
}

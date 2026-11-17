import AgentsCore
import AgentsInstructions
import CoreServices
import Foundation
import Testing

@testable import AgentsApp

@Suite("Typed read dependencies", .serialized)
struct ReadDependencyTests {
  @Test func entryAndSubtreeKeepTheirIndependentInterests() {
    let home = URL(fileURLWithPath: "/fixture/home")
    let fetch = home.appendingPathComponent(".agents/cache/mirrors/demo.git/FETCH_HEAD").path
    let entry = ReadDependency.entry(home)
    let subtree = ReadDependency.subtree(home)
    #expect(!ReadMonitor.matches(fetch, dependencies: [entry]))
    #expect(ReadMonitor.matches(fetch, dependencies: [subtree]))
    let union = Set([entry]).union([subtree, entry])
    #expect(union.count == 2)
    #expect(ReadMonitor.matches(fetch, dependencies: Array(union)))
    #expect(!ReadMonitor.matches("/fixture/homestead/file", dependencies: Array(union)))
  }

  @Test func absentLeavesAndRecoveryAnchorsMatchTheirEntriesAndAncestors() {
    let absent = URL(fileURLWithPath: "/fixture/external/absent/transaction.new")
    let dependencies: [ReadDependency] = [.entry(absent)]
    for event in [absent.path, "/fixture/external/absent", "/fixture/external", "/fixture", "/"] {
      #expect(ReadMonitor.matches(event, dependencies: dependencies))
    }
    #expect(!ReadMonitor.matches(absent.path + "/child", dependencies: dependencies))
    #expect(
      !ReadMonitor.matches("/fixture/external/absent/transaction.newer", dependencies: dependencies)
    )
    #expect(!ReadMonitor.matches("/unrelated", dependencies: dependencies))
    #expect(
      !ReadMonitor.matches("/fixture/other", dependencies: [.entry(URL(fileURLWithPath: "/"))]))
  }

  @Test func logicalAndPhysicalAliasEntriesRemainDistinct() {
    let logical = URL(fileURLWithPath: "/fixture/alias/.agent/agents.yaml")
    let physical = URL(fileURLWithPath: "/fixture/physical/.agent/agents.yaml")
    let dependencies: [ReadDependency] = [.entry(logical), .entry(physical)]
    #expect(ReadMonitor.matches("/fixture/alias", dependencies: dependencies))
    #expect(ReadMonitor.matches(physical.path, dependencies: dependencies))
    #expect(!ReadMonitor.matches("/fixture/physical/other", dependencies: dependencies))
  }

  @Test func actualMappingDependenciesReachBothReaderAndExplicitCompletion() throws {
    let f = try TestFixture()
    defer { try? f.remove() }
    let scope = WorkspaceScope(kind: .project, root: f.project)
    let actions = CoreActions(home: f.home, processEnvironment: f.environment)
    let values = InstructionOperations.export(
      projectRoots: [f.project], environment: actions.environment(for: scope))
    let dependencies = Set(values.flatMap(\.readDependencies))
    #expect(!dependencies.isEmpty)
    #expect(dependencies.allSatisfy { if case .entry = $0 { true } else { false } })
    let completion = actions.mappings(.init(id: UUID(), context: scope, projects: [f.project]))
    #expect(Set(completion.readDependencies) == dependencies)
    let read = CoreReader(home: f.home, processEnvironment: f.environment).read(scope: scope)
    #expect(dependencies.isSubset(of: Set(read.readDependencies)))
    let fetch = f.home.appendingPathComponent(".agents/cache/mirrors/demo.git/FETCH_HEAD").path
    #expect(!ReadMonitor.matches(fetch, dependencies: Array(dependencies)))
    #expect(
      read.readDependencies.contains(
        .subtree(f.project.appendingPathComponent(".agent/agents.yaml"))))
  }
}

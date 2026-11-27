import AgentsCore
import AgentsInstructions
import CoreServices
import Foundation
import Testing

@testable import AgentsApp

@Suite("Typed read dependencies", .serialized)
struct ReadDependencyTests {
  private let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
  private let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)

  @Test func entryAndSubtreeKeepTheirIndependentInterests() {
    let home = URL(fileURLWithPath: "/fixture/home")
    let fetch = home.appendingPathComponent(".agents/cache/mirrors/demo.git/FETCH_HEAD").path
    let entry = ReadDependency.entry(home)
    let subtree = ReadDependency.subtree(home)
    #expect(!matches(fetch, flags: modified, dependencies: [entry]))
    #expect(matches(fetch, flags: modified, dependencies: [subtree]))
    let union = Set([entry]).union([subtree, entry])
    #expect(union.count == 2)
    #expect(matches(fetch, flags: modified, dependencies: Array(union)))
    #expect(
      !matches("/fixture/homestead/file", flags: modified, dependencies: Array(union)))
  }

  @Test func absentLeavesAndRecoveryAnchorsMatchTheirEntriesAndAncestors() {
    let absent = URL(fileURLWithPath: "/fixture/external/absent/transaction.new")
    let dependencies: [ReadDependency] = [.entry(absent)]
    for event in [absent.path, "/fixture/external/absent", "/fixture/external", "/fixture", "/"] {
      #expect(matches(event, flags: renamed, dependencies: dependencies))
    }
    #expect(
      !matches(absent.path + "/child", flags: modified, dependencies: dependencies))
    #expect(
      !matches(
        "/fixture/external/absent/transaction.newer", flags: modified, dependencies: dependencies)
    )
    #expect(!matches("/unrelated", flags: modified, dependencies: dependencies))
    #expect(
      !matches(
        "/fixture/other", flags: modified, dependencies: [.entry(URL(fileURLWithPath: "/"))]))
  }

  @Test func logicalAndPhysicalAliasEntriesRemainDistinct() {
    let logical = URL(fileURLWithPath: "/fixture/alias/.agent/agents.yaml")
    let physical = URL(fileURLWithPath: "/fixture/physical/.agent/agents.yaml")
    let dependencies: [ReadDependency] = [.entry(logical), .entry(physical)]
    #expect(matches("/fixture/alias", flags: renamed, dependencies: dependencies))
    #expect(matches(physical.path, flags: modified, dependencies: dependencies))
    #expect(
      !matches("/fixture/physical/other", flags: modified, dependencies: dependencies))
  }

  @Test func directoryBookkeepingAndLFSCacheDoNotInvalidateAuthoredInputs() {
    let root = URL(fileURLWithPath: "/fixture/producer")
    let source = ReadDependency.subtree(root)
    let home = ReadDependency.entry(root.deletingLastPathComponent())
    let object = root.appendingPathComponent(".git/lfs/objects/a3/f0")
    let bookkeeping = modified | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    #expect(
      !matches(
        root.deletingLastPathComponent().path, flags: bookkeeping,
        dependencies: [home, source]))
    #expect(!matches(object.path, flags: bookkeeping, dependencies: [source]))
    #expect(!matches(object.path, flags: renamed, dependencies: [source]))
    #expect(
      matches(object.path, flags: renamed, dependencies: [source, .entry(object)]))
    #expect(
      matches(
        root.appendingPathComponent("instructions/rules.md").path,
        flags: modified, dependencies: [source]))
  }

  @Test func indexedInterestsPreserveMatchesAcrossInterleavedEventsAndScopes() {
    let repo = URL(fileURLWithPath: "/fixture/repo")
    let objectStore = repo.appendingPathComponent(".git/lfs/objects")
    let scope = ReadDependencyIndex([
      .subtree(repo),
      .subtree(objectStore.appendingPathComponent("selected")),
      .entry(URL(fileURLWithPath: "/fixture/scope/../state/transaction.json")),
    ])
    let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
    let changedRoot = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
    let metadata = FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod)
    let history = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
    let events = [
      ("/fixture/repository/unrelated", modified, false),
      (repo.appendingPathComponent("instructions/rules.md").path, modified, true),
      (objectStore.appendingPathComponent("unselected/new-object").path, renamed, false),
      (objectStore.appendingPathComponent("selected/new-object").path, modified, true),
      ("/fixture/state/transaction.json", modified, true),
      ("/fixture/state", modified, false),
      ("/fixture/state", metadata, true),
      ("/fixture/state", changedRoot, true),
      ("/fixture/elsewhere", rescan, false),
      ("/", rescan, true),
      ("/", rescan | history, false),
    ]
    for (path, flags, expected) in events {
      #expect(scope.matches(path, flags: flags) == expected, "Unexpected match for \(path)")
    }

    let replacement = ReadDependencyIndex([.subtree(URL(fileURLWithPath: "/fixture/elsewhere"))])
    #expect(replacement.matches("/fixture/elsewhere", flags: rescan))
    #expect(!replacement.matches(repo.path, flags: changedRoot))
  }

  @Test func volumeChangesMatchAncestorsOfWatchedSources() {
    let source = URL(fileURLWithPath: "/Volumes/Work/repo")
    let index = ReadDependencyIndex([.subtree(source)])
    for flag in [kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
      let flags = FSEventStreamEventFlags(flag | kFSEventStreamEventFlagItemIsDir)
      #expect(index.matches("/Volumes/Work", flags: flags))
      #expect(!index.matches("/Volumes/Workspace", flags: flags))
    }
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
    #expect(!matches(fetch, flags: modified, dependencies: Array(dependencies)))
    #expect(
      read.readDependencies.contains(
        .subtree(f.project.appendingPathComponent(".agent/agents.yaml"))))
  }

  private func matches(
    _ event: String, flags: FSEventStreamEventFlags, dependencies: [ReadDependency]
  ) -> Bool {
    ReadDependencyIndex(dependencies).matches(event, flags: flags)
  }
}

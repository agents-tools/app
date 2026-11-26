import AgentsCore
import AgentsInstructions
import AgentsUpdates
import CryptoKit
import Darwin
import Foundation

enum ManagedInstructionOutput {
  static func read(
    _ selected: MappingTarget, in scope: WorkspaceScope, environment: RuntimeEnvironment
  ) throws -> (Data, [ReadDependency]) {
    let store = StateStore(scope: scope.installScope, environment: environment)
    let locked = try store.loadResolved().instructions
    let projects = scope.kind == .project ? [scope.root] : []
    let values = InstructionOperations.export(projectRoots: projects, environment: environment)
    guard
      let value = values.first(where: {
        $0.scope == scope.installScope
          && $0.root.standardizedFileURL.path == scope.root.standardizedFileURL.path
      }), value.status == .locked
    else {
      throw CoreError.invalidState("The instruction mapping is unavailable for this scope.")
    }
    let mapping = CoreReader.mapping(value)
    guard mapping.targets.contains(selected) else { throw mappingChanged }

    var dependencies = value.readDependencies
    func verifiedBytes(for target: MappingTarget) throws -> Data {
      guard let entry = locked.targets[target.id],
        entry.import == target.importedFile, Set(entry.agents) == Set(target.recipients)
      else { throw mappingChanged }
      let file = try admittedFile(for: target, scope: scope, environment: environment)
      let bytes = try readRegularFile(file)
      let current: Bool
      if target.importedFile != nil {
        current =
          try Instructions.detectDrift(in: bytes, lockedBlockHash: entry.blockHash) == .clean
      } else {
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        current = entry.blockHash == "sha256:" + hash
      }
      guard current else {
        throw CoreError.invalidState(
          "The managed instruction file “\(target.id)” differs from its lock.")
      }
      dependencies.append(.entry(file))
      return bytes
    }

    let bytes: Data
    if let reference = selected.importedFile {
      guard scope.kind == .project, let claude = ClaudeInstructionPath(rawValue: selected.id),
        reference == String(claude.importLine.dropFirst()),
        let shared = mapping.targets.first(where: {
          $0.id == "AGENTS.md" && $0.importedFile == nil && $0.recipients.contains(.claudeCode)
        })
      else {
        throw CoreError.invalidState("The managed Claude import has no mapped instruction file.")
      }
      _ = try verifiedBytes(for: selected)
      bytes = try verifiedBytes(for: shared)
    } else {
      bytes = try verifiedBytes(for: selected)
    }
    // The digest tied the opened bytes to the captured lock. Reject a new generation during copy.
    guard try store.loadResolved().instructions == locked else { throw mappingChanged }
    return (bytes, dependencies)
  }

  private static var mappingChanged: CoreError {
    .invalidState("This instruction mapping changed. Refresh and try again.")
  }

  private static func admittedFile(
    for target: MappingTarget, scope: WorkspaceScope, environment: RuntimeEnvironment
  ) throws -> URL {
    let unsafe = CoreError.unsafePath(
      "The instruction file “\(target.id)” is outside its managed location.")
    let input = target.id
    let relative = input.hasPrefix("~/") ? String(input.dropFirst(2)) : input
    let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !input.contains("\0"), !input.contains("\\"),
      !segments.dropFirst(input.hasPrefix("/") ? 1 : 0).contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".."
      })
    else { throw unsafe }
    let url =
      input.hasPrefix("/")
      ? URL(fileURLWithPath: input) : scope.root.appendingPathComponent(relative)
    guard let leaf = segments.last else { throw unsafe }
    if scope.kind == .project {
      guard !input.hasPrefix("/"), !input.hasPrefix("~/") else { throw unsafe }
      if ClaudeInstructionPath(rawValue: input) != nil, target.importedFile != nil {
        return url
      }
      if leaf == "AGENTS.md" || leaf == "GEMINI.md",
        !segments.dropLast().contains(".git"), segments.first != ".agent",
        target.importedFile == nil
      {
        return url
      }
    } else if !input.hasPrefix("~/"), !input.hasPrefix("/") {
      throw unsafe
    }

    let clientLocations = try AgentClientOperations.inspect(
      scope: scope.installScope, environment: environment
    ).clients.filter { target.recipients.contains($0.agent) }
      .flatMap(\.configurationLocations).filter { $0.purpose == .instructions }
    for location in clientLocations {
      guard let admitted = location.location?.standardizedFileURL else { continue }
      switch location.objectRole {
      case .file:
        if url.path == admitted.path { return url }
      case .container:
        if url.deletingLastPathComponent().path == admitted.path,
          leaf.range(of: #"^agents-[a-z0-9_-]{1,60}-[a-f0-9]{64}\.md\z"#) != nil
        {
          return url
        }
      }
    }
    throw unsafe
  }

  private static func readRegularFile(_ url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw CoreError.unsafePath("Couldn’t open the managed instruction file at \(url.path).")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw CoreError.unsafePath("Expected a regular managed instruction file at \(url.path).")
    }
    // A sparse replacement of a managed file must not force a large allocation on the read worker.
    let maximumBytes = 128 * 1024 * 1024
    guard let size = Int(exactly: info.st_size), (0...maximumBytes).contains(size) else {
      throw CoreError.invalidState("The managed instruction file is too large to copy.")
    }
    guard
      let bytes = try handle.read(upToCount: size + 1), bytes.count == size
    else {
      throw CoreError.invalidState("The managed instruction file changed while it was being read.")
    }
    return bytes
  }
}

import Foundation

struct TestFixture: Sendable {
  let root: URL
  var home: URL { root.appendingPathComponent("home") }
  var project: URL { root.appendingPathComponent("project") }
  var environment: [String: String] {
    ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
  }

  init() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let output =
      ProcessInfo.processInfo.environment["AGENTS_TEST_OUTPUT_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? repository.appendingPathComponent(".agent/evidence/m3/fixtures")
    root = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  }

  func writeManifest(_ text: String, user: Bool = false) throws {
    let directory =
      user ? home.appendingPathComponent(".agents") : project.appendingPathComponent(".agent")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: directory.appendingPathComponent("agents.yaml"))
  }

  func remove() throws { try FileManager.default.removeItem(at: root) }

  func entries() throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    var files: [String: Data] = [:]
    for case let file as URL in enumerator {
      if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
      }
    }
    return files
  }
}

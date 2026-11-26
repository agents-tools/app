import AgentsCore
import Darwin
import Foundation
import Yams

struct SkillMetadataReader {
  struct Display {
    var title: String?
    var summary: String?
    var sourceURL: URL?
    var iconURL: URL?
  }

  private let metadataLimit = 16 * 1024
  private let iconLimit = 1024 * 1024
  private var cache: [URL: Display] = [:]
  private(set) var dependencies = Set<ReadDependency>()

  mutating func read(_ locations: [URL]) -> Display {
    var fallback: Display?
    for location in locations {
      if cache[location] == nil { cache[location] = read(root: location) }
      guard let value = cache[location] else { continue }
      if value.sourceURL != nil { return value }
      if fallback == nil, value.title != nil || value.summary != nil || value.iconURL != nil {
        fallback = value
      }
    }
    return fallback ?? Display()
  }

  private mutating func read(root location: URL) -> Display {
    // The locked resource or installation can itself be a managed symlink.
    guard let physical = realpath(location.path, nil) else { return Display() }
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    let manifest = root.appendingPathComponent("agents/openai.yaml")
    let markdown = root.appendingPathComponent("SKILL.md")
    dependencies.insert(.entry(manifest))
    dependencies.insert(.entry(markdown))
    dependencies.insert(.entry(location))

    let interface = readFile(manifest, limit: metadataLimit, prefix: false)
      .flatMap { String(data: $0, encoding: .utf8) }
      .flatMap { try? Yams.compose(yaml: $0) }?["interface"]
    let markdownBytes = readFile(markdown, limit: metadataLimit, prefix: true)
    let frontMatter = markdownBytes.flatMap(Self.frontMatter)
    let icon = ["icon_small", "icon_large"].lazy
      .compactMap { interface?[$0]?.string }
    var iconURL: URL?
    for path in icon {
      guard let candidate = Self.iconPath(path, root: root) else { continue }
      dependencies.insert(.entry(candidate))
      if let size = Self.fileSize(candidate), size > 0, size <= iconLimit {
        iconURL = candidate
        break
      }
    }
    return Display(
      title: Self.text(interface?["display_name"]?.string, limit: 256)
        ?? Self.text(frontMatter?["name"]?.string, limit: 256),
      summary: Self.text(interface?["short_description"]?.string, limit: 1024)
        ?? Self.text(frontMatter?["description"]?.string, limit: 4096),
      sourceURL: markdownBytes == nil ? nil : markdown, iconURL: iconURL)
  }

  private static func frontMatter(_ data: Data) -> Node? {
    let lines = String(decoding: data, as: UTF8.self)
      .components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
      return nil
    }
    return try? Yams.compose(yaml: lines[1..<end].joined(separator: "\n"))
  }

  private static func text(_ value: String?, limit: Int) -> String? {
    guard let value else { return nil }
    let cleaned = value.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
        || CharacterSet.whitespacesAndNewlines.contains($0)
    }
    let bounded = String(String.UnicodeScalarView(cleaned))
      .trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)
    return bounded.isEmpty ? nil : String(bounded)
  }

  private static func iconPath(_ relative: String, root: URL) -> URL? {
    guard relative.utf8.count <= 512, !relative.hasPrefix("/"), !relative.hasPrefix("~"),
      !relative.contains(":"), !relative.contains("\\"), !relative.contains("\0")
    else { return nil }
    let parts = relative.split(separator: "/").filter { $0 != "." }
    guard !parts.isEmpty, !parts.contains("..") else { return nil }
    let url = parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    let formats = ["svg", "png", "jpg", "jpeg", "webp", "heic", "icns", "tiff", "gif"]
    return formats.contains(url.pathExtension.lowercased()) ? url : nil
  }

  private static func openRegularFile(_ url: URL) -> (descriptor: Int32, size: Int)? {
    // Reject links in descendants, and avoid blocking when hostile metadata names a FIFO.
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      close(descriptor)
      return nil
    }
    return (descriptor, Int(info.st_size))
  }

  private static func fileSize(_ url: URL) -> Int? {
    guard let file = openRegularFile(url) else { return nil }
    close(file.descriptor)
    return file.size
  }

  private func readFile(_ url: URL, limit: Int, prefix: Bool) -> Data? {
    guard let file = Self.openRegularFile(url) else { return nil }
    let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    guard prefix || file.size <= limit,
      let bytes = try? handle.read(upToCount: prefix ? limit : limit + 1),
      bytes.count <= limit
    else { return nil }
    return bytes
  }
}

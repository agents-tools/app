import AgentsCore
import Foundation
import Observation

@MainActor @Observable
final class AppPreferences {
  private let defaults: UserDefaults?
  private(set) var projects: [URL]
  var organizationPolicyFiles: [String: String] {
    didSet { defaults?.set(organizationPolicyFiles, forKey: "organizationPolicyFiles") }
  }
  var selectedScopeID: String? {
    didSet { defaults?.set(selectedScopeID, forKey: "selectedScope") }
  }
  var inspectorVisible: Bool {
    didSet { defaults?.set(inspectorVisible, forKey: "inspectorVisible") }
  }
  var assistanceEnabled: Bool {
    didSet { defaults?.set(assistanceEnabled, forKey: "assistanceEnabled") }
  }
  var webInstructionSelections: [String: [String]] {
    didSet { defaults?.set(webInstructionSelections, forKey: "webInstructionSelections") }
  }

  init(defaults: UserDefaults? = .standard, initialProjects: [URL] = []) {
    self.defaults = defaults
    organizationPolicyFiles =
      defaults?.dictionary(forKey: "organizationPolicyFiles") as? [String: String] ?? [:]
    let saved =
      defaults?.stringArray(forKey: "projects")?.map { URL(fileURLWithPath: $0) } ?? initialProjects
    var seen = Set<String>()
    projects = saved.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    selectedScopeID = defaults?.string(forKey: "selectedScope")
    inspectorVisible = defaults?.object(forKey: "inspectorVisible") as? Bool ?? true
    assistanceEnabled = defaults?.object(forKey: "assistanceEnabled") as? Bool ?? false
    webInstructionSelections =
      defaults?.dictionary(forKey: "webInstructionSelections") as? [String: [String]] ?? [:]
  }

  func addProject(_ url: URL) {
    let root = url.standardizedFileURL
    guard !projects.contains(root) else { return }
    projects.append(root)
    saveProjects()
  }

  func removeProject(_ url: URL) {
    projects.removeAll { $0 == url.standardizedFileURL }
    saveProjects()
  }

  private func saveProjects() {
    defaults?.set(projects.map(\.path), forKey: "projects")
  }
}

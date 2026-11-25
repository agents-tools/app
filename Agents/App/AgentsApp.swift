import AgentsCore
import AppKit
import SwiftUI

@main
struct AgentsApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
  @State private var model: AppModel

  init() {
    ProcessLimits.raiseOpenFileLimit()
    let input = LaunchInput.current
    let preferences = AppPreferences(
      defaults: input.isFixture ? nil : .standard,
      initialProjects: input.projects)
    _model = State(
      initialValue: AppModel(
        home: input.home, preferences: preferences,
        processEnvironment: input.environment))
  }

  var body: some Scene {
    Window("Agents App", id: "workspace") {
      WorkspaceView(model: model)
        .frame(minWidth: 900, minHeight: 580)
        .onAppear {
          delegate.model = model
          model.terminationReply = { allowed in
            NSApplication.shared.reply(toApplicationShouldTerminate: allowed)
          }
          if case .idle = model.loadState { model.refresh() }
        }
        .onDisappear { model.discardSourceAccess() }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
          if model.operations.isEmpty { model.refresh() }
        }
    }
    .defaultSize(width: 1160, height: 760)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Add Project…") { chooseProject(for: model) }
          .keyboardShortcut("o", modifiers: [.command, .shift])
          .disabled(model.isTerminating || model.isApplying)
      }
      CommandGroup(after: .toolbar) {
        Button("Refresh Configuration") { model.refresh() }
          .keyboardShortcut("r", modifiers: .command)
          .disabled(model.isTerminating || model.isApplying)
        Toggle(
          "Show Inspector",
          isOn: Binding(
            get: { model.preferences.inspectorVisible }, set: model.setInspectorVisible)
        )
        .keyboardShortcut("i", modifiers: [.command, .option])
      }
    }
    Settings {
      SettingsView(model: model).frame(width: 580, height: 420)
    }
  }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  var model: AppModel?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    switch model.requestTermination() {
    case .now: return .terminateNow
    case .later: return .terminateLater
    case .cancel: return .terminateCancel
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
func chooseProject(for model: AppModel) {
  let panel = NSOpenPanel()
  panel.title = "Add Project"
  panel.prompt = "Add Project"
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.canCreateDirectories = false
  panel.message =
    "Adds a directory to this app’s project list. Configuration files are not created or changed."
  let completion: (NSApplication.ModalResponse) -> Void = { [panel] response in
    if response == .OK, let url = panel.url { model.addProject(url) }
  }
  if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
    panel.beginSheetModal(for: window, completionHandler: completion)
  } else {
    panel.begin(completionHandler: completion)
  }
}

struct LaunchInput {
  let home: URL
  let projects: [URL]
  let isFixture: Bool
  let environment: [String: String]

  static var current: Self {
    let environment = ProcessInfo.processInfo.environment
    #if DEBUG
      if environment["AGENTS_APP_TESTING"] == "1",
        let path = environment["AGENTS_APP_FIXTURE_ROOT"], path.hasPrefix("/")
      {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        return Self(
          home: home, projects: [], isFixture: true,
          environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
      }
      let arguments = ProcessInfo.processInfo.arguments
      if let index = arguments.firstIndex(of: "--agents-fixture-root"),
        arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/")
      {
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        // Fixtures never inherit client-specific path overrides from the developer's shell.
        let home = root.appendingPathComponent("home", isDirectory: true)
        return Self(
          home: home, projects: [root.appendingPathComponent("project", isDirectory: true)],
          isFixture: true,
          environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
      }
    #endif
    return Self(
      home: FileManager.default.homeDirectoryForCurrentUser, projects: [],
      isFixture: false, environment: environment)
  }
}

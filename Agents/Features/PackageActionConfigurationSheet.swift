import AgentsCore
import AgentsManifest
import AgentsUpdates
import SwiftUI

struct PackageActionConfigurationSheet: View {
  enum Mode: Identifiable {
    case scaffold
    case edit(DeclarationDocument)
    case enable

    var id: String {
      switch self {
      case .scaffold: "scaffold"
      case .edit: "edit"
      case .enable: "enable"
      }
    }

    var title: String {
      switch self {
      case .scaffold: "Add Package Action Configuration"
      case .edit: "Edit Package Actions"
      case .enable: "Enable Project Actions"
      }
    }

    var saveTitle: LocalizedStringKey {
      if case .scaffold = self { "Add Configuration" } else { "Save" }
    }
  }

  private enum Review {
    case save(LifecycleDeclarationReview)
    case enable(LifecycleEnableReview)

    var enablement: LifecycleEnablement? {
      switch self {
      case .save(let review): review.enablement
      case .enable(let review): review.enablement
      }
    }

    var declaration: DeclarationValue? {
      switch self {
      case .save(let review): review.declaration
      case .enable(let review): review.enablement.declaration
      }
    }
  }

  let model: AppModel
  let scope: WorkspaceScope
  let environment: RuntimeEnvironment
  let mode: Mode
  let saved: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var yaml = ""
  @State private var original = ""
  @State private var reviewedYAML = ""
  @State private var review: Review?
  @State private var preparing = true
  @State private var working = false
  @State private var failure: String?
  @State private var editorReady = false

  private var destination: URL {
    StateStore(scope: scope.installScope, environment: environment).declarationURL
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(mode.title).font(.headline)
      LabeledContent("Configuration File") { PathView(url: destination, scope: scope) }

      if let review {
        if let enablement = review.enablement {
          LabeledContent("Project Folder") {
            PathView(url: URL(fileURLWithPath: enablement.project.canonicalPath))
          }
          Text(
            "Enabling applies to the configuration shown here. Changes to its actions require another review."
          )
          .foregroundStyle(.secondary)
          Text(
            "Shell commands run with your access and can call other files that may change after this review."
          )
          .foregroundStyle(.secondary)
        }
        ScrollView {
          Text(reviewedYAML.isEmpty ? "Remove the package action configuration." : reviewedYAML)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 180)
          .accessibilityLabel("Reviewed package action YAML")
      } else if editorReady {
        Text("Edit the lifecycle section. Clear it to remove the package action configuration.")
          .foregroundStyle(.secondary)
        ConfigurationYAMLEditor(label: "Package action YAML", text: $yaml).disabled(preparing)
      } else {
        Spacer(minLength: 0)
      }
      if let failure {
        Text(failure).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction).disabled(working)
        if case .edit = mode, review != nil {
          Button("Back to Editor") {
            review = nil
            failure = nil
          }.disabled(working)
        }
        Spacer()
        if preparing || working { ProgressView().controlSize(.small) }
        switch review {
        case .save(let review):
          Button(mode.saveTitle) {
            save(review, enable: false)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(working || !model.canModify)
          if review.enablement != nil, case .edit = mode {
            Button("Save and Enable") { save(review, enable: true) }
              .disabled(working || !model.canModify)
          }
        case .enable(let review):
          Button("Enable Project Actions") { enable(review) }
            .disabled(working || !model.canModify)
        case nil:
          if case .edit(let originalDocument) = mode, editorReady {
            Button("Review Changes") { prepareEdit(originalDocument) }
              .keyboardShortcut(.defaultAction)
              .disabled(preparing || !model.canModify || yaml == original)
          }
        }
      }
    }
    .padding(20)
    .frame(minWidth: 590, minHeight: 400)
    .interactiveDismissDisabled(working)
    .task {
      switch mode {
      case .edit(let document):
        do {
          yaml = try PackageActionYAML.text(for: document.declaration.lifecycle)
          original = yaml
          editorReady = true
        } catch {
          failure = String(describing: error)
        }
        preparing = false
      case .scaffold:
        await prepare { [scope, environment] in
          .save(
            try LifecycleOperations.previewScaffold(
              scope: scope.installScope, environment: environment))
        }
      case .enable:
        await prepare { [environment] in
          .enable(try LifecycleOperations.reviewEnable(environment: environment))
        }
      }
    }
  }

  private func prepareEdit(_ document: DeclarationDocument) {
    preparing = true
    let draft = yaml
    Task {
      await prepare { [scope, environment] in
        .save(
          try PackageActionYAML.preview(
            draft, replacing: document, scope: scope, environment: environment))
      }
    }
  }

  private func prepare(_ operation: @escaping @Sendable () throws -> Review) async {
    failure = nil
    defer { preparing = false }
    do {
      let (candidate, text) = try await Task.detached {
        let candidate = try operation()
        return (candidate, try PackageActionYAML.text(for: candidate.declaration))
      }.value
      guard !Task.isCancelled else { return }
      reviewedYAML = text
      review = candidate
    } catch {
      failure = String(describing: error)
    }
  }

  private func save(_ review: LifecycleDeclarationReview, enable: Bool) {
    guard model.canModify else { return }
    failure = nil
    working = model.startPackageActionEffect(
      title: "Save Package Actions", scope: scope, writes: true
    ) {
      [scope] in
      await CoreActions.savePackageActions(review, enable: enable, scope: scope)
    } receive: { completion in
      working = false
      switch completion.output {
      case .packageActionSave(.saved): saved("Package action configuration saved.")
      case .packageActionSave(.savedAndEnabled): saved("Project actions saved and enabled.")
      case .packageActionSave(.savedEnablementIncomplete):
        saved("Configuration saved. Review the current project actions again to enable them.")
      default: showFailure(completion)
      }
    }
  }

  private func enable(_ review: LifecycleEnableReview) {
    guard model.canModify else { return }
    failure = nil
    working = model.startPackageActionEffect(
      title: "Enable Package Actions", scope: scope, writes: true
    ) {
      [scope] in
      await CoreActions.enablePackageActions(review, scope: scope)
    } receive: { completion in
      working = false
      if completion.disposition == .completed {
        saved("Project actions enabled.")
      } else {
        showFailure(completion)
      }
    }
  }

  private func showFailure(_ completion: CoreCompletion) {
    failure =
      completion.disposition == .cancelled
      ? "Operation cancelled."
      : completion.diagnostics.map(\.message).joined(separator: "\n")
    review = nil
  }
}

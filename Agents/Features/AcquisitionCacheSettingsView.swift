import AgentsCore
import Foundation
import SwiftUI

struct AcquisitionCacheSettingsView: View {
  private let environment: RuntimeEnvironment

  @State private var inventory: AcquisitionCacheInventory?
  @State private var lastRemoval:
    (operation: AcquisitionCacheMaintenance, result: AcquisitionCacheRemoval)?
  @State private var pendingPreview: PreviewSheetItem?
  @State private var pruneDaysText = "30"
  @State private var isBusy = false
  @State private var errorMessage: String?
  @State private var runningTask: Task<Void, Never>?

  init(environment: RuntimeEnvironment) {
    self.environment = environment
  }

  private var pruneDays: Int? {
    let trimmed = pruneDaysText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(trimmed), value >= 0 else { return nil }
    return value
  }

  private var isMainDisabled: Bool {
    isBusy || pendingPreview != nil
  }

  var body: some View {
    Form {
      Section("Storage") {
        LabeledContent("Location") {
          Text(inventory?.root.path(percentEncoded: false) ?? "—")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        LabeledContent {
          HStack(spacing: 8) {
            if let inventory {
              Text(formatBytes(inventory.totalBytes))
                .monospacedDigit()
            } else {
              Text("—")
                .foregroundStyle(.secondary)
            }
            Button("Refresh") { refresh() }
              .disabled(isMainDisabled)
          }
        } label: {
          Text("Total Size")
          if let inventory {
            Text(entryCountText(inventory.entries.count))
          }
        }
      }

      Section("Stores") {
        ForEach(AcquisitionCacheStore.allCases, id: \.self) { store in
          let entries = inventory?.entries.filter { $0.store == store } ?? []
          let pending = entries.filter(\.pendingDisposal).count
          LabeledContent {
            if let inventory {
              Text(formatBytes(inventory.bytes(in: store)))
                .monospacedDigit()
            } else {
              Text("—")
                .foregroundStyle(.secondary)
            }
          } label: {
            Text(storeTitle(store))
            if inventory != nil {
              Text(
                pending > 0
                  ? "\(entryCountText(entries.count)) · \(pending) pending disposal"
                  : entryCountText(entries.count))
            }
          }
        }
      }

      Section("Maintenance") {
        LabeledContent {
          HStack(spacing: 6) {
            TextField("Days", text: $pruneDaysText)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .monospacedDigit()
              .frame(width: 58)
              .disabled(isMainDisabled)
            Stepper(
              "Minimum age in days",
              onIncrement: {
                let current = pruneDays ?? 30
                pruneDaysText = String(current < Int.max ? current + 1 : Int.max)
              },
              onDecrement: {
                pruneDaysText = String(max(0, (pruneDays ?? 30) - 1))
              }
            )
            .labelsHidden()
            .disabled(isMainDisabled)
            Text(pruneDays == 1 ? "day" : "days")
              .foregroundStyle(.secondary)
            Button("Prune…") {
              if let days = pruneDays { preview(.prune(days: days)) }
            }
            .disabled(isMainDisabled || pruneDays == nil)
          }
        } label: {
          Text("Prune Git Groups")
          if pruneDays == nil {
            Text("Enter 0 or more days.")
              .foregroundStyle(.red)
          }
        }

        LabeledContent("Clean Cache") {
          Button("Clean…") { preview(.clean) }
            .disabled(isMainDisabled)
        }
      }

      if let errorMessage {
        Section("Error") {
          Text(errorMessage)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }

      if let issues = inventory?.issues, !issues.isEmpty {
        Section("Inspection Issues") {
          DisclosureGroup("\(issues.count) issues") {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
              issueRow(issue)
            }
          }
        }
      }

      if let lastRemoval {
        let result = lastRemoval.result
        Section("Last Maintenance Result") {
          LabeledContent(operationTitle(lastRemoval.operation)) {
            Text(result.isComplete ? "Completed" : "Incomplete")
              .foregroundStyle(result.isComplete ? Color.secondary : Color.orange)
          }
          LabeledContent("Reclaimed") {
            Text(formatBytes(result.reclaimedBytes))
              .monospacedDigit()
          }
          LabeledContent("Summary") {
            Text(
              "\(result.removed.count) removed · \(result.skipped.count) skipped · \(result.failures.count) failed"
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()
          }
          if !result.skipped.isEmpty {
            DisclosureGroup("Skipped (\(result.skipped.count))") {
              ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, entry in
                entryRow(entry)
              }
            }
          }
          if !result.failures.isEmpty {
            DisclosureGroup("Failures (\(result.failures.count))") {
              ForEach(Array(result.failures.enumerated()), id: \.offset) { _, issue in
                issueRow(issue)
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await loadInitialInventory() }
    .onDisappear {
      runningTask?.cancel()
      runningTask = nil
    }
    .sheet(item: $pendingPreview) { item in
      CachePreviewSheet(
        preview: item.preview,
        isBusy: isBusy,
        onCancel: { if !isBusy { pendingPreview = nil } },
        onConfirm: { apply(item) }
      )
    }
  }

  private func runOffMain<T: Sendable>(
    _ work: @escaping @Sendable (AcquisitionCache) throws -> T
  ) async throws -> T {
    let environment = self.environment
    return try await Task.detached(priority: .userInitiated) {
      try work(AcquisitionCache(environment: environment))
    }.value
  }

  private func runAction(_ action: @escaping @MainActor () async -> Void) {
    guard !isBusy else { return }
    isBusy = true
    runningTask = Task {
      defer {
        isBusy = false
        runningTask = nil
      }
      await action()
    }
  }

  private func loadInitialInventory() async {
    guard !isBusy, pendingPreview == nil else { return }
    isBusy = true
    defer { isBusy = false }
    await refreshInventory()
  }

  private func refreshInventory() async {
    do {
      let loaded = try await runOffMain { try $0.inspect() }
      guard !Task.isCancelled else { return }
      inventory = loaded
      errorMessage = nil
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func refresh() {
    guard pendingPreview == nil else { return }
    runAction { await refreshInventory() }
  }

  private func preview(_ maintenance: AcquisitionCacheMaintenance) {
    guard pendingPreview == nil else { return }
    runAction {
      errorMessage = nil
      do {
        let captured = try await runOffMain { try $0.preview(maintenance) }
        guard !Task.isCancelled else { return }
        pendingPreview = PreviewSheetItem(preview: captured)
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  private func apply(_ item: PreviewSheetItem) {
    guard pendingPreview?.id == item.id, !item.preview.candidates.isEmpty else { return }
    runAction {
      errorMessage = nil
      do {
        let removal = try await runOffMain { try $0.apply(item.preview) }
        guard !Task.isCancelled else { return }
        lastRemoval = (item.preview.operation, removal)
        pendingPreview = nil
        await refreshInventory()
      } catch {
        guard !Task.isCancelled else { return }
        pendingPreview = nil
        errorMessage = error.localizedDescription
      }
    }
  }
}

private struct PreviewSheetItem: Identifiable, Sendable {
  let id = UUID()
  let preview: AcquisitionCachePreview
}

private struct CachePreviewSheet: View {
  let preview: AcquisitionCachePreview
  let isBusy: Bool
  let onCancel: () -> Void
  let onConfirm: () -> Void

  @State private var isEntriesExpanded: Bool

  init(
    preview: AcquisitionCachePreview,
    isBusy: Bool,
    onCancel: @escaping () -> Void,
    onConfirm: @escaping () -> Void
  ) {
    self.preview = preview
    self.isBusy = isBusy
    self.onCancel = onCancel
    self.onConfirm = onConfirm
    _isEntriesExpanded = State(initialValue: preview.candidates.count <= 8)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section(operationTitle(preview.operation)) {
          LabeledContent("Location") {
            Text(preview.root.path(percentEncoded: false))
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          LabeledContent("Selected") {
            Text("\(entryCountText(preview.candidates.count)) · \(formatBytes(preview.totalBytes))")
              .monospacedDigit()
          }
        }

        Section("Entries to Remove") {
          if preview.candidates.isEmpty {
            Text("No matching cache entries.")
              .foregroundStyle(.secondary)
          } else {
            DisclosureGroup(
              entryCountText(preview.candidates.count), isExpanded: $isEntriesExpanded
            ) {
              ForEach(Array(preview.candidates.enumerated()), id: \.offset) { _, entry in
                entryRow(entry)
              }
            }
          }
        }

        if !preview.issues.isEmpty {
          Section("Inspection Issues") {
            DisclosureGroup("\(preview.issues.count) issues") {
              ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in
                issueRow(issue)
              }
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button(preview.candidates.isEmpty ? "Close" : "Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isBusy)
        Button(confirmTitle(preview.operation), role: .destructive, action: onConfirm)
          .disabled(isBusy || preview.candidates.isEmpty)
      }
      .padding()
    }
    .frame(minWidth: 460, minHeight: 300, maxHeight: 440)
    .interactiveDismissDisabled(isBusy)
  }
}

@MainActor @ViewBuilder
private func entryRow(_ entry: AcquisitionCacheEntry) -> some View {
  HStack(alignment: .firstTextBaseline) {
    VStack(alignment: .leading, spacing: 2) {
      Text(entry.id.isEmpty ? entry.object : entry.id)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Text(entryMetadata(entry))
        .font(.caption)
        .foregroundStyle(entry.pendingDisposal ? Color.orange : Color.secondary)
    }
    Spacer(minLength: 8)
    Text(formatBytes(entry.bytes))
      .monospacedDigit()
      .foregroundStyle(.secondary)
  }
}

@MainActor @ViewBuilder
private func issueRow(_ issue: AcquisitionCacheIssue) -> some View {
  VStack(alignment: .leading, spacing: 2) {
    Text(issue.path)
      .lineLimit(2)
      .truncationMode(.middle)
      .textSelection(.enabled)
    Text(issue.reason)
      .font(.caption)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
  }
}

private func entryMetadata(_ entry: AcquisitionCacheEntry) -> String {
  var parts = [storeTitle(entry.store)]
  if !entry.object.isEmpty, entry.object != entry.id {
    parts.append(entry.object)
  }
  parts.append(entry.lastUsed.formatted(date: .abbreviated, time: .shortened))
  if entry.pendingDisposal {
    parts.append("Pending disposal")
  }
  return parts.joined(separator: " · ")
}

private func formatBytes(_ bytes: Int64) -> String {
  bytes.formatted(.byteCount(style: .file))
}

private func storeTitle(_ store: AcquisitionCacheStore) -> String {
  switch store {
  case .git: return "Git"
  case .http: return "HTTP"
  case .deployed: return "Deployed"
  }
}

private func entryCountText(_ count: Int) -> String {
  count == 1 ? "1 entry" : "\(count) entries"
}

private func operationTitle(_ operation: AcquisitionCacheMaintenance) -> String {
  switch operation {
  case .clean: return "Clean Cache"
  case .prune(let days):
    return days == 1 ? "Prune Git Groups (1 day)" : "Prune Git Groups (\(days) days)"
  }
}

private func confirmTitle(_ operation: AcquisitionCacheMaintenance) -> String {
  switch operation {
  case .clean: return "Clean"
  case .prune: return "Prune"
  }
}

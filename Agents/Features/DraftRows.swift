import SwiftUI

struct DraftRowActions {
  let moveUp: () -> Void
  let moveDown: () -> Void
  let remove: () -> Void
  let canMoveUp: Bool
  let canMoveDown: Bool
}

/// Fresh draft occurrences have no Core node yet. These identities last for the editor's lifetime
/// and move with the values; they never become declaration or preference data.
struct DraftRows<Value, Content: View>: View {
  private struct Row: Identifiable {
    let id: UUID
    let value: Value
  }
  @Binding var values: [Value]
  @State private var identities: [UUID]
  private let content: (Binding<Value>, DraftRowActions) -> Content

  init(
    values: Binding<[Value]>,
    @ViewBuilder content: @escaping (Binding<Value>, DraftRowActions) -> Content
  ) {
    _values = values
    _identities = State(initialValue: values.wrappedValue.map { _ in UUID() })
    self.content = content
  }

  var body: some View {
    ForEach(zip(identities, values).map { Row(id: $0.0, value: $0.1) }) { row in
      let index = identities.firstIndex(of: row.id)
      content(
        Binding(
          get: {
            guard let index = identities.firstIndex(of: row.id), values.indices.contains(index)
            else { return row.value }
            return values[index]
          },
          set: { value in
            guard let index = identities.firstIndex(of: row.id), values.indices.contains(index)
            else { return }
            values[index] = value
          }),
        DraftRowActions(
          moveUp: { move(row.id, offset: -1) }, moveDown: { move(row.id, offset: 1) },
          remove: {
            guard let index = identities.firstIndex(of: row.id), values.indices.contains(index)
            else { return }
            identities.remove(at: index)
            values.remove(at: index)
          }, canMoveUp: (index ?? 0) > 0, canMoveDown: (index ?? values.count) + 1 < values.count))
    }
    .onChange(of: values.count) { _, count in
      if identities.count < count { identities += (identities.count..<count).map { _ in UUID() } }
      if identities.count > count { identities.removeLast(identities.count - count) }
    }
  }

  private func move(_ id: UUID, offset: Int) {
    guard let index = identities.firstIndex(of: id), values.indices.contains(index),
      values.indices.contains(index + offset)
    else { return }
    identities.swapAt(index, index + offset)
    values.swapAt(index, index + offset)
  }
}

struct DraftRowButtons: View {
  let actions: DraftRowActions
  var body: some View {
    HStack {
      Button("Move Up", action: actions.moveUp).disabled(!actions.canMoveUp)
      Button("Move Down", action: actions.moveDown).disabled(!actions.canMoveDown)
      Button("Remove", action: actions.remove)
    }
  }
}

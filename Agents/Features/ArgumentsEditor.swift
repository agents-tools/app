import SwiftUI

/// UI occurrence identities are separate from string values so duplicate and empty arguments remain
/// distinct while moving or editing. The bindings write each complete string without tokenization.
struct ArgumentRows {
  let values: Binding<[String]>
  let identities: Binding<[UUID]>

  func text(for id: UUID) -> Binding<String> {
    Binding(
      get: {
        guard let index = identities.wrappedValue.firstIndex(of: id),
          values.wrappedValue.indices.contains(index)
        else { return "" }
        return values.wrappedValue[index]
      },
      set: { text in
        guard let index = identities.wrappedValue.firstIndex(of: id),
          values.wrappedValue.indices.contains(index)
        else { return }
        values.wrappedValue[index] = text
      })
  }

  func append() {
    values.wrappedValue.append("")
    identities.wrappedValue.append(UUID())
  }

  func remove(_ id: UUID) {
    guard let index = identities.wrappedValue.firstIndex(of: id),
      values.wrappedValue.indices.contains(index)
    else { return }
    identities.wrappedValue.remove(at: index)
    values.wrappedValue.remove(at: index)
  }

  func move(_ id: UUID, offset: Int) {
    guard let index = identities.wrappedValue.firstIndex(of: id),
      values.wrappedValue.indices.contains(index),
      values.wrappedValue.indices.contains(index + offset)
    else { return }
    identities.wrappedValue.swapAt(index, index + offset)
    values.wrappedValue.swapAt(index, index + offset)
  }
}

struct ArgumentsEditor: View {
  @Binding var values: [String]
  @State private var identities: [UUID]

  init(values: Binding<[String]>) {
    _values = values
    _identities = State(initialValue: values.wrappedValue.map { _ in UUID() })
  }

  var body: some View {
    let rows = ArgumentRows(values: $values, identities: $identities)
    DisclosureGroup("Arguments") {
      ForEach(identities, id: \.self) { id in
        if let index = identities.firstIndex(of: id) {
          TextField("Argument \(index + 1)", text: rows.text(for: id), axis: .vertical)
            .lineLimit(1...5)
          DraftRowButtons(
            actions: .init(
              moveUp: { rows.move(id, offset: -1) }, moveDown: { rows.move(id, offset: 1) },
              remove: { rows.remove(id) }, canMoveUp: index > 0,
              canMoveDown: index + 1 < identities.count))
        }
      }
      Button("Add Argument") { rows.append() }
      Text("Each row is one argument. Empty rows and line breaks are preserved.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onChange(of: values.count) { _, count in
      if identities.count < count { identities += (identities.count..<count).map { _ in UUID() } }
      if identities.count > count { identities.removeLast(identities.count - count) }
    }
  }
}

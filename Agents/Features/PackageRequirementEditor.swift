import AgentsCore
import SwiftUI

struct PackageRequirementEditor: View {
  @Binding var requirement: SourceRequirement

  private enum Kind: String, CaseIterable {
    case exact = "Exact version"
    case major = "Up to next major"
    case minor = "Up to next minor"
    case range = "Version range"

    func requirement(from lower: String, to upper: String) -> SourceRequirement {
      switch self {
      case .exact: .exact(lower)
      case .major: .upToNextMajor(from: lower)
      case .minor: .upToNextMinor(from: lower)
      case .range: .range(from: lower, to: upper)
      }
    }
  }

  var body: some View {
    Picker(
      "Version requirement",
      selection: Binding(
        get: { kind }, set: { requirement = $0.requirement(from: lower, to: upper) }
      )
    ) {
      ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    TextField(
      kind == .exact ? "Version" : "Minimum version",
      text: Binding(
        get: { lower }, set: { requirement = kind.requirement(from: $0, to: upper) }
      ), prompt: Text("1.0.0"))
    if kind == .range {
      TextField(
        "Upper bound (exclusive)",
        text: Binding(
          get: { upper }, set: { requirement = .range(from: lower, to: $0) }
        ), prompt: Text("2.0.0"))
    }
  }

  private var kind: Kind {
    switch requirement {
    case .upToNextMajor: .major
    case .upToNextMinor: .minor
    case .range: .range
    default: .exact
    }
  }

  private var lower: String {
    switch requirement {
    case .exact(let version), .upToNextMajor(let version), .upToNextMinor(let version),
      .range(let version, _):
      version
    case .branch, .revision: ""
    }
  }

  private var upper: String {
    if case .range(_, let version) = requirement { return version }
    return ""
  }
}

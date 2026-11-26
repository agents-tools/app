import AgentsCore
import Foundation
import Yams

struct SourceAccessProfileDraft: Equatable {
  struct Authority: Equatable {
    var host = ""
    var port = ""

    fileprivate init() {}

    fileprivate init(_ node: Node) {
      host = node.text("host")
      port = node.text("port")
    }

    fileprivate var fields: [(Node, Node?)] {
      let portValue: Node?
      if port.isEmpty {
        portValue = nil
      } else if port.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(port) {
        portValue = Node(String(number))
      } else {
        portValue = quoted(port)
      }
      return [("host", quoted(host)), ("port", portValue)]
    }
  }

  struct Provider: Identifiable, Equatable {
    let id = UUID()
    var authority = Authority()
    var provider: SourceProvider = .github
  }

  struct Mirror: Identifiable, Equatable {
    let id = UUID()
    var source = Authority()
    var base = ""
    var flavor: SourceArchiveMirror.Flavor = .github
    var supportsQualifiedGitLabRefs: Bool?
    var requiresExactArchiveBytes: Bool?

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id && lhs.source == rhs.source && lhs.base.utf8.elementsEqual(rhs.base.utf8)
        && lhs.flavor == rhs.flavor
        && lhs.supportsQualifiedGitLabRefs == rhs.supportsQualifiedGitLabRefs
        && lhs.requiresExactArchiveBytes == rhs.requiresExactArchiveBytes
    }
  }

  struct Credential: Identifiable, Equatable {
    let id = UUID()
    var route: SourceAccessProfile.Credential.Route = .direct
    var authority = Authority()
    var path = ""
    var environmentVariable = ""
    var exportable: Bool?
    var validationEndpoint = ""

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id && lhs.route == rhs.route && lhs.authority == rhs.authority
        && lhs.path.utf8.elementsEqual(rhs.path.utf8)
        && lhs.environmentVariable == rhs.environmentVariable && lhs.exportable == rhs.exportable
        && lhs.validationEndpoint.utf8.elementsEqual(rhs.validationEndpoint.utf8)
    }
  }

  let id = UUID()
  var egress: SourceAccessProfile.Egress = .directAllowed
  var providers: [Provider] = []
  var mirrors: [Mirror] = []
  var credentials: [Credential] = []
  private var explicitLists: Set<String> = []

  init() {}

  // Core has already admitted the document. Read its scalar values here to retain
  // original strings and the presence of optional fields in the form.
  init?(yaml: String, profile: SourceAccessProfile) {
    guard let root = try? Yams.compose(yaml: yaml) else { return nil }
    let providerNodes = root["providers"]?.array() ?? []
    let mirrorNodes = root["mirrors"]?.array() ?? []
    let credentialNodes = root["credentials"]?.array() ?? []
    guard providerNodes.count == profile.providers.count,
      mirrorNodes.count == profile.mirrors.count,
      credentialNodes.count == profile.credentials.count
    else { return nil }
    egress = profile.egress
    explicitLists = Set(["providers", "mirrors", "credentials"].filter { root[$0] != nil })
    providers = zip(providerNodes, profile.providers).map { node, value in
      Provider(authority: Authority(node), provider: value.provider)
    }
    mirrors = zip(mirrorNodes, profile.mirrors).map { node, value in
      Mirror(
        source: node["source"].map(Authority.init) ?? Authority(), base: node.text("base"),
        flavor: value.flavor,
        supportsQualifiedGitLabRefs: node["supportsQualifiedGitLabRefs"].map { _ in
          value.supportsQualifiedGitLabRefs
        },
        requiresExactArchiveBytes: node["requiresExactArchiveBytes"].map { _ in
          value.requiresExactArchiveBytes
        })
    }
    credentials = zip(credentialNodes, profile.credentials).map { node, value in
      Credential(
        route: value.route, authority: Authority(node), path: node.text("path"),
        environmentVariable: value.environmentVariable,
        exportable: node["exportable"].map { _ in value.exportable },
        validationEndpoint: node.text("validationEndpoint"))
    }
  }

  func encoded() throws -> Data {
    let providerNodes = providers.map { row in
      mapping(row.authority.fields + [("provider", Node(row.provider.rawValue))])
    }
    let mirrorNodes = mirrors.map { row in
      mapping([
        ("source", mapping(row.source.fields)), ("base", quoted(row.base)),
        ("flavor", Node(row.flavor.rawValue)),
        ("supportsQualifiedGitLabRefs", flag(row.supportsQualifiedGitLabRefs)),
        ("requiresExactArchiveBytes", flag(row.requiresExactArchiveBytes)),
      ])
    }
    let credentialNodes = credentials.map { row in
      mapping(
        [("route", Node(row.route.rawValue))] + row.authority.fields + [
          ("path", optionalText(row.path)),
          ("environmentVariable", quoted(row.environmentVariable)),
          ("exportable", flag(row.exportable)),
          ("validationEndpoint", optionalText(row.validationEndpoint)),
        ])
    }
    let root = mapping([
      ("version", Node("1")), ("egress", Node(egress.rawValue)),
      ("providers", list(providerNodes, key: "providers")),
      ("mirrors", list(mirrorNodes, key: "mirrors")),
      ("credentials", list(credentialNodes, key: "credentials")),
    ])
    return Data(try Yams.serialize(node: root, allowUnicode: true).utf8)
  }

  private func list(_ nodes: [Node], key: String) -> Node? {
    nodes.isEmpty && !explicitLists.contains(key) ? nil : Node(nodes)
  }
}

extension Node {
  fileprivate func text(_ key: String) -> String { self[key]?.scalar?.string ?? "" }
}

private func mapping(_ fields: [(Node, Node?)]) -> Node {
  Node(fields.compactMap { key, value in value.map { (key, $0) } })
}

private func quoted(_ text: String) -> Node {
  Node(text, Tag(.str), .doubleQuoted)
}

private func optionalText(_ text: String) -> Node? {
  text.isEmpty ? nil : quoted(text)
}

private func flag(_ value: Bool?) -> Node? {
  value.map { Node(String($0)) }
}

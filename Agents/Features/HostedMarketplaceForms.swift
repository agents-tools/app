import AgentsCore
import AgentsUpdates
import SwiftUI

struct HostedMarketplaceForm: View {
  let index: URL?
  let allowsToken: Bool
  let connect: (String, MarketplaceOrigin, String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var address = ""
  @State private var token = ""
  @State private var errorText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(index == nil ? "Add HTTPS Marketplace" : "Marketplace Access").font(.headline)
      Form {
        if let index {
          LabeledContent("Index", value: index.absoluteString)
        } else {
          TextField("Name", text: $name)
          TextField(
            "Index URL", text: $address, prompt: Text("https://example.com/marketplace.json"))
        }
        if allowsToken {
          SecureField("Access token", text: $token, prompt: Text("Optional"))
            .help("Used for this index while the Packages window is open.")
        }
      }
      if let errorText { Text(errorText).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(index == nil ? "Add and Browse" : "Connect") {
          do {
            guard let url = index ?? URL(string: address) else {
              throw CoreError.invalidState("Enter an HTTPS index URL.")
            }
            connect(name, try MarketplaceOrigin(hostedIndex: url), token.isEmpty ? nil : token)
          } catch { errorText = String(describing: error) }
        }.keyboardShortcut(.defaultAction)
          .disabled(index == nil && (name.isEmpty || address.isEmpty))
      }
    }.padding().frame(minWidth: 420)
  }
}

struct HostedDownloadOriginsForm: View {
  let save: ([URL]) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var addresses: String
  @State private var errorText: String?

  init(origins: [URL], save: @escaping ([URL]) -> Void) {
    _addresses = State(initialValue: origins.map(\.absoluteString).joined(separator: "\n"))
    self.save = save
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Trusted Download Origins").font(.headline)
      Text(
        "Allow archive redirects to these HTTPS origins while Packages is open. Enter one origin per line."
      )
      TextEditor(text: $addresses).font(.body.monospaced()).frame(minHeight: 80)
      if let errorText { Text(errorText).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Save") {
          do {
            let urls = try addresses.split(whereSeparator: \.isNewline).compactMap { line -> URL? in
              let value = String(line).trimmingCharacters(in: .whitespaces)
              guard !value.isEmpty else { return nil }
              guard let url = URL(string: value) else {
                throw CoreError.invalidState("Enter an HTTPS origin.")
              }
              return url
            }
            _ = try HostedMarketplaceAccess(trustedDownloadOrigins: urls)
            save(urls)
          } catch { errorText = String(describing: error) }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding().frame(minWidth: 440)
  }
}

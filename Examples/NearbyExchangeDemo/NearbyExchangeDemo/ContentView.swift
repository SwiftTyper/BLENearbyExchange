import BLENearbyExchange
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Environment(\.nearbyExchange) private var nearbyExchange
  @State private var file = ContentView.dummy
  @State private var received: FilePayload?
  @State private var previewURL: URL?
  @State private var isImporting = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Your file") {
          Button {
            isImporting = true
          } label: {
            LabeledContent(
              file.name,
              value: file.data.count.formatted(.byteCount(style: .file))
            )
          }
        }

        if let received {
          Section("Received") {
            Button {
              preview(received)
            } label: {
              LabeledContent(
                received.name,
                value: received.data.count.formatted(.byteCount(style: .file))
              )
            }
          }
        }

        Section {
          Button("Start exchange") {
            Task { await exchange() }
          }
          .frame(maxWidth: .infinity)
          .fontWeight(.semibold)
          .disabled(file.data.isEmpty)
        }
      }
      .navigationTitle("Nearby Exchange")
      .quickLookPreview($previewURL)
      .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
        guard
          let url = try? result.get(),
          url.startAccessingSecurityScopedResource()
        else { return }

        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url)
        else { return }

        file = FilePayload(name: url.lastPathComponent, data: data)
      }
    }
  }
}

extension ContentView {
  private func exchange() async {
    guard let payload = try? JSONEncoder().encode(file)
    else { return }
    
    guard let peer = try? await nearbyExchange.run(payload: payload)
    else { return }
    
    received = try? JSONDecoder().decode(FilePayload.self, from: peer)
  }
  
  private func preview(_ file: FilePayload) {
    let name = URL(filePath: file.name).lastPathComponent
    let url = URL.temporaryDirectory.appending(path: name.isEmpty ? "received" : name)
    
    guard (try? file.data.write(to: url)) != nil
    else { return }
    
    previewURL = url
  }
}

extension ContentView {
  struct FilePayload: Codable {
    var name: String
    var data: Data
  }
  
  private static let dummy = FilePayload(
    name: "dummy\(Int.random(in: 0..<10)).txt",
    data: Data(String(repeating: "Dummy Payload Data :)", count: 5000 ).utf8)
  )
}

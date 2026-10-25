import SwiftUI
import TodoCore

@main
struct TodoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var status = "Verbindung wird geprüft …"
    // Placeholder base URL for local development.
    private let client = APIClient(baseURL: URL(string: "http://127.0.0.1:28080")!)

    var body: some View {
        VStack(spacing: 12) {
            Text("Todo").font(.largeTitle)
            Text(status)
        }
        .padding()
        .task {
            do { _ = try await client.ready(); status = "Backend erreichbar" }
            catch { status = "Backend nicht erreichbar" }
        }
    }
}

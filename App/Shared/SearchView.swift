import SwiftUI
import TodoCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    var body: some View {
        List(hits) { hit in
            if let task = hit.task {
                NavigationLink(value: task) {
                    VStack(alignment: .leading) {
                        Text(task.title)
                        Text(hit.project.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button { model.selectedProjectID = hit.project.id } label: {
                    Label(hit.project.name, systemImage: "folder")
                }
            }
        }
        .overlay { if searched && hits.isEmpty { ContentUnavailableView.search(text: query) } }
        .searchable(text: $query, prompt: Text("search.prompt"))
        .onSubmit(of: .search) { Task { await run() } }
        .navigationTitle("view.search")
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let client = model.client, !q.isEmpty else { return }
        do { hits = try await client.search(q, limit: 50).items; searched = true }
        catch { await model.handle(error) }
    }
}

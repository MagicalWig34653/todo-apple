import SwiftUI
import TodoCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    var body: some View {
        List {
            if !searched {
                Section {
                    ForEach(model.projects) { p in
                        Button { model.selectedProjectID = p.id } label: {
                            HStack(spacing: Space.m) { IconTile(symbol: "folder.fill", tint: model.projectColor(p.id), size: 26); Text(verbatim: p.name).font(.body.weight(.medium)); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).taskRowInsets()
                    }
                } header: { SectionHeaderLabel(title: "projects.title") }
                if !meta.allLabels.isEmpty {
                    Section {
                        ForEach(meta.allLabels) { l in
                            Button { query = l.name; Task { await run(label: l) } } label: {
                                Label { Text(verbatim: l.name) } icon: { Image(systemName: "tag").foregroundStyle(.secondary) }
                            }
                            .buttonStyle(.plain).taskRowInsets()
                        }
                    } header: { SectionHeaderLabel(title: "task.labels") }
                }
            }
            ForEach(hits) { hit in
                if let task = hit.task {
                    TaskRow(task: task).taskRowInsets()
                } else {
                    Button { model.selectedProjectID = hit.project.id } label: {
                        HStack(spacing: 10) { ProjectDot(id: hit.project.id, size: 10); Text(verbatim: hit.project.name); Spacer() }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).taskRowInsets()
                }
            }
        }
        .taskListStyle()
        .overlay { if searched && hits.isEmpty { ContentUnavailableView.search(text: query) } }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("search.prompt"))
        #else
        .searchable(text: $query, prompt: Text("search.prompt"))
        #endif
        .onSubmit(of: .search) { Task { await run() } }
        .onChange(of: query) { _, new in if new.isEmpty { searched = false; hits = [] } }
        .navigationTitle("view.search")
    }

    private func run(label: TaskLabel? = nil) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let client = model.client, !q.isEmpty else { return }
        do { hits = try await client.search(label == nil ? q : nil, labelID: label?.id, limit: 50).items; searched = true }
        catch { await model.handle(error) }
    }
}

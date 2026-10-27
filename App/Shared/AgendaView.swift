import SwiftUI
import TodoCore

/// "Heute" and "Anstehend": server-side lists of planned tasks.
struct AgendaView: View {
    enum Mode { case today, upcoming }
    @Environment(AppModel.self) private var model
    let mode: Mode

    private var items: [PlanningTask] { mode == .today ? model.today : model.upcoming }

    var body: some View {
        List(items) { item in
            NavigationLink(value: item.task) {
                TaskRow(task: item.task, planning: item.planning)
            }
        }
        .overlay { if items.isEmpty { ContentUnavailableView(mode == .today ? "agenda.todayEmpty" : "agenda.upcomingEmpty", systemImage: "checkmark.seal") } }
        .navigationTitle(mode == .today ? "view.today" : "view.upcoming")
        .refreshable { await model.reloadAgenda() }
        .task { await model.reloadAgenda() }
    }
}

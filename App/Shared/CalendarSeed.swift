#if DEBUG
import SwiftUI
import TodoCore

/// Sample data for the calendar previews and screenshots (no server). The busy day is the selected day, the other days of
/// the week get a few cards each, so the week grid and the strip look alive on any weekday.
enum CalendarSeed {
    static let apple = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    static let backend = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
    static let home = UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!
    static let privacy = UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!

    static let projectNames: [UUID: String] = [apple: "Todolino Apple", backend: "Todolino Backend", home: "Umzug", privacy: "Datenschutz"]

    @MainActor static func model(reference: Date = AppClock.now, calendar: Calendar = .current) -> CalendarModel {
        let day = calendar.startOfDay(for: reference)
        let window = CalendarWindow.week(containing: day, calendar: calendar)
        var entries = busyDay(day, calendar: calendar)
        for (index, other) in window.days.enumerated() where !calendar.isDate(other, inSameDayAs: day) {
            entries += quietDay(other, index: index, calendar: calendar)
        }
        return CalendarModel(entries: entries, unscheduled: unscheduled(day, calendar: calendar), projectNames: projectNames, selectedDay: day, calendar: calendar)
    }

    private static func at(_ day: Date, _ hour: Int, _ minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func entry(
        _ title: String, _ project: UUID, start: Date? = nil, minutes: Int? = nil, allDay: Bool = false, due: Date? = nil,
        status: String = "open", canEdit: Bool = true, autoStart: Bool = false, autoStarted: Date? = nil, repo: String? = nil,
        conflicts: [ScheduleConflict] = []
    ) -> ScheduleEntry {
        ScheduleEntry(taskID: UUID(), projectID: project, title: title, status: status, version: 1, plannedAt: start, plannedMinutes: minutes,
                      plannedAllDay: allDay, dueAt: due, canEdit: canEdit, autoStart: autoStart, autoStartedAt: autoStarted, repositoryKey: repo,
                      conflicts: conflicts)
    }

    private static func busyDay(_ day: Date, calendar c: Calendar) -> [ScheduleEntry] {
        [
            entry("Release-Notizen schreiben", backend, start: day, allDay: true),
            entry("Tagesbericht prüfen", backend, start: at(day, 8, 30, calendar: c), autoStart: true),
            entry("Kalender-Raster umsetzen", apple, start: at(day, 9, calendar: c), minutes: 60, due: at(day, 9, 45, calendar: c)),
            entry("Review der Push-Vorschau", apple, start: at(day, 9, 30, calendar: c), minutes: 45),
            entry("Runner-Anbindung testen", apple, start: at(day, 11, calendar: c), minutes: 90, autoStart: true, repo: "github.com/todolino/runner"),
            entry("Datenbank-Migration prüfen", backend, start: at(day, 11, 30, calendar: c), minutes: 60, repo: "github.com/todolino/runner"),
            entry("Datenschutzerklärung aktualisieren", privacy, start: at(day, 13, 30, calendar: c), due: at(day, 14, calendar: c)),
            entry("Dokumentation zur Datenschutz-Grundverordnung vollständig überarbeiten und mit der Rechtsabteilung abstimmen", privacy,
                  start: at(day, 15, calendar: c), minutes: 120, conflicts: [.prerequisiteOpen]),
            entry("Team-Abstimmung zum Umzug", home, start: at(day, 16, calendar: c), minutes: 60, canEdit: false),
            entry("Wochenrückblick", apple, start: at(day, 17, calendar: c), status: "done"),
            entry("Steuerunterlagen einreichen", home, due: at(day, 18, calendar: c)),
        ]
    }

    private static func quietDay(_ day: Date, index: Int, calendar c: Calendar) -> [ScheduleEntry] {
        switch index % 4 {
        case 0: [entry("Wochenplanung", apple, start: at(day, 9, calendar: c), minutes: 45), entry("Support-Postfach sichten", backend, start: at(day, 14, calendar: c))]
        case 1: [entry("Projekt-Reise vorbereiten", home, start: day, allDay: true), entry("Design-Review", apple, start: at(day, 10, 30, calendar: c), minutes: 90)]
        case 2: [entry("Lizenzliste abgleichen", privacy, start: at(day, 13, calendar: c), minutes: 60), entry("Build-Server aufräumen", backend, start: at(day, 15, 30, calendar: c), minutes: 30)]
        default: [entry("Nachbarn Schlüssel übergeben", home, start: at(day, 11, calendar: c))]
        }
    }

    private static func unscheduled(_ day: Date, calendar c: Calendar) -> [ScheduleEntry] {
        let soon = c.date(byAdding: .day, value: 2, to: at(day, 17, calendar: c))
        return [
            entry("Fehlerbericht sortieren", apple, due: soon),
            entry("Angebot für die Arbeitsplatte einholen", home),
            entry("Backup-Skript prüfen", backend),
            entry("Passkey-Texte überarbeiten", apple, due: at(day, 12, calendar: c)),
            entry("Lizenzliste aktualisieren", privacy),
            entry("Sehr langer Titel für den Test des Zeilenumbruchs in der Seitenleiste Ohne Termin", backend),
        ]
    }
}

/// Root of the server-free preview (`TODO_DEBUG_CALENDAR_PREVIEW=1`), used for screenshots by the UI tour.
struct CalendarPreviewHost: View {
    @State private var app = AppModel()
    var body: some View {
        NavigationStack { CalendarScreen(model: CalendarSeed.model()) }
            .environment(app).tint(.brand)
    }
}
#endif

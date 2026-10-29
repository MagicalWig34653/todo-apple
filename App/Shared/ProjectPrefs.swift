import SwiftUI
import TodoCore

/// Per-device project preferences: favorites, view options and the inline description. The server has no project
/// description, favorite flag or view settings yet, so these live in UserDefaults (provisional, documented in STATUS).
@MainActor @Observable
final class ProjectPrefs {
    enum ViewMode: String, CaseIterable { case list, board }
    enum Sort: String, CaseIterable { case manual, name, due, priority }
    enum Group: String, CaseIterable { case none, column, priority }

    struct Options: Codable, Equatable {
        var mode: String = ViewMode.list.rawValue
        var sort: String = Sort.manual.rawValue
        var group: String = Group.none.rawValue
        var showCompleted = false
    }

    private let defaults: UserDefaults
    private(set) var favorites: [UUID]
    private var options: [String: Options]
    private var descriptions: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = (defaults.stringArray(forKey: "pref.favorites") ?? []).compactMap(UUID.init(uuidString:))
        options = defaults.data(forKey: "pref.projectOptions").flatMap { try? JSONDecoder().decode([String: Options].self, from: $0) } ?? [:]
        descriptions = defaults.dictionary(forKey: "pref.projectDescriptions") as? [String: String] ?? [:]
    }

    func isFavorite(_ id: UUID) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: UUID) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
        defaults.set(favorites.map(\.uuidString), forKey: "pref.favorites")
    }

    func options(for id: UUID) -> Options {
        #if DEBUG
        if options[id.uuidString] == nil, ProcessInfo.processInfo.environment["TODO_DEBUG_BOARD"] == "1" { return Options(mode: ViewMode.board.rawValue) }
        #endif
        return options[id.uuidString] ?? Options()
    }

    func setOptions(_ value: Options, for id: UUID) {
        options[id.uuidString] = value
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: "pref.projectOptions") }
    }

    func description(for id: UUID) -> String { descriptions[id.uuidString] ?? "" }

    func setDescription(_ text: String, for id: UUID) {
        descriptions[id.uuidString] = text.isEmpty ? nil : text
        defaults.set(descriptions, forKey: "pref.projectDescriptions")
    }
}

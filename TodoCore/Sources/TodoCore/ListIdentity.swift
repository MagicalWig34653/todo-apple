// Identities for SwiftUI lists over data that can repeat its natural key (card 21A79A08).
//
// A `ForEach` whose ids collide draws one row for several entries and misplaces state and animations. These helpers keep the first
// entry's key and number later repeats, like `uniqueKeys` of the web app (`web/src/lib/keys.ts`): "a", "a#2", "a#3". A number that
// is already taken moves on, so keys stay stable while a list only grows at its end.

/// `keys` with every repeat made unique: the first keeps its key, later repeats get `#2`, `#3`, ...
public func uniqueKeys(_ keys: [String]) -> [String] {
    var used = Set<String>()
    var repeats: [String: Int] = [:]
    return keys.map { wanted in
        var key = wanted
        while used.contains(key) {
            let next = (repeats[wanted] ?? 1) + 1
            repeats[wanted] = next
            key = "\(wanted)#\(next)"
        }
        used.insert(key)
        return key
    }
}

/// An entry with the list-unique key it is drawn under.
public struct Keyed<Item>: Identifiable {
    public let id: String
    public let item: Item
}

public extension Sequence {
    /// Pairs every element with a list-unique id built from `key` (repeats are numbered, see `uniqueKeys`).
    func uniquelyKeyed(by key: (Element) -> String) -> [Keyed<Element>] {
        let items = Array(self)
        return zip(uniqueKeys(items.map(key)), items).map { Keyed(id: $0, item: $1) }
    }
}

public extension Array where Element: Identifiable {
    /// Appends a further page without the entries the list already shows (a page requested twice, a refresh that overlaps).
    func appendingPage(_ page: [Element]) -> [Element] {
        var known = Set(map(\.id))
        return self + page.filter { known.insert($0.id).inserted }
    }
}

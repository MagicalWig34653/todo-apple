// Stub: the behaviour follows after the red run (card 21A79A08).

public struct Keyed<Item>: Identifiable {
    public let id: String
    public let item: Item
}

public func uniqueKeys(_ keys: [String]) -> [String] { keys }

public extension Sequence {
    func uniquelyKeyed(by key: (Element) -> String) -> [Keyed<Element>] {
        let items = Array(self)
        return zip(uniqueKeys(items.map(key)), items).map { Keyed(id: $0, item: $1) }
    }
}

public extension Array where Element: Identifiable {
    func appendingPage(_ page: [Element]) -> [Element] { self + page }
}

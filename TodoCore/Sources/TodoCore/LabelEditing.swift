import Foundation

/// Outcome of checking the text typed into the rename sheet (card 9E4572D1).
public enum LabelRenameCheck: Equatable, Sendable {
    /// The trimmed name equals the current one: nothing to send, the sheet just closes.
    case unchanged
    /// The trimmed name to send.
    case valid(String)
    /// The name the server would refuse; the sheet shows the reason and stays open.
    case invalid(LabelNameError)
}

/// Pure rules behind the label management screen, kept out of the views so they are testable.
public enum LabelEditing {
    public static func checkRename(_ input: String, of label: TaskLabel) -> LabelRenameCheck {
        do {
            let name = try LabelName.normalized(input)
            return name == label.name ? .unchanged : .valid(name)
        } catch let error as LabelNameError {
            return .invalid(error)
        } catch {
            return .invalid(.empty)
        }
    }

    /// The confirmed labels with the unsent edits on top: queued renames show their new name, queued deletes disappear.
    public static func applying(_ overlay: OutboxSnapshot, to labels: [TaskLabel]) -> [TaskLabel] {
        labels.compactMap { label in
            if overlay.deletedLabels.contains(label.id) { return nil }
            guard let name = overlay.renamedLabels[label.id] else { return label }
            return TaskLabel(id: label.id, name: name, version: label.version)
        }
    }

    /// The label part of the REST outbox (older servers) and the sync queue as one overlay; the sync queue's newer rename wins.
    public static func merged(legacy: OutboxSnapshot, engine: OutboxSnapshot) -> OutboxSnapshot {
        var o = legacy
        for (id, name) in engine.renamedLabels { o.renamedLabels[id] = name }
        o.deletedLabels.formUnion(engine.deletedLabels)
        for id in o.deletedLabels { o.renamedLabels[id] = nil }
        return o
    }
}

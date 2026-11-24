import SwiftUI
import TodoCore

/// Rename sheet of the labels screen (card 9E4572D1). The check is `LabelEditing.checkRename` (trimmed, 1...200 characters):
/// a refused name shows its reason under the field and keeps the sheet open, nothing is queued then.
struct LabelRenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let label: TaskLabel
    /// Seeded once with the current name; the sheet is created per label (`sheet(item:)`), so it never has to follow changes.
    @State private var name: String
    @State private var error: LabelNameError?
    @State private var saving = false
    @FocusState private var focused: Bool

    init(label: TaskLabel) {
        self.label = label
        _name = State(initialValue: label.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(accessible: "label.rename.placeholder", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                        .accessibilityIdentifier("labelRenameField")
                        .onChange(of: name) { _, _ in error = nil }
                } footer: {
                    if let error {
                        Label { Text(Self.message(error)) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .font(.footnote)
                            .foregroundStyle(Color.dueOverdue)
                            .accessibilityIdentifier("labelRenameError")
                    }
                }
            }
            .navigationTitle("label.rename.action")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("label.rename.cancel") { dismiss() }.accessibilityIdentifier("labelRenameCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("label.rename.save") { save() }.disabled(saving).accessibilityIdentifier("labelRenameSave")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 180)
        #endif
        .presentationDetents([.medium])
        .task { focused = true }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let refused = await model.renameLabel(label, to: name)
            saving = false
            if let refused { error = refused } else { dismiss() }
        }
    }

    static func message(_ error: LabelNameError) -> LocalizedStringKey {
        switch error {
        case .empty: "label.rename.error.empty"
        case .tooLong: "label.rename.error.tooLong \(LabelName.maxLength)"
        }
    }
}

/// Swipe and context actions of a label row: rename (sheet) and delete (confirmation dialog, set by the owner).
struct LabelRowActions: ViewModifier {
    let label: TaskLabel
    let onRename: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: onDelete) { Label("label.delete.action", systemImage: "trash") }
                    .accessibilityIdentifier("labelDeleteAction")
                Button(action: onRename) { Label("label.rename.action", systemImage: "pencil") }
                    .tint(Color.tileBlue)
                    .accessibilityIdentifier("labelRenameAction")
            }
            .contextMenu {
                Button(action: onRename) { Label("label.rename.action", systemImage: "pencil") }
                Button(role: .destructive, action: onDelete) { Label("label.delete.action", systemImage: "trash") }
            }
            .accessibilityAction(named: Text("label.rename.action"), onRename)
            .accessibilityAction(named: Text("label.delete.action"), onDelete)
    }
}

extension View {
    func labelRowActions(_ label: TaskLabel, rename: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        modifier(LabelRowActions(label: label, onRename: rename, onDelete: delete))
    }
}

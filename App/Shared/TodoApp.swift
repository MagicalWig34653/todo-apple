import SwiftUI

@main
struct TodoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environment(model).task { await model.start() }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .launching: ProgressView()
        case .signedOut: LoginView()
        case .signedIn: MainView()
        }
    }
}

import SwiftUI

/// Placeholder: the watch session handover (from the paired iPhone) is not designed yet, so this target
/// only builds and explains that. Showing/completing open tasks follows once a token can be transferred.
@main
struct TodoWatchApp: App {
    var body: some Scene {
        WindowGroup {
            Text("watch.placeholder").multilineTextAlignment(.center).padding()
        }
    }
}

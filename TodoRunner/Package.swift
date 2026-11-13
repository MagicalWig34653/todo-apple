// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TodoRunner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TodoRunner", targets: ["TodoRunner"]),
        .executable(name: "todo-runner", targets: ["todo-runner"]),
    ],
    dependencies: [
        // Local speech recognition (Core ML). The model is downloaded once, explicitly, by `todo-runner voice-setup`.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        .target(name: "TodoRunner"),
        // WhisperKit lives in its own target so the runner core stays free of the Core ML dependency.
        .target(name: "TodoRunnerWhisper", dependencies: ["TodoRunner", .product(name: "WhisperKit", package: "WhisperKit")]),
        .executableTarget(name: "todo-runner", dependencies: ["TodoRunner", "TodoRunnerWhisper"]),
        .testTarget(name: "TodoRunnerTests", dependencies: ["TodoRunner", "TodoRunnerWhisper"]),
    ]
)

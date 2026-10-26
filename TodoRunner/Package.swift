// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TodoRunner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TodoRunner", targets: ["TodoRunner"]),
        .executable(name: "todo-runner", targets: ["todo-runner"]),
    ],
    targets: [
        .target(name: "TodoRunner"),
        .executableTarget(name: "todo-runner", dependencies: ["TodoRunner"]),
        .testTarget(name: "TodoRunnerTests", dependencies: ["TodoRunner"]),
    ]
)

// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TodoCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [.library(name: "TodoCore", targets: ["TodoCore"])],
    targets: [
        .target(name: "TodoCore"),
        .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"]),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RallyDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RallyDesktop", targets: ["RallyDesktop"])
    ],
    targets: [
        .target(
            name: "RallyCore",
            path: "Sources/RallyCore"
        ),
        .executableTarget(
            name: "RallyDesktop",
            dependencies: ["RallyCore"],
            path: "Sources/RallyDesktop"
        ),
        .executableTarget(
            name: "SelfTest",
            dependencies: ["RallyCore"],
            path: "Sources/SelfTest"
        ),
        .testTarget(
            name: "RallyDesktopTests",
            dependencies: ["RallyCore"],
            path: "Tests/RallyDesktopTests"
        ),
    ]
)

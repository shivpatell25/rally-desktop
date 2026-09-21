// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RallyDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RallyDesktop", targets: ["RallyDesktop"])
    ],
    dependencies: [
        // Playback: libVLC for non-standard IPTV/Stremio transports AVPlayer rejects.
        .package(url: "https://github.com/videolan/vlckit.git", branch: "master"),
        // In-app updates: Sparkle 2 against appleApp/appcast.xml.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "RallyCore",
            dependencies: [.product(name: "VLCKit", package: "vlckit")],
            path: "Sources/RallyCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "RallyDesktop",
            dependencies: [
                "RallyCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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

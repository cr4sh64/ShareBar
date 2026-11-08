// swift-tools-version:5.9
import PackageDescription

// Le package sert au développement (swift build / swift test).
// L'app (.app signée, universelle) est assemblée par build.sh.
let package = Package(
    name: "ShareBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ShareBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("NetFS"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(name: "ShareBarTests", dependencies: ["ShareBar"]),
    ]
)

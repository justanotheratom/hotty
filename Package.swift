// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HoTty",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "HoTty",
            path: "Sources/HoTty",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChronicleKit",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "ChronicleKit", targets: ["ChronicleKit"]),
        .library(name: "ChronicleCLICore", targets: ["ChronicleCLICore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "ChronicleKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .target(
            name: "ChronicleCLICore",
            dependencies: [
                "ChronicleKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ChronicleKitTests", dependencies: ["ChronicleKit"]),
        .testTarget(name: "ChronicleCLICoreTests", dependencies: ["ChronicleCLICore"]),
    ]
)

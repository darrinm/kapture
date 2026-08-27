// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Kapture",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(name: "KaptureDesign", path: "Sources/KaptureDesign"),
        .target(
            name: "KaptureCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/KaptureCore"),
        .target(
            name: "KaptureCapture",
            dependencies: ["KaptureCore", "KaptureDesign"],
            path: "Sources/KaptureCapture"),
        .target(
            name: "KaptureIntelligence",
            dependencies: ["KaptureCore"],
            path: "Sources/KaptureIntelligence"),
        .target(
            name: "KaptureEditor",
            dependencies: ["KaptureCore", "KaptureDesign"],
            path: "Sources/KaptureEditor"),
        .target(
            name: "KaptureRecording",
            dependencies: ["KaptureCore", "KaptureCapture"],
            path: "Sources/KaptureRecording"),
        .executableTarget(
            name: "Kapture",
            dependencies: ["KaptureCore", "KaptureCapture", "KaptureDesign", "KaptureEditor",
                           "KaptureRecording", "KaptureIntelligence"],
            path: "Sources/Kapture"),
        .testTarget(name: "KaptureCoreTests", dependencies: ["KaptureCore"], path: "Tests/KaptureCoreTests"),
    ]
)

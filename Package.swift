// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Kapture",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // in-app updates: the appcast lives at kapture.sh/appcast.xml and points at GitHub releases
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
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
        // The shared library (docs/SHARED-LIBRARY.md §10.5 F89). Separate from Core because sync
        // adds CryptoKit and URLSession, and Core stays testable without a network stack.
        .target(
            name: "KaptureSync",
            dependencies: ["KaptureCore"],
            path: "Sources/KaptureSync"),
        .executableTarget(
            name: "Kapture",
            dependencies: ["KaptureCore", "KaptureCapture", "KaptureDesign", "KaptureEditor",
                           "KaptureRecording", "KaptureIntelligence", "KaptureSync",
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Kapture"),
        .testTarget(name: "KaptureCoreTests", dependencies: ["KaptureCore"], path: "Tests/KaptureCoreTests"),
        .testTarget(name: "KaptureSyncTests", dependencies: ["KaptureSync"],
                    path: "Tests/KaptureSyncTests"),
        .testTarget(name: "KaptureEditorTests", dependencies: ["KaptureEditor"],
                    path: "Tests/KaptureEditorTests"),
        .testTarget(name: "KaptureDesignTests", dependencies: ["KaptureDesign"],
                    path: "Tests/KaptureDesignTests"),
    ]
)

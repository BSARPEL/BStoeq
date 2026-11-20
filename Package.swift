// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BStoeq",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "BStoeq", targets: ["BStoeq"])],
    targets: [
        .target(name: "MenuBarBridge", publicHeadersPath: "include"),
        .target(name: "BStoeqCore", resources: [.process("Resources")]),
        .target(name: "BStoeqRuntime", dependencies: ["MenuBarBridge"]),
        .target(name: "ArchiveCore"),
        .target(name: "ArchiveWorkspace", dependencies: ["ArchiveCore"], resources: [.process("Resources")]),
        .executableTarget(name: "BStoeq", dependencies: ["BStoeqCore", "BStoeqRuntime", "MenuBarBridge", "ArchiveWorkspace"],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "BStoeqCoreTests", dependencies: ["BStoeqCore"]),
        .testTarget(name: "BStoeqRuntimeTests", dependencies: ["BStoeqRuntime"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "BStoeqTests", dependencies: ["BStoeq"])
    ],
    swiftLanguageModes: [.v5]
)

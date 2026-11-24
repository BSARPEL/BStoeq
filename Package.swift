// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BStoeq",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "BStoeq", targets: ["BStoeq"])],
    targets: [
        .target(name: "MenuBarBridge", publicHeadersPath: "include"),
        .target(name: "ConvertCore"),
        .target(name: "BStoeqCore", dependencies: ["ConvertCore"], resources: [.process("Resources")]),
        .target(name: "BStoeqRuntime", dependencies: ["MenuBarBridge"]),
        .target(name: "ArchiveCore"),
        .target(name: "ArchiveWorkspace", dependencies: ["ArchiveCore"], resources: [.process("Resources")]),
        .executableTarget(name: "BStoeq", dependencies: ["BStoeqCore", "BStoeqRuntime", "MenuBarBridge", "ArchiveWorkspace", "ConvertCore", "ArchiveCore"],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "ConvertCoreTests", dependencies: ["ConvertCore"]),
        .testTarget(name: "BStoeqCoreTests", dependencies: ["BStoeqCore", "ConvertCore"]),
        .testTarget(name: "BStoeqRuntimeTests", dependencies: ["BStoeqRuntime"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "BStoeqTests", dependencies: ["BStoeq"])
    ],
    swiftLanguageModes: [.v5]
)

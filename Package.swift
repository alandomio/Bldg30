// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ModelDeck",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ModelDeck", targets: ["ModelDeck"])],
    targets: [
        .target(name: "ModelDeckCore", resources: [.process("Resources")]),
        .executableTarget(name: "ModelDeck", dependencies: ["ModelDeckCore"], exclude: ["Info.plist"]),
        .testTarget(name: "ModelDeckCoreTests", dependencies: ["ModelDeckCore"])
    ]
)

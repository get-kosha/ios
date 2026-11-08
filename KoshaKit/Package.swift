// swift-tools-version: 6.0
import PackageDescription

// Kosha's shared code: the app, its widgets and later the watch app use it. Model has no UI and no I/O; API talks to
// the server; Store keeps the cache and outbox; Design holds the tokens, strings and every component; Features holds
// the screens. It builds for macOS too, so `swift test` runs on the Mac.
let package = Package(
    name: "KoshaKit",
    defaultLocalization: "en",
    platforms: [.iOS("17.4"), .macOS("14.4")],
    products: [
        .library(name: "KoshaKit", targets: ["Model", "API", "Store", "Design", "Features"]),
        .library(name: "KoshaWidgetKit", targets: ["Model", "Store", "Design"]),
    ],
    targets: [
        .target(name: "Model"),
        .target(name: "API", dependencies: ["Model"]),
        .target(name: "Store", dependencies: ["Model", "API"]),
        .target(name: "Design", dependencies: ["Model"], resources: [.process("Resources")]),
        .target(name: "Features", dependencies: ["Model", "API", "Store", "Design"]),
        .testTarget(name: "ModelTests", dependencies: ["Model"]),
        .testTarget(name: "DesignTests", dependencies: ["Design"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", "Model"]),
    ],
    swiftLanguageModes: [.v6]
)

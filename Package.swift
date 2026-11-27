// swift-tools-version: 6.0
import PackageDescription

// Sprocket: a video is code. A JavaScript composition answers "what does frame N look like?" with a tree of
// nodes; the engine draws that tree with Core Image / Metal and writes the frames to a movie, on the phone.
let package = Package(
    name: "Sprocket",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Sprocket", targets: ["Sprocket"]),
        .executable(name: "sprocket-render", targets: ["SprocketCLI"]),
    ],
    targets: [
        .target(name: "Sprocket", resources: [.copy("Prelude")]),
        .executableTarget(name: "SprocketCLI", dependencies: ["Sprocket"]),
        .testTarget(name: "SprocketTests", dependencies: ["Sprocket"]),
    ],
    swiftLanguageModes: [.v5]
)

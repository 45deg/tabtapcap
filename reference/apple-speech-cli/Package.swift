// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AppleSpeechCLI",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "apple-speech-cli", targets: ["AppleSpeechCLI"]),
    ],
    targets: [
        .executableTarget(name: "AppleSpeechCLI"),
    ]
)
